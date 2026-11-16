import Foundation

/// Persisted node identity + paired device tokens. This Mac is the auth server.
@MainActor
final class PairingStore: ObservableObject {
    struct PairedDevice: Identifiable, Codable, Hashable {
        let id: UUID
        var name: String
        var token: String
        var createdAt: Date
    }

    struct PendingDeviceAuth: Identifiable, Hashable {
        let id: UUID
        var deviceCode: String
        var userCode: String
        var deviceName: String
        var expiresAt: Date
        var status: Status
        var issuedToken: String?

        enum Status: String, Hashable {
            case pending
            case approved
            case denied
        }
    }

    struct PairChallenge: Hashable {
        var code: String
        var secret: String
        var expiresAt: Date
    }

    @Published var nodeID: UUID
    @Published var nodeName: String
    @Published var remoteEnabled: Bool
    @Published var port: UInt16
    /// Optional public host for off-LAN (Tailscale MagicDNS / tunnel hostname).
    @Published var publicHost: String
    @Published var pairedDevices: [PairedDevice] = []
    @Published var pendingAuths: [PendingDeviceAuth] = []
    @Published private(set) var activeChallenge: PairChallenge?

    private let defaultPort: UInt16 = 9932

    private var fileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CoffeeAndPi", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("node.json")
    }

    private struct Disk: Codable {
        var nodeID: UUID
        var nodeName: String
        var remoteEnabled: Bool
        var port: UInt16
        var publicHost: String?
        var pairedDevices: [PairedDevice]
    }

    init() {
        nodeID = UUID()
        nodeName = Host.current().localizedName ?? "Coffee & Pi"
        remoteEnabled = false
        port = defaultPort
        publicHost = ""
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let disk = try? decoder.decode(Disk.self, from: data) else { return }
        nodeID = disk.nodeID
        nodeName = disk.nodeName
        remoteEnabled = disk.remoteEnabled
        port = disk.port == 0 ? defaultPort : disk.port
        publicHost = disk.publicHost ?? ""
        pairedDevices = disk.pairedDevices
    }

    func save() {
        let disk = Disk(
            nodeID: nodeID,
            nodeName: nodeName,
            remoteEnabled: remoteEnabled,
            port: port,
            publicHost: publicHost.isEmpty ? nil : publicHost,
            pairedDevices: pairedDevices
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(disk) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func setRemoteEnabled(_ on: Bool) {
        remoteEnabled = on
        save()
    }

    func setNodeName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        nodeName = trimmed
        save()
    }

    func setPublicHost(_ host: String) {
        publicHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    // MARK: - QR / one-shot pair code

    func refreshPairChallenge() -> PairChallenge {
        let challenge = PairChallenge(
            code: Self.sixDigitCode(),
            secret: Self.randomToken(bytes: 16),
            expiresAt: Date().addingTimeInterval(120)
        )
        activeChallenge = challenge
        return challenge
    }

    func clearExpiredChallenge() {
        guard let c = activeChallenge, c.expiresAt < Date() else { return }
        activeChallenge = nil
    }

    /// Redeem QR / short code → long-lived device token.
    func redeemPairCode(_ code: String, deviceName: String) -> PairedDevice? {
        clearExpiredChallenge()
        guard let challenge = activeChallenge else { return nil }
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let ok = normalized == challenge.code.uppercased() || normalized == challenge.secret.uppercased()
        guard ok, challenge.expiresAt >= Date() else { return nil }
        activeChallenge = nil
        return issueDevice(name: deviceName.isEmpty ? "Device" : deviceName)
    }

    // MARK: - Device OAuth

    func startDeviceAuth(deviceName: String) -> PendingDeviceAuth {
        pendingAuths.removeAll { $0.expiresAt < Date() }
        let auth = PendingDeviceAuth(
            id: UUID(),
            deviceCode: Self.randomToken(bytes: 24),
            userCode: Self.userFacingCode(),
            deviceName: deviceName.isEmpty ? "Device" : deviceName,
            expiresAt: Date().addingTimeInterval(120),
            status: .pending,
            issuedToken: nil
        )
        pendingAuths.insert(auth, at: 0)
        return auth
    }

    func approveDeviceAuth(id: UUID) -> PairedDevice? {
        guard let idx = pendingAuths.firstIndex(where: { $0.id == id }) else { return nil }
        guard pendingAuths[idx].status == .pending, pendingAuths[idx].expiresAt >= Date() else { return nil }
        let device = issueDevice(name: pendingAuths[idx].deviceName)
        pendingAuths[idx].status = .approved
        pendingAuths[idx].issuedToken = device.token
        return device
    }

    func denyDeviceAuth(id: UUID) {
        guard let idx = pendingAuths.firstIndex(where: { $0.id == id }) else { return }
        pendingAuths[idx].status = .denied
    }

    enum TokenPollResult {
        case pending
        case denied
        case expired
        case token(PairedDevice)
    }

    func pollDeviceToken(deviceCode: String) -> TokenPollResult {
        pendingAuths.removeAll { $0.expiresAt < Date() && $0.status == .pending }
        guard let idx = pendingAuths.firstIndex(where: { $0.deviceCode == deviceCode }) else {
            return .expired
        }
        let auth = pendingAuths[idx]
        if auth.expiresAt < Date(), auth.status == .pending {
            return .expired
        }
        switch auth.status {
        case .pending:
            return .pending
        case .denied:
            return .denied
        case .approved:
            if let token = auth.issuedToken,
               let device = pairedDevices.first(where: { $0.token == token }) {
                return .token(device)
            }
            return .expired
        }
    }

    func device(forBearer token: String) -> PairedDevice? {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return pairedDevices.first { $0.token == t }
    }

    func revokeDevice(id: UUID) {
        pairedDevices.removeAll { $0.id == id }
        save()
    }

    @discardableResult
    private func issueDevice(name: String) -> PairedDevice {
        let device = PairedDevice(
            id: UUID(),
            name: name,
            token: Self.randomToken(bytes: 32),
            createdAt: Date()
        )
        pairedDevices.insert(device, at: 0)
        save()
        return device
    }

    private static func sixDigitCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    private static func userFacingCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }

    private static func randomToken(bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}

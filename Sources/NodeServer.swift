import Darwin
import Foundation
import Network

/// Coffee & Pi node API: pairing + chat surface for phone / peer Macs.
@MainActor
final class NodeServer: ObservableObject {
    let pairing = PairingStore()
    @Published private(set) var isListening = false
    @Published private(set) var lastError: String?
    @Published private(set) var lanAddresses: [String] = []

    private var http: NodeHTTPServer?
    private let bonjour = NodeBonjour()
    private let wsHub = NodeWSHub()
    private weak var app: AppModel?
    private var lastPushAt: [UUID: Date] = [:]

    /// QR payload clients scan.
    struct PairPayload: Codable {
        var v: Int
        var nodeID: String
        var name: String
        var hosts: [String]
        var port: UInt16
        var code: String
    }

    func attach(app: AppModel) {
        self.app = app
    }

    func bootstrap() {
        lanAddresses = Self.localIPv4Addresses()
        if pairing.remoteEnabled {
            start()
        }
    }

    func setEnabled(_ on: Bool) {
        pairing.setRemoteEnabled(on)
        if on {
            start()
        } else {
            stop()
        }
    }

    func start() {
        stop()
        lanAddresses = Self.localIPv4Addresses()
        let port = pairing.port
        let server = NodeHTTPServer(
            port: port,
            wsPath: "/v1/ws",
            wsHandler: { [weak self] sessionID, message in
                await self?.handleWebSocket(sessionID: sessionID, message: message)
            },
            wsAuth: { [weak self] req in
                guard let self else { return false }
                if await self.authorizedDevice(req) != nil { return true }
                return await self.authorizedDeviceFromQuery(req) != nil
            },
            wsOpen: { [weak self] sessionID, send in
                Task { @MainActor in
                    self?.wsHub.add(id: sessionID, send: { text in send(text) })
                }
            },
            wsClose: { [weak self] sessionID in
                Task { @MainActor in
                    self?.wsHub.remove(sessionID)
                }
            },
            handler: { [weak self] req in
                await self?.handle(req) ?? .json(500, ["error": "server unavailable"])
            }
        )
        do {
            try server.start()
            http = server
            isListening = true
            lastError = nil
            bonjour.start(
                name: pairing.nodeName,
                port: Int(port),
                nodeID: pairing.nodeID.uuidString
            )
        } catch {
            lastError = error.localizedDescription
            isListening = false
            http = nil
        }
    }

    func stop() {
        http?.stop()
        http = nil
        bonjour.stop()
        isListening = false
    }

    func refreshPairChallenge() -> PairingStore.PairChallenge {
        pairing.refreshPairChallenge()
    }

    func currentPairPayload() -> PairPayload {
        pairing.clearExpiredChallenge()
        let challenge = pairing.activeChallenge ?? pairing.refreshPairChallenge()
        return PairPayload(
            v: 1,
            nodeID: pairing.nodeID.uuidString,
            name: pairing.nodeName,
            hosts: lanAddresses.isEmpty ? ["127.0.0.1"] : lanAddresses,
            port: pairing.port,
            code: challenge.code
        )
    }

    func pairQRString() -> String {
        let payload = currentPairPayload()
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8)
        else { return "" }
        return "coffeeandpi://pair?\(json.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? json)"
    }

    // MARK: - HTTP routing

    private func handle(_ req: NodeHTTPServer.Request) async -> NodeHTTPServer.Response {
        let path = req.path
        let method = req.method

        if method == "GET", path == "/v1/health" {
            return .json(200, [
                "ok": true,
                "nodeID": pairing.nodeID.uuidString,
                "name": pairing.nodeName,
                "port": pairing.port,
                "hosts": lanAddresses,
            ])
        }

        if method == "POST", path == "/v1/pair" {
            return handlePair(req)
        }

        if (method == "POST" || method == "GET"), path == "/v1/oauth/device" {
            return handleOAuthDeviceStart(req)
        }

        if method == "POST", path == "/v1/oauth/token" {
            return handleOAuthToken(req)
        }

        // Everything else needs a bearer token.
        guard let device = authorizedDevice(req) else {
            return .json(401, ["error": "unauthorized"])
        }

        if method == "GET", path == "/v1/nodes" {
            return .json(200, [
                "self": [
                    "id": pairing.nodeID.uuidString,
                    "name": pairing.nodeName,
                    "hosts": lanAddresses,
                    "port": pairing.port,
                ],
                "peers": [] as [Any],
                "device": ["id": device.id.uuidString, "name": device.name],
            ])
        }

        if method == "GET", path == "/v1/models" {
            return await handleModels()
        }

        if method == "GET", path == "/v1/chats" {
            return await handleListChats()
        }

        if method == "GET", path.hasPrefix("/v1/chats/") {
            let rest = String(path.dropFirst("/v1/chats/".count))
            if rest.contains("/") {
                // only messages POST uses deeper paths for now
            } else if let id = UUID(uuidString: rest) {
                return await handleGetChat(id)
            }
        }

        if method == "POST", path.hasPrefix("/v1/chats/"), path.hasSuffix("/messages") {
            let mid = String(path.dropFirst("/v1/chats/".count).dropLast("/messages".count))
            if let id = UUID(uuidString: mid) {
                return await handlePostMessage(chatID: id, req: req)
            }
        }

        if method == "POST", path == "/v1/chats" {
            return await handleCreateChat(req)
        }

        if method == "POST", path.hasPrefix("/v1/chats/"), path.hasSuffix("/abort") {
            let mid = String(path.dropFirst("/v1/chats/".count).dropLast("/abort".count))
            if let id = UUID(uuidString: mid) {
                return await handleAbort(chatID: id)
            }
        }

        return .json(404, ["error": "not_found"])
    }

    /// Push chat state to subscribed thin clients (phone). Throttled while streaming.
    func notifyChatChanged(_ chatID: UUID, force: Bool = false) {
        guard let app, let thread = app.threads.first(where: { $0.id == chatID }) else { return }
        let now = Date()
        if !force, let last = lastPushAt[chatID], now.timeIntervalSince(last) < 0.12 {
            return
        }
        lastPushAt[chatID] = now
        guard let payload = jsonString(["type": "chat", "chat": chatDetail(thread)]) else { return }
        wsHub.publish(chatID: chatID, json: payload)
    }

    private func authorizedDevice(_ req: NodeHTTPServer.Request) -> PairingStore.PairedDevice? {
        if let header = req.headers["authorization"] {
            let prefix = "bearer "
            if header.lowercased().hasPrefix(prefix) {
                let token = String(header.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if let device = pairing.device(forBearer: token) { return device }
            }
        }
        return authorizedDeviceFromQuery(req)
    }

    private func authorizedDeviceFromQuery(_ req: NodeHTTPServer.Request) -> PairingStore.PairedDevice? {
        guard let token = req.query["token"] else { return nil }
        return pairing.device(forBearer: token)
    }

    private func handlePair(_ req: NodeHTTPServer.Request) -> NodeHTTPServer.Response {
        guard let json = jsonObject(req.body),
              let code = json["code"] as? String
        else {
            return .json(400, ["error": "code_required"])
        }
        let name = (json["deviceName"] as? String) ?? "Device"
        guard let device = pairing.redeemPairCode(code, deviceName: name) else {
            return .json(401, ["error": "invalid_or_expired_code"])
        }
        return .json(200, deviceJSON(device))
    }

    private func handleOAuthDeviceStart(_ req: NodeHTTPServer.Request) -> NodeHTTPServer.Response {
        let name = (jsonObject(req.body)?["deviceName"] as? String) ?? "Device"
        let auth = pairing.startDeviceAuth(deviceName: name)
        let host = lanAddresses.first ?? "127.0.0.1"
        return .json(200, [
            "device_code": auth.deviceCode,
            "user_code": auth.userCode,
            "verification_uri": "http://\(host):\(pairing.port)/pair",
            "expires_in": 120,
            "interval": 2,
        ])
    }

    private func handleOAuthToken(_ req: NodeHTTPServer.Request) -> NodeHTTPServer.Response {
        guard let json = jsonObject(req.body),
              let deviceCode = json["device_code"] as? String
        else {
            return .json(400, ["error": "device_code_required"])
        }
        switch pairing.pollDeviceToken(deviceCode: deviceCode) {
        case .pending:
            return .json(400, ["error": "authorization_pending"])
        case .denied:
            return .json(403, ["error": "access_denied"])
        case .expired:
            return .json(400, ["error": "expired_token"])
        case .token(let device):
            return .json(200, deviceJSON(device))
        }
    }

    private func handleModels() async -> NodeHTTPServer.Response {
        guard let app else { return .json(500, ["error": "no_app"]) }
        let models = app.availableModels.map { m -> [String: Any] in
            var d: [String: Any] = [
                "id": m.id,
                "provider": m.provider,
                "modelId": m.modelId,
                "name": m.displayName,
            ]
            if let loaded = m.loaded { d["loaded"] = loaded }
            return d
        }
        return .json(200, ["models": models])
    }

    private func handleListChats() async -> NodeHTTPServer.Response {
        guard let app else { return .json(500, ["error": "no_app"]) }
        let chats = app.threads
            .filter { !$0.isArchived }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { chatSummary($0) }
        return .json(200, ["chats": chats])
    }

    private func handleGetChat(_ id: UUID) async -> NodeHTTPServer.Response {
        guard let app else { return .json(500, ["error": "no_app"]) }
        guard let thread = app.threads.first(where: { $0.id == id }) else {
            return .json(404, ["error": "not_found"])
        }
        return .json(200, chatDetail(thread))
    }

    private func handleCreateChat(_ req: NodeHTTPServer.Request) async -> NodeHTTPServer.Response {
        guard let app else { return .json(500, ["error": "no_app"]) }
        let json = jsonObject(req.body) ?? [:]
        let projectID = (json["projectID"] as? String).flatMap(UUID.init(uuidString:))
        let beanID = (json["beanID"] as? String).flatMap(UUID.init(uuidString:))
        await app.newChat(projectID: projectID ?? app.projects.activeProjectID, beanID: beanID ?? app.projects.activeBeanID)
        guard let thread = app.activeThread else {
            return .json(500, ["error": "create_failed"])
        }
        return .json(201, chatDetail(thread))
    }

    private func handlePostMessage(chatID: UUID, req: NodeHTTPServer.Request) async -> NodeHTTPServer.Response {
        guard let app else { return .json(500, ["error": "no_app"]) }
        guard let json = jsonObject(req.body),
              let text = json["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .json(400, ["error": "text_required"])
        }
        do {
            // Phone only submits text — Pi + models run on this Mac.
            var thread = try app.enqueueRemoteMessage(chatID: chatID, text: text)
            // Yield so the background send appends the user bubble before we serialize.
            try? await Task.sleep(nanoseconds: 40_000_000)
            if let latest = app.threads.first(where: { $0.id == chatID }) {
                thread = latest
            }
            notifyChatChanged(chatID, force: true)
            var body = chatDetail(thread)
            body["runsOn"] = "node"
            body["accepted"] = true
            return .json(202, body)
        } catch {
            return .json(400, ["error": error.localizedDescription])
        }
    }

    private func handleAbort(chatID: UUID) async -> NodeHTTPServer.Response {
        guard let app else { return .json(500, ["error": "no_app"]) }
        guard app.threads.contains(where: { $0.id == chatID }) else {
            return .json(404, ["error": "not_found"])
        }
        await app.abortRemote(chatID: chatID)
        notifyChatChanged(chatID, force: true)
        if let thread = app.threads.first(where: { $0.id == chatID }) {
            return .json(200, chatDetail(thread))
        }
        return .json(200, ["ok": true])
    }

    /// WebSocket: subscribe to a chat; Mac pushes `{type:chat}` as Pi streams on this computer.
    private func handleWebSocket(sessionID: UUID, message: String) async -> String? {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            return jsonString(["type": "error", "error": "bad_message"])
        }
        if type == "ping" {
            return jsonString(["type": "pong"])
        }
        if type == "subscribe", let chatID = (json["chatID"] as? String).flatMap(UUID.init(uuidString:)) {
            guard let app, let thread = app.threads.first(where: { $0.id == chatID }) else {
                return jsonString(["type": "error", "error": "not_found"])
            }
            wsHub.subscribe(sessionID, chatID: chatID)
            return jsonString(["type": "chat", "chat": chatDetail(thread)])
        }
        if type == "unsubscribe", let chatID = (json["chatID"] as? String).flatMap(UUID.init(uuidString:)) {
            wsHub.unsubscribe(sessionID, chatID: chatID)
            return jsonString(["type": "ok"])
        }
        if type == "get_chat", let chatID = (json["chatID"] as? String).flatMap(UUID.init(uuidString:)) {
            guard let app, let thread = app.threads.first(where: { $0.id == chatID }) else {
                return jsonString(["type": "error", "error": "not_found"])
            }
            return jsonString(["type": "chat", "chat": chatDetail(thread)])
        }
        return jsonString(["type": "error", "error": "unknown_type"])
    }

    // MARK: - JSON helpers

    private func chatSummary(_ t: ChatThread) -> [String: Any] {
        [
            "id": t.id.uuidString,
            "title": t.title,
            "updatedAt": ISO8601DateFormatter().string(from: t.updatedAt),
            "isBusy": t.isBusy,
            "preview": String(t.preview.prefix(160)),
            "beanID": t.beanID?.uuidString as Any,
            "projectID": t.projectID?.uuidString as Any,
            "kind": t.kind.rawValue,
        ]
    }

    private func chatDetail(_ t: ChatThread) -> [String: Any] {
        var d = chatSummary(t)
        d["messages"] = t.messages.map { m -> [String: Any] in
            [
                "id": m.id,
                "role": m.role.rawValue,
                "text": m.text,
                "isStreaming": m.isStreaming,
                "speakerBeanID": m.speakerBeanID?.uuidString as Any,
            ]
        }
        if let model = t.selectedModel {
            d["selectedModel"] = [
                "provider": model.provider,
                "modelId": model.modelId,
                "id": model.id,
            ]
        }
        if let err = t.lastError { d["lastError"] = err }
        return d
    }

    private func deviceJSON(_ d: PairingStore.PairedDevice) -> [String: Any] {
        [
            "access_token": d.token,
            "token_type": "Bearer",
            "device": [
                "id": d.id.uuidString,
                "name": d.name,
                "createdAt": ISO8601DateFormatter().string(from: d.createdAt),
            ],
            "node": [
                "id": pairing.nodeID.uuidString,
                "name": pairing.nodeName,
            ],
        ]
    }

    private func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func jsonString(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    static func localIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING) else { continue }
            guard flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: hostname)
                if !ip.hasPrefix("169.254.") {
                    addresses.append(ip)
                }
            }
        }
        return addresses
    }
}

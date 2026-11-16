import AppKit
import Foundation

/// Checks GitHub Releases and installs the macOS zip over the running app.
@MainActor
final class AppUpdater: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, notes: String)
        case downloading(fraction: Double?)
        case installing
        case error(String)
    }

    struct ReleaseInfo: Equatable {
        var tag: String
        var version: String
        var notes: String
        var assetURL: URL
        var assetName: String
    }

    /// ponytail: public Releases API — repo must be public (or mirror releases) for unsigned clients.
    static let githubOwner = "Frarebear"
    static let githubRepo = "coffee-and-pi"

    @Published var status: Status = .idle
    @Published private(set) var latest: ReleaseInfo?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "0.0.0"
    }

    var releasesURL: URL {
        URL(string: "https://github.com/\(Self.githubOwner)/\(Self.githubRepo)/releases")!
    }

    func check(quiet: Bool = false) async {
        if !quiet { status = .checking }
        do {
            let release = try await fetchLatestRelease()
            latest = release
            if Self.isVersion(release.version, newerThan: currentVersion) {
                status = .available(version: release.version, notes: release.notes)
            } else {
                status = quiet ? .idle : .upToDate
            }
        } catch {
            if quiet {
                status = .idle
            } else {
                status = .error(error.localizedDescription)
            }
        }
    }

    func installAvailable() async {
        if latest == nil {
            await check()
        }
        guard let release = latest, case .available = status else { return }
        await downloadAndInstall(release)
    }

    // MARK: - Network

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(Self.githubOwner)/\(Self.githubRepo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("CoffeeAndPi/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            throw UpdateError.noReleases
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.badResponse
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.badResponse
        }
        let tag = (json["tag_name"] as? String) ?? ""
        let version = Self.normalizeVersion(tag)
        let notes = (json["body"] as? String) ?? ""
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = Self.pickMacAsset(assets),
              let rawURL = asset["browser_download_url"] as? String,
              let assetURL = URL(string: rawURL),
              let assetName = asset["name"] as? String
        else {
            throw UpdateError.noMacAsset
        }
        return ReleaseInfo(tag: tag, version: version, notes: notes, assetURL: assetURL, assetName: assetName)
    }

    private static func pickMacAsset(_ assets: [[String: Any]]) -> [String: Any]? {
        let names = assets.compactMap { row -> (String, [String: Any])? in
            guard let name = row["name"] as? String else { return nil }
            return (name.lowercased(), row)
        }
        let preferred = names.first { name, _ in
            name.hasSuffix(".zip") && (name.contains("macos") || name.contains("mac") || name.contains("coffee"))
        }
        if let preferred { return preferred.1 }
        return names.first { $0.0.hasSuffix(".zip") }?.1
    }

    // MARK: - Install

    private func downloadAndInstall(_ release: ReleaseInfo) async {
        status = .downloading(fraction: nil)
        do {
            let (tempURL, response) = try await URLSession.shared.download(from: release.assetURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw UpdateError.badResponse
            }
            status = .installing

            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("CoffeeAndPi-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zipURL = work.appendingPathComponent(release.assetName)
            if FileManager.default.fileExists(atPath: zipURL.path) {
                try FileManager.default.removeItem(at: zipURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: zipURL)

            let unzipDir = work.appendingPathComponent("payload", isDirectory: true)
            try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", args: ["-x", "-k", zipURL.path, unzipDir.path])

            guard let newApp = findAppBundle(in: unzipDir) else {
                throw UpdateError.noAppInZip
            }

            let currentApp = Bundle.main.bundleURL
            let script = """
            #!/bin/bash
            set -euo pipefail
            APP_PID=\(ProcessInfo.processInfo.processIdentifier)
            NEW_APP=\(shellEscape(newApp.path))
            DEST=\(shellEscape(currentApp.path))
            LOG="$HOME/Library/Logs/coffee-and-pi-update.log"
            {
              echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) updating → $DEST"
              while kill -0 "$APP_PID" 2>/dev/null; do sleep 0.2; done
              sleep 0.4
              xattr -dr com.apple.quarantine "$NEW_APP" 2>/dev/null || true
              rm -rf "$DEST"
              ditto "$NEW_APP" "$DEST"
              xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
              open "$DEST"
              echo "done"
            } >>"$LOG" 2>&1
            """
            let scriptURL = work.appendingPathComponent("install.sh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [scriptURL.path]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()

            NSApp.terminate(nil)
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func findAppBundle(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            if url.pathExtension == "app" {
                return url
            }
        }
        return nil
    }

    private func run(_ launchPath: String, args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let err = Pipe()
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "failed"
            throw UpdateError.shell(msg)
        }
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Version compare

    static func normalizeVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("v") {
            s = String(s.dropFirst())
        }
        return s
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        compare(parse(normalizeVersion(candidate)), parse(normalizeVersion(current))) > 0
    }

    private static func parse(_ v: String) -> [Int] {
        let parts = v.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        if parts.isEmpty { return [0, 0, 0] }
        return parts + Array(repeating: 0, count: max(0, 3 - parts.count))
    }

    private static func compare(_ a: [Int], _ b: [Int]) -> Int {
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }

    enum UpdateError: LocalizedError {
        case noReleases, badResponse, noMacAsset, noAppInZip, shell(String)
        var errorDescription: String? {
            switch self {
            case .noReleases: return "No GitHub releases yet — push a release with Scripts/release.sh"
            case .badResponse: return "Couldn’t read GitHub releases"
            case .noMacAsset: return "Latest release has no macOS .zip asset"
            case .noAppInZip: return "Update zip didn’t contain a .app"
            case .shell(let m): return m
            }
        }
    }
}

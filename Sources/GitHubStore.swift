import AppKit
import Foundation

/// Thin `gh` / `git` wrapper for project GitHub connection.
@MainActor
final class GitHubStore: ObservableObject {
    @Published private(set) var loggedInLogin: String?
    @Published var lastError: String?

    func refreshAuth() async {
        do {
            let out = try await run("/opt/homebrew/bin/gh", ["api", "user", "--jq", ".login"])
            loggedInLogin = out.trimmingCharacters(in: .whitespacesAndNewlines)
            lastError = nil
        } catch {
            loggedInLogin = nil
            lastError = error.localizedDescription
        }
    }

    /// Detect `owner/repo` from a local git checkout.
    func detectRemote(at path: String) async -> String? {
        do {
            let url = try await run("/usr/bin/git", ["-C", path, "remote", "get-url", "origin"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return normalizeRemote(url)
        } catch {
            return nil
        }
    }

    func openRepo(_ remote: String) {
        let slug = normalizeRemote(remote) ?? remote
        if let url = URL(string: "https://github.com/\(slug)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func normalizeRemote(_ raw: String) -> String? {
        var s = raw
        if s.hasSuffix(".git") { s.removeLast(4) }
        if let r = s.range(of: "github.com[:/]") {
            let rest = String(s[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let parts = rest.split(separator: "/").prefix(2)
            if parts.count == 2 { return parts.joined(separator: "/") }
        }
        if s.contains("/"), !s.contains("://") { return s }
        return nil
    }

    private func run(_ launchPath: String, _ args: [String]) async throws -> String {
        let proc = Process()
        var path = launchPath
        if launchPath.hasSuffix("/gh"), !FileManager.default.isExecutableFile(atPath: path) {
            path = "/usr/local/bin/gh"
        }
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
        ]
        try proc.run()
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? text
            throw NSError(domain: "GitHubStore", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: e])
        }
        return text
    }
}

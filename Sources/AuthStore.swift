import Foundation
import Security

/// Surfaces Pi's existing `~/.pi/agent/auth.json` providers in the UI.
@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var providers: [ProviderAuth] = []

    struct ProviderAuth: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let type: String
        let ready: Bool
    }

    private var authURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.pi/agent/auth.json")
    }

    private let keychainServicePrefix = "com.caleb.CoffeeAndPi.provider."

    func reload() {
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            providers = []
            return
        }

        providers = json.keys.sorted().map { key in
            let entry = json[key] as? [String: Any] ?? [:]
            let type = entry["type"] as? String ?? "unknown"
            return ProviderAuth(name: key, type: type, ready: true)
        }
    }

    /// API key for a provider from `~/.pi/agent/auth.json` (never shown in UI).
    func apiKey(for provider: String) -> String? {
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = json[provider] as? [String: Any]
        else { return nil }
        if let key = entry["key"] as? String, !key.isEmpty {
            if key.hasPrefix("!") {
                // Command-backed key (Keychain via `security`) — resolve for OpenRouter usage API.
                return runShellKeyCommand(String(key.dropFirst()))
            }
            return key
        }
        if let key = entry["apiKey"] as? String, !key.isEmpty { return key }
        if let key = entry["api_key"] as? String, !key.isEmpty { return key }
        return nil
    }

    var openRouterAPIKey: String? {
        for name in ["openrouter", "OpenRouter"] {
            if let key = apiKey(for: name) { return key }
        }
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for (name, raw) in json {
            guard name.lowercased().contains("openrouter"),
                  let entry = raw as? [String: Any]
            else { continue }
            if let key = entry["key"] as? String, !key.isEmpty {
                if key.hasPrefix("!") { return runShellKeyCommand(String(key.dropFirst())) }
                return key
            }
        }
        return nil
    }

    /// Save an API key in Keychain and point Pi `auth.json` at it (Pi `!command` form).
    func saveAPIKey(_ key: String, for provider: CloudProviderOption) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "AuthStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "API key is empty",
            ])
        }
        let account = provider.piID
        let service = keychainServicePrefix + provider.piID
        try storeInKeychain(password: trimmed, account: account, service: service)

        // Pi resolves `!…` by running the command and using stdout as the key.
        let lookup = "security find-generic-password -a \(shellEscape(account)) -s \(shellEscape(service)) -w"
        try upsertAuthJSON(provider: provider.piID, entry: [
            "type": "api_key",
            "key": "!\(lookup)",
        ])
        reload()
    }

    /// Browser / device OAuth via Pi in Terminal (needs a real TTY).
    func loginWithOAuth(provider: CloudProviderOption) throws {
        guard provider.supportsOAuth else {
            throw NSError(domain: "AuthStore", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(provider.displayName) doesn’t support account sign-in — use an API key.",
            ])
        }
        let pi = resolvePiBinary()
        let cmd = "\(shellEscape(pi)) auth login \(shellEscape(provider.piID)); echo; echo Done — you can close this window.; exec bash"
        let apple = """
        tell application "Terminal"
          activate
          do script \(appleScriptString(cmd))
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", apple]
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw NSError(domain: "AuthStore", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Couldn’t open Terminal for sign-in",
            ])
        }
    }

    func logout(provider: String) async throws {
        // Clear Keychain copy if we created one.
        let service = keychainServicePrefix + provider
        deleteKeychain(account: provider, service: service)
        try await runPiAuth(["logout", provider])
        reload()
    }

    // MARK: - Keychain / auth.json

    private func storeInKeychain(password: String, account: String, service: String) throws {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Keychain save failed (\(status))",
            ])
        }
    }

    private func deleteKeychain(account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func upsertAuthJSON(provider: String, entry: [String: Any]) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: authURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        root[provider] = entry
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: authURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try out.write(to: authURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: authURL.path
        )
    }

    private func runShellKeyCommand(_ command: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-lc", command]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (s?.isEmpty == false) ? s : nil
        } catch {
            return nil
        }
    }

    private func runPiAuth(_ args: [String]) async throws {
        let pi = resolvePiBinary()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pi)
        proc.arguments = ["auth"] + args
        proc.environment = [
            "PATH": "/opt/homebrew/bin:\(NSHomeDirectory())/.npm-global/bin:/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
        ]
        let err = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "auth failed"
            throw NSError(domain: "AuthStore", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private func resolvePiBinary() -> String {
        let candidates = [
            NSHomeDirectory() + "/.npm-global/bin/pi",
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptString(_ s: String) -> String {
        "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }
}

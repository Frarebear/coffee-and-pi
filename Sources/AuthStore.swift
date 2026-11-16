import Foundation

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
        if let key = entry["key"] as? String, !key.isEmpty { return key }
        if let key = entry["apiKey"] as? String, !key.isEmpty { return key }
        if let key = entry["api_key"] as? String, !key.isEmpty { return key }
        return nil
    }

    var openRouterAPIKey: String? {
        let names = ["openrouter", "OpenRouter", "open-router"]
        for name in names {
            if let key = apiKey(for: name) { return key }
        }
        // Case-insensitive scan
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for (name, raw) in json {
            guard name.lowercased().contains("openrouter"),
                  let entry = raw as? [String: Any]
            else { continue }
            if let key = entry["key"] as? String, !key.isEmpty { return key }
            if let key = entry["apiKey"] as? String, !key.isEmpty { return key }
        }
        return nil
    }

    /// Runs `pi auth login <provider>` (API key or browser — Pi handles it).
    func login(provider: String, apiKey: Bool) async throws {
        try await runPiAuth(["login", provider] + (apiKey ? ["--api-key"] : []))
        reload()
    }

    func logout(provider: String) async throws {
        try await runPiAuth(["logout", provider])
        reload()
    }

    private func runPiAuth(_ args: [String]) async throws {
        let pi = NSHomeDirectory() + "/.npm-global/bin/pi"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: FileManager.default.isExecutableFile(atPath: pi) ? pi : "/opt/homebrew/bin/pi")
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
}

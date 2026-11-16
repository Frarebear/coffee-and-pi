import Foundation

/// Installs / verifies Pi, llama.cpp router, and optional MLX for local engines.
/// Never deletes models, auth, or Coffee & Pi data — only creates missing pieces.
@MainActor
final class LocalRuntimeInstaller: ObservableObject {
    struct CheckResult: Equatable {
        var piReady: Bool
        var llamaReady: Bool
        var routerReady: Bool
        var mlxReady: Bool
        var presetsReady: Bool
        var llamaAuthReady: Bool
        var mlxAuthReady: Bool

        var localOK: Bool { piReady && llamaReady && routerReady && presetsReady && llamaAuthReady }
        var mlxOK: Bool { mlxReady && mlxAuthReady }
    }

    @Published private(set) var lastLog: String = ""
    @Published private(set) var check = CheckResult(
        piReady: false, llamaReady: false, routerReady: false, mlxReady: false,
        presetsReady: false, llamaAuthReady: false, mlxAuthReady: false
    )

    private let fm = FileManager.default

    func refresh() {
        let pi = resolvePiPath() != nil
        let llama = resolveLlamaPath() != nil
        let router = resolveRouterPath() != nil
        let mlx = resolveMLXServerPath() != nil
        let presets = fm.fileExists(atPath: presetsPath)
        let auth = loadAuthJSON()
        let llamaAuth = auth["llama.cpp"] != nil
        let mlxAuth = auth["mlx"] != nil
        check = CheckResult(
            piReady: pi,
            llamaReady: llama,
            routerReady: router,
            mlxReady: mlx,
            presetsReady: presets,
            llamaAuthReady: llamaAuth,
            mlxAuthReady: mlxAuth
        )
    }

    /// Install Pi + llama.cpp + router wrapper + presets + llama.cpp auth.
    func setupLocalStack(progress: @escaping (String) -> Void) async throws {
        refresh()
        if !check.piReady {
            progress("Installing Pi…")
            try await installPi()
        } else {
            progress("Pi already installed")
        }

        if !check.llamaReady {
            progress("Installing llama.cpp…")
            try await installLlamaCpp()
        } else {
            progress("llama.cpp already installed")
        }

        progress("Writing llama-router…")
        try writeRouterScript()

        progress("Ensuring models folder…")
        try ensureModelsDir()

        progress("Configuring Pi → llama.cpp…")
        try writeLlamaAuth()

        refresh()
        progress("Local stack ready")
    }

    /// Install mlx-lm (Homebrew) and register an OpenAI-compatible `mlx` provider in Pi.
    func setupMLX(progress: @escaping (String) -> Void) async throws {
        refresh()
        if !check.piReady {
            progress("Installing Pi first…")
            try await installPi()
        }
        if !check.mlxReady {
            progress("Installing mlx-lm via Homebrew…")
            try await run(["/opt/homebrew/bin/brew", "install", "mlx-lm"], label: "brew install mlx-lm")
        } else {
            progress("mlx-lm already installed")
        }
        progress("Registering MLX provider in Pi…")
        try writeMLXAuthAndModels()
        refresh()
        progress("MLX ready — start a model with mlx_lm.server when you want it loaded")
    }

    // MARK: - Paths

    private var home: String { NSHomeDirectory() }
    private var presetsPath: String { home + "/models/presets.ini" }
    private var authPath: String { home + "/.pi/agent/auth.json" }
    private var modelsJSONPath: String { home + "/.pi/agent/models.json" }
    private var routerScriptPath: String { home + "/.local/bin/llama-router" }

    func resolvePiPath() -> String? {
        let candidates = [
            home + "/.npm-global/bin/pi",
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    func resolveLlamaPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/llama",
            home + "/.local/bin/llama",
            "/usr/local/bin/llama",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    func resolveRouterPath() -> String? {
        let candidates = [
            routerScriptPath,
            "/opt/homebrew/bin/llama-router",
            "/usr/local/bin/llama-router",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    func resolveMLXServerPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/mlx_lm.server",
            "/opt/homebrew/opt/mlx-lm/bin/mlx_lm.server",
            home + "/.local/bin/mlx_lm.server",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    // MARK: - Install steps

    private func installPi() async throws {
        // Prefer npm global under ~/.npm-global when that prefix exists.
        let npm = resolveNPM()
        let prefix = home + "/.npm-global"
        if !fm.fileExists(atPath: prefix) {
            try fm.createDirectory(atPath: prefix, withIntermediateDirectories: true)
        }
        try await run([
            npm, "install", "-g", "@earendil-works/pi-coding-agent",
            "--prefix", prefix,
        ], label: "npm install pi")
        // Ensure PATH hint file for shells that don't have it.
        _ = resolvePiPath()
    }

    private func installLlamaCpp() async throws {
        // Official installer from llama.app (same as Pi docs).
        let script = """
        set -euo pipefail
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        curl -LsSf https://llama.app/install.sh | sh
        """
        try await runShell(script, label: "llama.app install")
    }

    private func writeRouterScript() throws {
        let binDir = home + "/.local/bin"
        try fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        let body = """
        #!/usr/bin/env bash
        # ponytail: llama.cpp multi-model router for Coffee & Pi / Pi
        set -euo pipefail
        export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

        PRESET="${LLAMA_MODELS_PRESET:-$HOME/models/presets.ini}"
        HOST="${LLAMA_HOST:-127.0.0.1}"
        PORT="${LLAMA_PORT:-9931}"
        MODELS_MAX="${LLAMA_MODELS_MAX:-2}"

        args=(
          llama serve
          --host "$HOST"
          --port "$PORT"
          --models-preset "$PRESET"
          --no-models-autoload
          --models-max "$MODELS_MAX"
          -ngl all
        )
        if [[ -n "${LLAMA_MODELS_DIR:-}" ]]; then
          args+=(--models-dir "$LLAMA_MODELS_DIR")
        fi
        [[ -n "${LLAMA_CTX:-}" ]] && args+=(-c "$LLAMA_CTX")
        [[ -n "${LLAMA_CTK:-}" ]] && args+=(-ctk "$LLAMA_CTK")
        [[ -n "${LLAMA_CTV:-}" ]] && args+=(-ctv "$LLAMA_CTV")
        args+=("$@")
        exec "${args[@]}"
        """
        let url = URL(fileURLWithPath: routerScriptPath)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: routerScriptPath)
    }

    private func ensureModelsDir() throws {
        let dir = home + "/models"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: presetsPath) {
            let stub = """
            # Coffee & Pi model presets — add GGUF models or download from the app.
            # Example:
            # [gemma4-heretic]
            # model = /Users/YOU/models/gemma-4-12B-it-heretic-Q4_K_M.gguf
            """
            try stub.write(toFile: presetsPath, atomically: true, encoding: .utf8)
        }
    }

    private func writeLlamaAuth() throws {
        var auth = loadAuthJSON()
        auth["llama.cpp"] = [
            "type": "api_key",
            "key": "local",
            "env": ["LLAMA_BASE_URL": "http://127.0.0.1:9931"],
        ]
        try saveAuthJSON(auth)
    }

    private func writeMLXAuthAndModels() throws {
        var auth = loadAuthJSON()
        auth["mlx"] = [
            "type": "api_key",
            "key": "local",
        ]
        try saveAuthJSON(auth)

        // Register openai-compatible MLX endpoint in models.json (merge, don't wipe).
        var root = loadModelsJSON()
        var providers = root["providers"] as? [String: Any] ?? [:]
        var mlx = providers["mlx"] as? [String: Any] ?? [:]
        mlx["baseUrl"] = "http://127.0.0.1:8080/v1"
        mlx["api"] = "openai-completions"
        if mlx["models"] == nil {
            mlx["models"] = [[
                "id": "mlx-local",
                "name": "MLX local (start mlx_lm.server)",
                "reasoning": false,
                "input": ["text"],
                "contextWindow": 8192,
                "maxTokens": 4096,
                "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
            ]] as [[String: Any]]
        }
        providers["mlx"] = mlx
        root["$schema"] = "https://pi.dev/schemas/models.schema.json"
        root["providers"] = providers
        try saveModelsJSON(root)
    }

    // MARK: - Auth helpers (also used by onboarding for API keys)

    func saveAPIKey(provider: String, key: String) throws {
        var auth = loadAuthJSON()
        auth[provider] = [
            "type": "api_key",
            "key": key,
        ]
        try saveAuthJSON(auth)
    }

    func hasProvider(_ id: String) -> Bool {
        loadAuthJSON()[id] != nil
    }

    /// Opens Terminal.app to run interactive `pi auth login` (OAuth / device flows).
    func openInteractivePiLogin(provider: String) throws {
        guard let pi = resolvePiPath() else {
            throw NSError(domain: "LocalRuntimeInstaller", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Pi is not installed yet",
            ])
        }
        let cmd = "\(shellEscape(pi)) auth login \(shellEscape(provider)); echo; echo 'Done — you can close this window.'; exec bash"
        let script = """
        tell application "Terminal"
          activate
          do script "\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw NSError(domain: "LocalRuntimeInstaller", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not open Terminal for Pi login",
            ])
        }
    }

    // MARK: - JSON I/O

    private func loadAuthJSON() -> [String: Any] {
        let dir = (authPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    private func saveAuthJSON(_ auth: [String: Any]) throws {
        let dir = (authPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: auth, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: authPath), options: .atomic)
    }

    private func loadModelsJSON() -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: modelsJSONPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    private func saveModelsJSON(_ root: [String: Any]) throws {
        let dir = (modelsJSONPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: modelsJSONPath), options: .atomic)
    }

    // MARK: - Process helpers

    private func resolveNPM() -> String {
        for p in ["/opt/homebrew/bin/npm", "/usr/local/bin/npm", "/usr/bin/npm"] {
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return "npm"
    }

    private func run(_ args: [String], label: String) async throws {
        lastLog = label
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: args[0])
        proc.arguments = Array(args.dropFirst())
        proc.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:\(home)/.npm-global/bin:\(home)/.local/bin:/usr/bin:/bin",
            "HOME": home,
            "npm_config_prefix": home + "/.npm-global",
        ]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        while proc.isRunning {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if proc.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                ?? String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                ?? "\(label) failed"
            throw NSError(domain: "LocalRuntimeInstaller", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: msg.trimmingCharacters(in: .whitespacesAndNewlines),
            ])
        }
    }

    private func runShell(_ script: String, label: String) async throws {
        lastLog = label
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-lc", script]
        proc.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:/usr/bin:/bin",
            "HOME": home,
        ]
        let err = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = err
        try proc.run()
        while proc.isRunning {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if proc.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "\(label) failed"
            throw NSError(domain: "LocalRuntimeInstaller", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: msg.trimmingCharacters(in: .whitespacesAndNewlines),
            ])
        }
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

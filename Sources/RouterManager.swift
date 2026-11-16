import Foundation

/// Owns the local llama.cpp multi-model router process.
@MainActor
final class RouterManager: ObservableObject {
    struct RouterModel: Identifiable, Hashable {
        let id: String
        let loaded: Bool
        let source: String?
        let downloading: Bool
        /// 0...1 when the router reports progress bytes.
        let progressRatio: Double?
        let modelPath: String?
        /// Context from the model's serve args when known.
        let ctxSize: Int?

        init(
            id: String,
            loaded: Bool,
            source: String?,
            downloading: Bool = false,
            progressRatio: Double? = nil,
            modelPath: String? = nil,
            ctxSize: Int? = nil
        ) {
            self.id = id
            self.loaded = loaded
            self.source = source
            self.downloading = downloading
            self.progressRatio = progressRatio
            self.modelPath = modelPath
            self.ctxSize = ctxSize
        }
    }

    struct DownloadProgress: Equatable {
        var modelID: String
        var message: String
        var ratio: Double?
        var detail: String?
    }

    @Published private(set) var status: RouterStatus = .stopped
    @Published private(set) var routerModels: [RouterModel] = []
    @Published private(set) var downloadProgress: DownloadProgress?
    @Published private(set) var lastDownloadError: String?
    /// Concurrent local model slots (llama-router `LLAMA_MODELS_MAX`).
    @Published private(set) var modelsMax: Int

    private var process: Process?
    private var downloadTask: Task<Void, Never>?
    private let host = "127.0.0.1"
    private let port = 9931
    private let presetsPath = NSHomeDirectory() + "/models/presets.ini"
    private let modelsDir = NSHomeDirectory() + "/models"
    private static let modelsMaxKey = "coffeeandpi.modelsMax"

    var baseURL: URL { URL(string: "http://\(host):\(port)")! }
    var isDownloading: Bool { downloadProgress != nil && downloadTask != nil }
    var loadedCount: Int { routerModels.filter(\.loaded).count }
    var slotsLabel: String { "\(loadedCount)/\(modelsMax) slots" }

    init(modelsMax: Int = 2) {
        let stored = UserDefaults.standard.object(forKey: Self.modelsMaxKey) as? Int
        self.modelsMax = max(1, min(stored ?? modelsMax, 8))
    }

    /// Persist slot capacity and restart router so LRU pool matches.
    func setModelsMax(_ n: Int) async throws {
        let clamped = max(1, min(n, 8))
        guard clamped != modelsMax else { return }
        modelsMax = clamped
        UserDefaults.standard.set(clamped, forKey: Self.modelsMaxKey)
        try await restartRouter()
    }

    func ensureRunning() async {
        if case .running = status {
            await refresh()
            return
        }
        if await isReachable() {
            await refresh()
            return
        }

        status = .starting
        do {
            try startProcess()
            for _ in 0..<40 {
                try await Task.sleep(nanoseconds: 250_000_000)
                if await isReachable() {
                    await refresh()
                    return
                }
            }
            status = .error("Router started but never became reachable on :\(port)")
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func refresh() async {
        guard await isReachable() else {
            if process?.isRunning != true { status = .stopped }
            return
        }
        var models = await fetchModels()
        // Drop HF-cache clones that are the same weights as a friendly preset.
        let removed = await pruneDuplicateCacheModels(models)
        if !removed.isEmpty {
            models = await fetchModels()
        }
        models = Self.dedupeForPicker(models)
        routerModels = models
        let loaded = models.filter(\.loaded).map(\.id)
        status = .running(models: loaded)
        syncPiModelsJSON(with: models)
    }

    /// Permanent remove from the router catalog (`DELETE /models?model=`).
    func removeModel(_ id: String) async {
        var comps = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "model", value: id)]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.timeoutInterval = 30
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Load a model instance on the router (LRU unload if models-max hit).
    func loadModel(_ id: String) async throws {
        try await postJSON(path: "models/load", body: ["model": id], timeout: 120)
        await refresh()
    }

    func unloadModel(_ id: String) async throws {
        try await postJSON(path: "models/unload", body: ["model": id], timeout: 60)
        await refresh()
    }

    /// Paste a Hugging Face URL / `owner/repo[:quant]` and download via the llama.cpp router.
    @discardableResult
    func downloadFromHuggingFace(_ raw: String) async throws -> String {
        let ref = try HuggingFaceModelRef.parse(raw)
        let modelID = ref.routerModelID
        lastDownloadError = nil
        downloadTask?.cancel()

        downloadProgress = DownloadProgress(modelID: modelID, message: "Starting download…", ratio: nil, detail: ref.repoID)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.ensureRunning()
                try await self.postJSON(path: "models", body: ["model": modelID], timeout: 30)
                self.downloadProgress = DownloadProgress(modelID: modelID, message: "Downloading…", ratio: nil, detail: modelID)

                var sawDownloading = false
                var polls = 0
                while !Task.isCancelled {
                    polls += 1
                    await self.refresh()
                    if let entry = self.routerModels.first(where: { $0.id == modelID }) {
                        if entry.downloading {
                            sawDownloading = true
                            let pct = entry.progressRatio.map { Int(($0 * 100).rounded()) }
                            self.downloadProgress = DownloadProgress(
                                modelID: modelID,
                                message: pct.map { "Downloading \($0)%" } ?? "Downloading…",
                                ratio: entry.progressRatio,
                                detail: modelID
                            )
                        } else if sawDownloading || polls >= 3 {
                            // Available in catalog (unloaded/loaded) after download.
                            self.registerPresetIfPossible(ref: ref, model: entry)
                            self.downloadProgress = DownloadProgress(
                                modelID: modelID,
                                message: "Downloaded",
                                ratio: 1,
                                detail: modelID
                            )
                            try? await Task.sleep(nanoseconds: 800_000_000)
                            self.downloadProgress = nil
                            self.downloadTask = nil
                            return
                        }
                    } else if sawDownloading && polls >= 4 {
                        // Finished and briefly disappeared from list — refresh hard.
                        break
                    }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }

                await self.refresh()
                if let entry = self.routerModels.first(where: { $0.id == modelID }) {
                    self.registerPresetIfPossible(ref: ref, model: entry)
                }
                self.downloadProgress = nil
                self.downloadTask = nil
            } catch is CancellationError {
                try? await self.unloadModel(modelID)
                self.downloadProgress = nil
                self.downloadTask = nil
            } catch {
                self.lastDownloadError = error.localizedDescription
                self.downloadProgress = nil
                self.downloadTask = nil
            }
        }
        downloadTask = task
        await task.value

        if let err = lastDownloadError {
            throw NSError(domain: "RouterManager", code: 1, userInfo: [NSLocalizedDescriptionKey: err])
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        // Prefer the friendly preset in the picker (HF id may already be pruned).
        if routerModels.contains(where: { $0.id == ref.shortPresetID }) {
            return ref.shortPresetID
        }
        return modelID
    }

    func cancelDownload() async {
        let id = downloadProgress?.modelID
        downloadTask?.cancel()
        downloadTask = nil
        if let id {
            try? await unloadModel(id)
        }
        downloadProgress = nil
    }

    func stopOwnedProcess() {
        process?.terminate()
        process = nil
        if case .running = status { status = .stopped }
    }

    // MARK: - Presets

    /// Write per-model knobs into presets.ini (+ Pi compaction overrides).
    func writeProfilePreset(_ profile: LocalModelProfile) {
        let path = profile.modelPath
            ?? routerModels.first(where: { $0.id == profile.id })?.modelPath
            ?? findModelPath(forRouterID: profile.id)
        upsertPreset(
            id: profile.id,
            modelPath: path,
            hfRepo: path == nil ? profile.id : nil,
            ctxSize: profile.ctxSize,
            cacheTypeK: profile.cacheTypeK,
            cacheTypeV: profile.cacheTypeV
        )
        syncPiCompactionOverride(for: profile)
    }

    /// Write knobs and restart the router so ctx / KV take effect.
    func applyProfile(_ profile: LocalModelProfile, reloadModel: Bool) async throws {
        writeProfilePreset(profile)
        try await restartRouter()
        if reloadModel {
            try await loadModel(profile.id)
        }
    }

    /// Soft-restart llama router so presets.ini is re-read.
    func restartRouter() async throws {
        let wasOwned = process?.isRunning == true
        if wasOwned {
            process?.terminate()
            process = nil
        } else {
            // LaunchAgent / external process — terminate listeners on our port.
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            task.arguments = ["-f", "llama serve .*--port \(port)"]
            try? task.run()
            task.waitUntilExit()
        }
        status = .starting
        // Give the old process a moment to die; LaunchAgent KeepAlive will respawn.
        try await Task.sleep(nanoseconds: 600_000_000)
        let reachable = await isReachable()
        if wasOwned || !reachable {
            try startProcess()
        }
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if await isReachable() {
                await refresh()
                return
            }
        }
        status = .error("Router did not come back after restart")
        throw NSError(domain: "RouterManager", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Router did not come back after restart",
        ])
    }

    /// Add/update a short alias in ~/models/presets.ini when we know the GGUF path.
    private func registerPresetIfPossible(ref: HuggingFaceModelRef, model: RouterModel) {
        let path = model.modelPath ?? findCachedGGUF(for: ref)
        ensureModelsDir()
        var modelPathForPreset = path
        if let path, FileManager.default.fileExists(atPath: path) {
            let linkName: String = {
                if let q = ref.quantization {
                    return "\(ref.repo)-\(q).gguf"
                }
                return (path as NSString).lastPathComponent
            }()
            let linkPath = (modelsDir as NSString).appendingPathComponent(linkName)
            if !FileManager.default.fileExists(atPath: linkPath) {
                try? FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: path)
            }
            if FileManager.default.fileExists(atPath: linkPath) {
                modelPathForPreset = linkPath
            }
        }
        // One friendly preset only — avoid listing the same GGUF twice (short + HF id).
        upsertPreset(
            id: ref.shortPresetID,
            modelPath: modelPathForPreset,
            hfRepo: modelPathForPreset == nil ? ref.routerModelID : nil,
            ctxSize: LocalModelProfile.autoCtxSize,
            cacheTypeK: "q8_0",
            cacheTypeV: "q8_0"
        )
        // Catalog still has the raw HF id from download; drop it once the preset exists.
        if ref.shortPresetID != ref.routerModelID {
            Task { await self.removeModel(ref.routerModelID) }
        }
    }

    /// Remove unloaded cache entries that resolve to the same file as a preset.
    private func pruneDuplicateCacheModels(_ models: [RouterModel]) async -> [String] {
        let presets = models.filter { $0.source == "preset" }
        guard !presets.isEmpty else { return [] }

        var presetFileKeys = Set<String>()
        let presetIDs = Set(presets.map { $0.id.lowercased() })
        for p in presets {
            if let path = p.modelPath {
                presetFileKeys.insert(Self.identityKey(forPath: path))
            }
        }

        var removed: [String] = []
        for m in models where m.source == "cache" && !m.loaded && !m.downloading {
            let cachePath = m.modelPath ?? findCachedGGUF(forRouterID: m.id)
            let sameFile = cachePath.map { presetFileKeys.contains(Self.identityKey(forPath: $0)) } ?? false
            let shortTaken: Bool = {
                guard let ref = try? HuggingFaceModelRef.parse(m.id) else { return false }
                return presetIDs.contains(ref.shortPresetID.lowercased())
            }()
            if sameFile || shortTaken {
                await removeModel(m.id)
                removed.append(m.id)
            }
        }
        return removed
    }

    private func findCachedGGUF(forRouterID id: String) -> String? {
        guard let ref = try? HuggingFaceModelRef.parse(id) else { return nil }
        return findCachedGGUF(for: ref)
    }

    /// Collapse remaining same-file duplicates for the picker (prefer loaded → preset → short id).
    private static func dedupeForPicker(_ models: [RouterModel]) -> [RouterModel] {
        var byKey: [String: RouterModel] = [:]
        let ranked = models.sorted { a, b in
            score(a) > score(b)
        }
        for m in ranked {
            let key: String = {
                if let path = m.modelPath {
                    return identityKey(forPath: path)
                }
                return "id:\(m.id.lowercased())"
            }()
            if byKey[key] == nil {
                byKey[key] = m
            }
        }
        return Array(byKey.values).sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    private static func score(_ m: RouterModel) -> Int {
        var s = 0
        if m.loaded { s += 100 }
        if m.source == "preset" { s += 50 }
        if !m.id.contains("/") { s += 20 }
        if m.id.count < 40 { s += 5 }
        return s
    }

    private static func identityKey(forPath path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let resolved = url.resolvingSymlinksInPath().path
        return "file:\(resolved)"
    }

    private func findModelPath(forRouterID id: String) -> String? {
        if let path = routerModels.first(where: { $0.id == id })?.modelPath {
            return path
        }
        // Try HF-style id → cache
        if let ref = try? HuggingFaceModelRef.parse(id) {
            return findCachedGGUF(for: ref)
        }
        return nil
    }

    private func ensureModelsDir() {
        try? FileManager.default.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)
    }

    private func findCachedGGUF(for ref: HuggingFaceModelRef) -> String? {
        let hub = NSHomeDirectory() + "/.cache/huggingface/hub"
        let folder = "models--\(ref.owner)--\(ref.repo)"
        let root = (hub as NSString).appendingPathComponent(folder)
        let snapshots = (root as NSString).appendingPathComponent("snapshots")
        guard let snapDirs = try? FileManager.default.contentsOfDirectory(atPath: snapshots) else { return nil }

        let wantQuant = (ref.quantization ?? "Q4_K_M").uppercased()
        var candidates: [String] = []
        for snap in snapDirs {
            let snapPath = (snapshots as NSString).appendingPathComponent(snap)
            if let files = try? FileManager.default.contentsOfDirectory(atPath: snapPath) {
                for f in files where f.lowercased().hasSuffix(".gguf") && !f.lowercased().hasPrefix("mmproj") {
                    candidates.append((snapPath as NSString).appendingPathComponent(f))
                }
            }
        }
        if let filename = ref.filename {
            if let hit = candidates.first(where: { ($0 as NSString).lastPathComponent == filename }) {
                return hit
            }
        }
        if let hit = candidates.first(where: { ($0 as NSString).lastPathComponent.uppercased().contains(wantQuant) }) {
            return hit
        }
        return candidates.first
    }

    private func upsertPreset(
        id: String,
        modelPath: String?,
        hfRepo: String?,
        ctxSize: Int,
        cacheTypeK: String,
        cacheTypeV: String
    ) {
        let fm = FileManager.default
        ensureModelsDir()
        if !fm.fileExists(atPath: presetsPath) {
            let seed = """
            # llama.cpp router presets — managed by Coffee & Pi
            [*]
            flash-attn = on
            n-gpu-layers = 999
            kv-unified = 1
            parallel = 1
            batch-size = 2048
            ubatch-size = 512
            ctx-size = 32768
            cache-type-k = q8_0
            cache-type-v = q8_0
            jinja = 1
            reasoning = off

            """
            try? seed.write(toFile: presetsPath, atomically: true, encoding: .utf8)
        }
        guard var text = try? String(contentsOfFile: presetsPath, encoding: .utf8) else { return }

        var lines: [String] = ["[\(id)]"]
        if let modelPath, !modelPath.isEmpty {
            lines.append("model = \(modelPath)")
        } else if let hfRepo, !hfRepo.isEmpty {
            lines.append("hf-repo = \(hfRepo)")
        }
        if ctxSize <= 0 {
            // 0 = model default; llama.cpp `--fit` may raise/lower to free Metal memory.
            lines.append("ctx-size = 0")
            lines.append("fit = on")
            lines.append("fit-ctx = 4096")
            lines.append("fit-target = 2048")
        } else {
            lines.append("ctx-size = \(ctxSize)")
            // Explicit ctx — don't let fit silently shrink it.
            lines.append("fit = off")
        }
        lines.append("cache-type-k = \(cacheTypeK)")
        lines.append("cache-type-v = \(cacheTypeV)")
        let block = lines.joined(separator: "\n") + "\n"

        let escaped = NSRegularExpression.escapedPattern(for: id)
        if let range = text.range(of: #"\["# + escaped + #"\][^\[]*"#, options: .regularExpression) {
            text.replaceSubrange(range, with: block)
        } else {
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\n" + block
        }
        try? text.write(toFile: presetsPath, atomically: true, encoding: .utf8)
    }

    private func syncPiCompactionOverride(for profile: LocalModelProfile) {
        let settingsURL = URL(fileURLWithPath: NSHomeDirectory() + "/.pi/agent/settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = obj
        }
        var compaction = settings["compaction"] as? [String: Any] ?? [:]
        // Keep global enabled true; session RPC flips per active model.
        if compaction["enabled"] == nil { compaction["enabled"] = true }
        var overrides = compaction["modelOverrides"] as? [String: Any] ?? [:]
        let key = "llama.cpp/\(profile.id)"
        // Reserve ~1/4 of ctx (capped) so autocompact triggers before OOM.
        let ctx = profile.effectiveCtxSize
        let reserve = min(16384, max(2048, ctx / 4))
        let keep = min(20000, max(4096, ctx / 2))
        overrides[key] = [
            "reserveTokens": reserve,
            "keepRecentTokens": keep,
        ]
        compaction["modelOverrides"] = overrides
        settings["compaction"] = compaction
        if let out = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: settingsURL, options: .atomic)
        }
    }

    // MARK: - Pi models.json sync so set_model can see router models

    private func syncPiModelsJSON(with models: [RouterModel]) {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.pi/agent/models.json")
        var providers: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let p = existing["providers"] as? [String: Any] {
            providers = p
        }

        var llama = providers["llama.cpp"] as? [String: Any] ?? [:]
        llama["baseUrl"] = "http://127.0.0.1:9931/v1"
        llama["api"] = "openai-completions"
        llama["apiKey"] = "local"

        let profilesURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CoffeeAndPi/model-profiles.json")
        var ctxByID: [String: Int] = [:]
        if let data = try? Data(contentsOf: profilesURL),
           let rows = try? JSONDecoder().decode([LocalModelProfile].self, from: data) {
            for p in rows { ctxByID[p.id] = p.effectiveCtxSize }
        }

        let piModels: [[String: Any]] = models.map { m in
            let ctx = m.ctxSize ?? ctxByID[m.id] ?? 32768
            return [
                "id": m.id,
                "name": m.id,
                "reasoning": true,
                "input": ["text"],
                "contextWindow": ctx,
                "maxTokens": ctx,
                "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
            ]
        }
        llama["models"] = piModels
        providers["llama.cpp"] = llama

        let root: [String: Any] = [
            "$schema": "https://pi.dev/schemas/models.schema.json",
            "providers": providers,
        ]
        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: url, options: .atomic)
        }

        // Enable all local models in settings
        let settingsURL = URL(fileURLWithPath: NSHomeDirectory() + "/.pi/agent/settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = obj
        }
        var enabled = Set(settings["enabledModels"] as? [String] ?? [])
        for m in models { enabled.insert("llama.cpp/\(m.id)") }
        settings["enabledModels"] = Array(enabled).sorted()
        if settings["defaultProvider"] == nil { settings["defaultProvider"] = "llama.cpp" }
        if settings["defaultModel"] == nil { settings["defaultModel"] = models.first?.id ?? "gemma4-heretic" }
        if let out = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: settingsURL, options: .atomic)
        }
    }

    private func startProcess() throws {
        let router = resolveRouterBinary()
        let proc = Process()
        proc.executableURL = router
        proc.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            "LLAMA_HOST": host,
            "LLAMA_PORT": String(port),
            "LLAMA_MODELS_MAX": String(modelsMax),
            "LLAMA_MODELS_PRESET": NSHomeDirectory() + "/models/presets.ini",
        ]
        let logPath = NSHomeDirectory() + "/Library/Logs/coffee-and-pi-router.log"
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        let log = FileHandle(forWritingAtPath: logPath)
        proc.standardOutput = log
        proc.standardError = log
        try proc.run()
        process = proc
    }

    private func resolveRouterBinary() -> URL {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/llama-router",
            "/opt/homebrew/bin/llama-router",
            "/usr/local/bin/llama-router",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/opt/homebrew/bin/llama")
    }

    private func isReachable() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        req.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func fetchModels() async -> [RouterModel] {
        // Prefer /models (includes download progress); fall back to /v1/models.
        if let rows = await fetchModelRows(path: "models") {
            return rows.compactMap(Self.parseModel(row:))
        }
        if let rows = await fetchModelRows(path: "v1/models") {
            return rows.compactMap(Self.parseModel(row:))
        }
        return []
    }

    private func fetchModelRows(path: String) async -> [[String: Any]]? {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return json?["data"] as? [[String: Any]]
        } catch {
            return nil
        }
    }

    private static func parseModel(row: [String: Any]) -> RouterModel? {
        guard let id = row["id"] as? String else { return nil }
        let statusObj = row["status"] as? [String: Any]
        let status = statusObj?["value"] as? String
        let progress = progressRatio(from: statusObj?["progress"])
        let args = statusObj?["args"] as? [String]
        let modelPath = modelPath(fromArgs: args)
        let ctx = ctxSize(fromArgs: args) ?? (row["context_length"] as? Int)
        return RouterModel(
            id: id,
            loaded: status == "loaded",
            source: row["source"] as? String,
            downloading: status == "downloading",
            progressRatio: progress,
            modelPath: modelPath,
            ctxSize: ctx
        )
    }

    private static func progressRatio(from raw: Any?) -> Double? {
        guard let map = raw as? [String: Any] else { return nil }
        var done: Double = 0
        var total: Double = 0
        for (_, value) in map {
            if let part = value as? [String: Any] {
                if let d = part["done"] as? Double { done += d }
                else if let d = part["done"] as? Int { done += Double(d) }
                if let t = part["total"] as? Double { total += t }
                else if let t = part["total"] as? Int { total += Double(t) }
            }
        }
        guard total > 0 else { return nil }
        return min(1, max(0, done / total))
    }

    private static func modelPath(fromArgs args: [String]?) -> String? {
        guard let args else { return nil }
        if let idx = args.firstIndex(of: "--model"), idx + 1 < args.count {
            return args[idx + 1]
        }
        if let idx = args.firstIndex(of: "-m"), idx + 1 < args.count {
            return args[idx + 1]
        }
        return nil
    }

    private static func ctxSize(fromArgs args: [String]?) -> Int? {
        guard let args else { return nil }
        if let idx = args.firstIndex(of: "--ctx-size"), idx + 1 < args.count, let n = Int(args[idx + 1]), n > 0 {
            return n
        }
        if let idx = args.firstIndex(of: "-c"), idx + 1 < args.count, let n = Int(args[idx + 1]), n > 0 {
            return n
        }
        return nil
    }

    private func postJSON(path: String, body: [String: Any], timeout: TimeInterval) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? "request failed (\(code))"
            if path.hasSuffix("load"), msg.contains("already running") {
                return
            }
            throw NSError(domain: "RouterManager", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
}

import Foundation

/// Per-model knobs: llama.cpp ctx/KV + Pi autocompact + system prompt.
struct LocalModelProfile: Identifiable, Hashable, Codable {
    /// Router model id (preset name or `owner/repo:QUANT`).
    var id: String
    var displayName: String?
    var modelPath: String?
    /// `0` = Auto (llama.cpp `--fit` sizes ctx to free device memory).
    var ctxSize: Int
    /// Last fitted/observed context when `ctxSize == 0`.
    var fittedCtxSize: Int?
    var cacheTypeK: String
    var cacheTypeV: String
    var autoCompaction: Bool
    var systemPrompt: String

    static let cacheTypes = ["q8_0", "q4_0", "q4_1", "q5_0", "q5_1", "iq4_nl", "f16", "bf16", "f32"]
    /// Includes `0` for Auto.
    static let ctxSizes = [0, 4096, 8192, 16384, 32768, 65536, 131072, 262144]

    static let autoCtxSize = 0

    var isAutoCtx: Bool { ctxSize == Self.autoCtxSize }

    /// Effective context for Pi / UI (fitted estimate when Auto).
    var effectiveCtxSize: Int {
        if isAutoCtx {
            return fittedCtxSize ?? 32768
        }
        return max(ctxSize, 4096)
    }

    static func defaults(id: String, modelPath: String? = nil) -> LocalModelProfile {
        LocalModelProfile(
            id: id,
            displayName: nil,
            modelPath: modelPath,
            ctxSize: autoCtxSize,
            fittedCtxSize: nil,
            cacheTypeK: "q8_0",
            cacheTypeV: "q8_0",
            autoCompaction: true,
            systemPrompt: ""
        )
    }

    var menuLabel: String { displayName ?? id }

    static func ctxLabel(_ n: Int, fitted: Int? = nil) -> String {
        if n == autoCtxSize {
            if let fitted {
                return "Auto · \(fitted.formatted())"
            }
            return "Auto (fit hardware)"
        }
        return n.formatted()
    }
}

@MainActor
final class ModelProfileStore: ObservableObject {
    @Published var profiles: [LocalModelProfile] = []

    private var fileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CoffeeAndPi", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("model-profiles.json")
    }

    func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([LocalModelProfile].self, from: data) {
            profiles = decoded
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func profile(for id: String) -> LocalModelProfile {
        if let existing = profiles.first(where: { $0.id == id }) {
            return existing
        }
        return LocalModelProfile.defaults(id: id)
    }

    func upsert(_ profile: LocalModelProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        profiles.sort { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        save()
    }

    /// Ensure every router model has a profile row (without clobbering edits).
    func ensureProfiles(for routerIDs: [String], paths: [String: String] = [:]) {
        var changed = false
        for id in routerIDs {
            if !profiles.contains(where: { $0.id == id }) {
                profiles.append(LocalModelProfile.defaults(id: id, modelPath: paths[id]))
                changed = true
            } else if let path = paths[id], let idx = profiles.firstIndex(where: { $0.id == id }),
                      profiles[idx].modelPath == nil {
                profiles[idx].modelPath = path
                changed = true
            }
        }
        if changed {
            profiles.sort { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
            save()
        }
    }
}

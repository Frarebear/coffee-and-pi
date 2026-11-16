import Foundation

/// Tracks local Coffee & Pi usage per provider, plus live OpenRouter key credits.
@MainActor
final class UsageStore: ObservableObject {
    struct ProviderStats: Identifiable, Hashable, Codable {
        var id: String { provider }
        var provider: String
        var messages: Int
        var estimatedTokens: Int
        var lastUsedAt: Date?

        var kindLabel: String {
            let p = provider.lowercased()
            if p == "openrouter" { return "pay-as-you-go" }
            if p == "llama.cpp" || p.contains("llama") { return "local" }
            return "subscription / cloud"
        }
    }

    struct OpenRouterSnapshot: Hashable {
        var label: String?
        var usage: Double
        var usageDaily: Double
        var usageWeekly: Double
        var usageMonthly: Double
        var limit: Double?
        var limitRemaining: Double?
        var fetchedAt: Date
        var error: String?

        var remainingLabel: String {
            if let rem = limitRemaining {
                return String(format: "$%.2f left", rem)
            }
            if let limit {
                return String(format: "$%.2f limit · $%.2f used", limit, usage)
            }
            return String(format: "$%.2f used", usage)
        }
    }

    @Published private(set) var stats: [ProviderStats] = []
    @Published private(set) var openRouter: OpenRouterSnapshot?
    @Published private(set) var isRefreshingOpenRouter = false

    private var fileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CoffeeAndPi", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("usage.json")
    }

    func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([ProviderStats].self, from: data) {
            stats = decoded.sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(stats) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Rough local counter after a settled assistant reply.
    func recordTurn(provider: String, userChars: Int, assistantChars: Int) {
        let key = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let tokens = max(1, (userChars + assistantChars) / 4)
        if let idx = stats.firstIndex(where: { $0.provider == key }) {
            stats[idx].messages += 1
            stats[idx].estimatedTokens += tokens
            stats[idx].lastUsedAt = Date()
        } else {
            stats.append(ProviderStats(
                provider: key,
                messages: 1,
                estimatedTokens: tokens,
                lastUsedAt: Date()
            ))
        }
        stats.sort { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
        save()
    }

    func refreshOpenRouter(apiKey: String?) async {
        guard let apiKey, !apiKey.isEmpty else {
            openRouter = nil
            return
        }
        isRefreshingOpenRouter = true
        defer { isRefreshingOpenRouter = false }

        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 12

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP \(code)"
                openRouter = OpenRouterSnapshot(
                    label: nil, usage: 0, usageDaily: 0, usageWeekly: 0, usageMonthly: 0,
                    limit: nil, limitRemaining: nil, fetchedAt: Date(), error: msg
                )
                return
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let row = json?["data"] as? [String: Any] ?? [:]
            openRouter = OpenRouterSnapshot(
                label: row["label"] as? String ?? row["name"] as? String,
                usage: Self.dbl(row["usage"]),
                usageDaily: Self.dbl(row["usage_daily"]),
                usageWeekly: Self.dbl(row["usage_weekly"]),
                usageMonthly: Self.dbl(row["usage_monthly"]),
                limit: Self.optDbl(row["limit"]),
                limitRemaining: Self.optDbl(row["limit_remaining"]),
                fetchedAt: Date(),
                error: nil
            )
        } catch {
            openRouter = OpenRouterSnapshot(
                label: nil, usage: 0, usageDaily: 0, usageWeekly: 0, usageMonthly: 0,
                limit: nil, limitRemaining: nil, fetchedAt: Date(), error: error.localizedDescription
            )
        }
    }

    private static func dbl(_ any: Any?) -> Double {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        if let i = any as? Int { return Double(i) }
        return 0
    }

    private static func optDbl(_ any: Any?) -> Double? {
        if any is NSNull || any == nil { return nil }
        return dbl(any)
    }
}

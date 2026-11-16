import Foundation

/// Persists chat threads under Application Support (UI mirror of Pi sessions).
@MainActor
final class ChatStore {
    private var fileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CoffeeAndPi", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("chats.json")
    }

    var sessionsDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CoffeeAndPi/pi-sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func load() -> [ChatThread] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([ChatThread].self, from: data) else { return [] }
        return decoded.map { thread in
            var t = thread
            // Never restore mid-stream flags.
            t.isBusy = false
            t.messages = t.messages.map { msg in
                var m = msg
                m.isStreaming = false
                m.streamPhase = .idle
                m.activeToolName = nil
                return m
            }
            return t
        }
    }

    func save(_ threads: [ChatThread]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(threads) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

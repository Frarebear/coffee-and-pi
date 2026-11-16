import Foundation

/// Builds table transcripts and turn prompts for multi-Bean chats.
enum TableTurnCoordinator {
    static let transcriptWindow = 40

    static func transcriptSnippet(messages: [ChatMessage], beans: [UUID: Bean], limit: Int = transcriptWindow) -> String {
        let slice = messages.suffix(limit)
        return slice.map { msg in
            let who: String = {
                if msg.role == .user, msg.speakerBeanID == nil { return "You" }
                if let id = msg.speakerBeanID, let bean = beans[id] { return bean.name }
                switch msg.role {
                case .assistant: return "Assistant"
                case .system: return "System"
                case .tool: return "Tool"
                case .user: return "You"
                }
            }()
            return "\(who): \(msg.text)"
        }.joined(separator: "\n")
    }

    static func tableSystemRules(bean: Bean, seats: [Bean], transcript: String) -> String {
        let names = seats.map(\.name).joined(separator: ", ")
        return """
        You are \(bean.name), a Coffee & Pi bean seated at a shared table with: \(names).
        You are talking with the other beans and the human. Stay in character.
        Keep replies concise (a few sentences) unless asked for depth.
        Do not speak for other beans — only as \(bean.name).

        Recent table transcript:
        \(transcript.isEmpty ? "(empty — open the conversation)" : transcript)
        """
    }

    static func handoffBlock(from thread: ChatThread, beans: [UUID: Bean]) -> String {
        let speakers = Dictionary(uniqueKeysWithValues: beans.map { ($0.key, $0.value) })
        let body = transcriptSnippet(messages: thread.messages, beans: speakers, limit: 30)
        return """

        --- Handoff from chat "\(thread.title)" (\(thread.id.uuidString.prefix(8))) ---
        \(body.isEmpty ? "(no messages yet)" : body)
        --- End handoff ---
        """
    }

    /// Compact handoff from an external transcript file (e.g. Cursor agent JSONL).
    static func handoffBlock(fromExternal title: String, body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped: String = {
            if trimmed.count <= 12_000 { return trimmed }
            return String(trimmed.suffix(12_000))
        }()
        return """

        --- Handoff from external transcript "\(title)" ---
        \(clipped.isEmpty ? "(empty file)" : clipped)
        --- End handoff ---
        """
    }

    /// Best-effort extract of readable text from Cursor / agent JSONL.
    static func summarizeJSONL(_ data: Data) -> String {
        guard let raw = String(data: data, encoding: .utf8) else { return "" }
        var linesOut: [String] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let s = String(line)
            guard let d = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { continue }
            if let text = flattenJSONLText(obj) {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { linesOut.append(t) }
            }
            if linesOut.count >= 40 { break }
        }
        if linesOut.isEmpty {
            // Fallback: first ~4k of raw file
            return String(raw.prefix(4000))
        }
        return linesOut.joined(separator: "\n")
    }

    private static func flattenJSONLText(_ obj: [String: Any]) -> String? {
        if let role = obj["role"] as? String, let content = obj["content"] as? String {
            return "\(role): \(content)"
        }
        if let message = obj["message"] as? [String: Any] {
            let role = (message["role"] as? String) ?? "message"
            if let content = message["content"] as? String {
                return "\(role): \(content)"
            }
            if let parts = message["content"] as? [[String: Any]] {
                let texts = parts.compactMap { $0["text"] as? String }
                if !texts.isEmpty { return "\(role): \(texts.joined(separator: " "))" }
            }
        }
        if let content = obj["content"] as? String { return content }
        if let text = obj["text"] as? String { return text }
        return nil
    }

    /// Parse `@BeanName` mentions from user text (case-insensitive, word boundary).
    static func mentionedBeanIDs(in text: String, beans: [Bean]) -> [UUID] {
        var hits: [UUID] = []
        let lower = text.lowercased()
        for bean in beans {
            let token = "@\(bean.name.lowercased())"
            if lower.contains(token) {
                hits.append(bean.id)
            }
        }
        return hits
    }
}

import Foundation

enum ThinkingLevel: String, CaseIterable, Identifiable, Codable {
    case off, minimal, low, medium, high, xhigh, max
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "XHigh"
        case .max: return "Max"
        }
    }
}

struct PiModel: Identifiable, Hashable, Codable {
    var id: String { "\(provider)/\(modelId)" }
    let provider: String
    let modelId: String
    var name: String?
    var reasoning: Bool?
    var loaded: Bool?

    var displayName: String {
        let base = name ?? modelId
        if let loaded {
            return loaded ? base : "\(base) · not loaded"
        }
        return base
    }

    var menuLabel: String { "\(provider) · \(displayName)" }
}

enum ChatKind: String, Codable, Hashable {
    case solo
    case table
}

/// Live assistant activity while a turn is in flight.
enum StreamPhase: String, Codable, Hashable {
    case idle
    case starting
    case thinking
    case responding
    case tooling
    case retrying

    var statusLabel: String {
        switch self {
        case .idle: return ""
        case .starting: return "Starting…"
        case .thinking: return "Thinking…"
        case .responding: return "Responding…"
        case .tooling: return "Working…"
        case .retrying: return "Retrying…"
        }
    }
}

struct ChatMessage: Identifiable, Hashable, Codable {
    enum Role: String, Codable { case user, assistant, system, tool }
    let id: String
    var role: Role
    var text: String
    /// Streamed model thinking / reasoning (when the provider emits it).
    var thinkingText: String = ""
    var isStreaming: Bool = false
    var streamPhase: StreamPhase = .idle
    /// Active tool name while `streamPhase == .tooling`.
    var activeToolName: String?
    /// True when `text` is a failure notice (style as error, not normal reply).
    var isError: Bool = false
    /// Which Bean spoke; `nil` = you / system.
    var speakerBeanID: UUID?

    enum CodingKeys: String, CodingKey {
        case id, role, text, thinkingText, isStreaming, streamPhase, activeToolName, isError, speakerBeanID
    }

    init(
        id: String = UUID().uuidString,
        role: Role,
        text: String,
        thinkingText: String = "",
        isStreaming: Bool = false,
        streamPhase: StreamPhase = .idle,
        activeToolName: String? = nil,
        isError: Bool = false,
        speakerBeanID: UUID? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.thinkingText = thinkingText
        self.isStreaming = isStreaming
        self.streamPhase = streamPhase
        self.activeToolName = activeToolName
        self.isError = isError
        self.speakerBeanID = speakerBeanID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        thinkingText = try c.decodeIfPresent(String.self, forKey: .thinkingText) ?? ""
        isStreaming = try c.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        streamPhase = try c.decodeIfPresent(StreamPhase.self, forKey: .streamPhase) ?? .idle
        activeToolName = try c.decodeIfPresent(String.self, forKey: .activeToolName)
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        speakerBeanID = try c.decodeIfPresent(UUID.self, forKey: .speakerBeanID)
    }
}

/// A Bean = agent personality (coffee beans). Can sit in a project or free-floating.
struct Bean: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var instructions: String
    /// `nil` = lives outside any project.
    var projectID: UUID?
    var defaultProvider: String?
    var defaultModelId: String?
    var defaultThinking: ThinkingLevel
    var allowsSelfEdit: Bool
    /// Accent hue 0...1 for the bean tile.
    var accentHue: Double
    /// Soft-delete: hidden from main lists until restored or permanently deleted.
    var archivedAt: Date?
    /// Grokbot-style: after create, open a chat and let the bean greet from its name alone.
    var awaitingFirstMessage: Bool

    var isArchived: Bool { archivedAt != nil }

    enum CodingKeys: String, CodingKey {
        case id, name, instructions, projectID, defaultProvider, defaultModelId
        case defaultThinking, allowsSelfEdit, accentHue, archivedAt, awaitingFirstMessage
    }

    init(
        id: UUID = UUID(),
        name: String,
        instructions: String,
        projectID: UUID? = nil,
        defaultProvider: String? = "llama.cpp",
        defaultModelId: String? = "gemma4-heretic",
        defaultThinking: ThinkingLevel = .off,
        allowsSelfEdit: Bool = true,
        accentHue: Double = Double.random(in: 0.05...0.12), // coffee browns by default
        archivedAt: Date? = nil,
        awaitingFirstMessage: Bool = false
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.projectID = projectID
        self.defaultProvider = defaultProvider
        self.defaultModelId = defaultModelId
        self.defaultThinking = defaultThinking
        self.allowsSelfEdit = allowsSelfEdit
        self.accentHue = accentHue
        self.archivedAt = archivedAt
        self.awaitingFirstMessage = awaitingFirstMessage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        instructions = try c.decode(String.self, forKey: .instructions)
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        defaultProvider = try c.decodeIfPresent(String.self, forKey: .defaultProvider)
        defaultModelId = try c.decodeIfPresent(String.self, forKey: .defaultModelId)
        defaultThinking = try c.decodeIfPresent(ThinkingLevel.self, forKey: .defaultThinking) ?? .off
        allowsSelfEdit = try c.decodeIfPresent(Bool.self, forKey: .allowsSelfEdit) ?? true
        accentHue = try c.decodeIfPresent(Double.self, forKey: .accentHue) ?? Double.random(in: 0.05...0.12)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        awaitingFirstMessage = try c.decodeIfPresent(Bool.self, forKey: .awaitingFirstMessage) ?? false
    }

    static func makeDefaultPi(projectID: UUID? = nil) -> Bean {
        Bean(
            name: "Pi",
            instructions: "You are Pi inside Coffee & Pi. Be direct and ship working changes.",
            projectID: projectID,
            allowsSelfEdit: true,
            accentHue: 0.08
        )
    }

    /// Grokbot-style create: the name *is* the job. No instructions form required.
    static func make(name: String, projectID: UUID?, selfEdit: Bool, accentHue: Double? = nil) -> Bean {
        Bean(
            name: name,
            instructions: Self.nameAsIdentityPrompt(name: name),
            projectID: projectID,
            allowsSelfEdit: selfEdit,
            accentHue: accentHue ?? Double.random(in: 0.05...0.12),
            awaitingFirstMessage: true
        )
    }

    static func nameAsIdentityPrompt(name: String) -> String {
        """
        You are \(name). Your name is your job description — infer what you do from it and act accordingly. \
        Don't wait for a long brief. Stay in character, be direct, and start helping.
        """
    }

    var subtitle: String {
        if allowsSelfEdit { return "Self-edit · agent" }
        return "Agent"
    }

    /// Short provider badge for shop / table chrome.
    var providerChip: String {
        let p = (defaultProvider ?? "").lowercased()
        let n = name.lowercased()
        if n == "cursor" || p.contains("cursor") { return "cursor" }
        if p.contains("codex") || p == "openai" || p.contains("openai") { return "codex" }
        if p.contains("anthropic") || p.contains("claude") { return "claude" }
        if p.contains("grok") || p.contains("xai") { return "grok" }
        if p.contains("llama") || p.isEmpty { return "local" }
        return defaultProvider ?? "local"
    }
}

struct Project: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var path: String
    /// `owner/repo` or HTTPS git URL. Empty = disconnected.
    var githubRemote: String

    var hasGitHub: Bool { !githubRemote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

}

struct ChatThread: Identifiable, Codable {
    let id: UUID
    /// `nil` = outside any project.
    var projectID: UUID?
    /// Primary / host bean for solo chats; for tables, first seat (also listed in participantBeanIDs).
    var beanID: UUID?
    var kind: ChatKind
    /// Ordered seats at a table. Solo chats use 0…1 entries matching `beanID`.
    var participantBeanIDs: [UUID]
    /// Handoff sources this chat can see.
    var linkedThreadIDs: [UUID]
    var title: String
    var messages: [ChatMessage]
    var selectedModel: PiModel?
    var thinkingLevel: ThinkingLevel
    var isBusy: Bool
    var lastError: String?
    var updatedAt: Date
    var piSessionID: String
    var archivedAt: Date?

    var preview: String {
        messages.last(where: { !$0.text.isEmpty })?.text ?? "New chat"
    }

    var isTable: Bool { kind == .table }
    var isArchived: Bool { archivedAt != nil }

    var seatedBeanIDs: [UUID] {
        if kind == .table {
            return participantBeanIDs
        }
        if let beanID { return [beanID] }
        return []
    }

    enum CodingKeys: String, CodingKey {
        case id, projectID, beanID, botID, kind, participantBeanIDs, linkedThreadIDs
        case title, messages, selectedModel
        case thinkingLevel, isBusy, lastError, updatedAt, piSessionID, archivedAt
    }

    init(
        id: UUID = UUID(),
        projectID: UUID? = nil,
        beanID: UUID? = nil,
        kind: ChatKind = .solo,
        participantBeanIDs: [UUID] = [],
        linkedThreadIDs: [UUID] = [],
        title: String = "New chat",
        messages: [ChatMessage] = [],
        selectedModel: PiModel? = nil,
        thinkingLevel: ThinkingLevel = .off,
        isBusy: Bool = false,
        lastError: String? = nil,
        updatedAt: Date = Date(),
        piSessionID: String? = nil,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.beanID = beanID
        self.kind = kind
        if kind == .table {
            self.participantBeanIDs = participantBeanIDs
        } else if let beanID {
            self.participantBeanIDs = participantBeanIDs.isEmpty ? [beanID] : participantBeanIDs
        } else {
            self.participantBeanIDs = participantBeanIDs
        }
        self.linkedThreadIDs = linkedThreadIDs
        self.title = title
        self.messages = messages
        self.selectedModel = selectedModel
        self.thinkingLevel = thinkingLevel
        self.isBusy = isBusy
        self.lastError = lastError
        self.updatedAt = updatedAt
        self.piSessionID = piSessionID ?? id.uuidString
        self.archivedAt = archivedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        // Prefer beanID; fall back to legacy botID.
        if let bean = try c.decodeIfPresent(UUID.self, forKey: .beanID) {
            beanID = bean
        } else {
            beanID = try c.decodeIfPresent(UUID.self, forKey: .botID)
        }
        kind = try c.decodeIfPresent(ChatKind.self, forKey: .kind) ?? .solo
        if let seats = try c.decodeIfPresent([UUID].self, forKey: .participantBeanIDs) {
            participantBeanIDs = seats
        } else if let beanID {
            participantBeanIDs = [beanID]
        } else {
            participantBeanIDs = []
        }
        linkedThreadIDs = try c.decodeIfPresent([UUID].self, forKey: .linkedThreadIDs) ?? []
        title = try c.decode(String.self, forKey: .title)
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        selectedModel = try c.decodeIfPresent(PiModel.self, forKey: .selectedModel)
        thinkingLevel = try c.decodeIfPresent(ThinkingLevel.self, forKey: .thinkingLevel) ?? .off
        isBusy = false
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        piSessionID = try c.decodeIfPresent(String.self, forKey: .piSessionID) ?? id.uuidString
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(projectID, forKey: .projectID)
        try c.encodeIfPresent(beanID, forKey: .beanID)
        try c.encode(kind, forKey: .kind)
        try c.encode(participantBeanIDs, forKey: .participantBeanIDs)
        try c.encode(linkedThreadIDs, forKey: .linkedThreadIDs)
        try c.encode(title, forKey: .title)
        try c.encode(messages, forKey: .messages)
        try c.encodeIfPresent(selectedModel, forKey: .selectedModel)
        try c.encode(thinkingLevel, forKey: .thinkingLevel)
        try c.encode(false, forKey: .isBusy)
        try c.encodeIfPresent(lastError, forKey: .lastError)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(piSessionID, forKey: .piSessionID)
        try c.encodeIfPresent(archivedAt, forKey: .archivedAt)
    }

    static func blank(
        projectID: UUID?,
        beanID: UUID?,
        model: PiModel?,
        thinking: ThinkingLevel = .off
    ) -> ChatThread {
        ChatThread(
            projectID: projectID,
            beanID: beanID,
            kind: .solo,
            participantBeanIDs: beanID.map { [$0] } ?? [],
            selectedModel: model,
            thinkingLevel: thinking
        )
    }

    static func table(
        projectID: UUID?,
        beanIDs: [UUID],
        model: PiModel?,
        thinking: ThinkingLevel = .off
    ) -> ChatThread {
        ChatThread(
            projectID: projectID,
            beanID: beanIDs.first,
            kind: .table,
            participantBeanIDs: beanIDs,
            title: "Table",
            selectedModel: model,
            thinkingLevel: thinking
        )
    }
}

/// Key for one Pi RPC process: a Bean seated in a thread (`beanID` nil = host/anonymous).
struct BeanClientKey: Hashable {
    let threadID: UUID
    let beanID: UUID?

    static func solo(threadID: UUID, beanID: UUID?) -> BeanClientKey {
        BeanClientKey(threadID: threadID, beanID: beanID)
    }

    static func seat(threadID: UUID, beanID: UUID) -> BeanClientKey {
        BeanClientKey(threadID: threadID, beanID: beanID)
    }

    var sessionSuffix: String {
        beanID?.uuidString ?? "host"
    }
}

enum RouterStatus: Equatable {
    case stopped
    case starting
    case running(models: [String])
    case error(String)
}

enum DetailPane: Hashable {
    case chat
    case shop
    case settings
}

/// Legacy nested bot shape for migrating old projects.json.
struct LegacyBot: Codable {
    let id: UUID
    var name: String
    var instructions: String
    var defaultProvider: String?
    var defaultModelId: String?
    var defaultThinking: ThinkingLevel?
    var allowsSelfEdit: Bool?
    var accentHue: Double?
}

struct LegacyProject: Codable {
    let id: UUID
    var name: String
    var path: String
    var githubRemote: String?
    var bots: [LegacyBot]?
}

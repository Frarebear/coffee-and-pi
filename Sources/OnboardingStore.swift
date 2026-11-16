import Foundation

/// First-launch wizard state. Never deletes projects / chats / auth — only tracks whether
/// the new-user walkthrough has been finished or skipped.
@MainActor
final class OnboardingStore: ObservableObject {
    static let completedKey = "hasCompletedOnboarding"

    enum Step: Int, CaseIterable, Identifiable {
        case welcome
        case chooseEngines
        case connect
        case tourBean
        case tourProject
        case tourShop
        case done

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .chooseEngines: return "Engines"
            case .connect: return "Connect"
            case .tourBean: return "Beans"
            case .tourProject: return "Projects"
            case .tourShop: return "Coffee Shop"
            case .done: return "Ready"
            }
        }
    }

    /// Engines the user can wire during onboarding.
    enum Engine: String, CaseIterable, Identifiable, Hashable {
        case local
        case mlx
        case openai
        case anthropic
        case openrouter
        case grok
        case cursor

        var id: String { rawValue }

        var title: String {
            switch self {
            case .local: return "Local (llama.cpp)"
            case .mlx: return "MLX (Apple Silicon)"
            case .openai: return "OpenAI / ChatGPT"
            case .anthropic: return "Claude"
            case .openrouter: return "OpenRouter"
            case .grok: return "Grok"
            case .cursor: return "Cursor"
            }
        }

        var subtitle: String {
            switch self {
            case .local: return "Pi + model router on this Mac. Private, offline-capable."
            case .mlx: return "Native MLX models via mlx-lm server (Mac only)."
            case .openai: return "ChatGPT subscription (OAuth) or an OpenAI API key."
            case .anthropic: return "Claude via API key or Anthropic account."
            case .openrouter: return "One key → many cloud models + live credits."
            case .grok: return "xAI Grok via API key."
            case .cursor: return "Cursor-style Bean + transcript handoff from Cursor chats."
            }
        }

        var systemImage: String {
            switch self {
            case .local: return "internaldrive"
            case .mlx: return "cpu"
            case .openai: return "sparkles"
            case .anthropic: return "brain.head.profile"
            case .openrouter: return "globe"
            case .grok: return "bolt.fill"
            case .cursor: return "hammer"
            }
        }

        /// Pi auth provider id when this engine uses credentials.
        var piProviderID: String? {
            switch self {
            case .local: return "llama.cpp"
            case .mlx: return "mlx"
            // Pi stores ChatGPT subscription OAuth under `openai` (not `openai-codex`).
            case .openai: return "openai"
            case .anthropic: return "anthropic"
            case .openrouter: return "openrouter"
            case .grok: return "xai"
            case .cursor: return nil
            }
        }

        /// Alternate Pi provider ids that also count as “connected” for this engine.
        var alternatePiProviderIDs: [String] {
            switch self {
            // Legacy / Codex-protocol login still counts if present.
            case .openai: return ["openai-codex"]
            default: return []
            }
        }

        var prefersOAuth: Bool {
            switch self {
            case .openai, .anthropic: return true
            default: return false
            }
        }

        var acceptsAPIKey: Bool {
            switch self {
            case .openai, .anthropic, .openrouter, .grok: return true
            case .local, .mlx, .cursor: return false
            }
        }

        var isLocalInstall: Bool {
            self == .local || self == .mlx
        }
    }

    @Published var step: Step = .welcome
    @Published var selectedEngines: Set<Engine> = [.local]
    @Published var connectQueue: [Engine] = []
    @Published var connectIndex: Int = 0
    @Published var statusMessage: String?
    @Published var isBusy = false
    @Published var beanNameDraft = "Pi"
    @Published var beanHue = 0.08
    @Published private(set) var isPresented = false

    var currentConnectEngine: Engine? {
        guard connectIndex < connectQueue.count else { return nil }
        return connectQueue[connectIndex]
    }

    var progressLabel: String {
        "\(step.rawValue + 1) / \(Step.allCases.count)"
    }

    /// Show wizard only for true first-run (or when Settings asks to replay).
    func evaluateShouldPresent(hasWorkspaceContent: Bool) {
        if UserDefaults.standard.bool(forKey: Self.completedKey) {
            isPresented = false
            return
        }
        // Existing installs: don't force the wizard; mark complete so relaunch stays quiet.
        if hasWorkspaceContent {
            markCompleted(skipped: true)
            isPresented = false
            return
        }
        isPresented = true
        step = .welcome
    }

    func replay() {
        step = .welcome
        selectedEngines = [.local]
        connectQueue = []
        connectIndex = 0
        statusMessage = nil
        isBusy = false
        beanNameDraft = "Pi"
        beanHue = 0.08
        isPresented = true
    }

    /// Called when the overlay closes so the app can finish deferred boot (router, etc.).
    var onDismiss: (() -> Void)?

    func skipAll() {
        markCompleted(skipped: true)
    }

    func markCompleted(skipped: Bool) {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        if skipped {
            UserDefaults.standard.set(true, forKey: "onboardingWasSkipped")
        }
        let wasPresented = isPresented
        isPresented = false
        if wasPresented {
            onDismiss?()
        }
    }

    func beginConnectQueue() {
        let order = Engine.allCases.filter { selectedEngines.contains($0) }
        connectQueue = order
        connectIndex = 0
        statusMessage = nil
        if connectQueue.isEmpty {
            step = .tourBean
        } else {
            step = .connect
        }
    }

    func advanceAfterConnect() {
        statusMessage = nil
        connectIndex += 1
        if connectIndex >= connectQueue.count {
            step = .tourBean
        }
    }

    func goNextFromWelcome() {
        step = .chooseEngines
    }

    func goNextFromEngines() {
        beginConnectQueue()
    }

    func goNextTour() {
        switch step {
        case .tourBean: step = .tourProject
        case .tourProject: step = .tourShop
        case .tourShop: step = .done
        default: break
        }
    }

    func finish() {
        markCompleted(skipped: false)
    }
}

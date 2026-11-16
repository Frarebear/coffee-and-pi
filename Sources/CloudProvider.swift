import Foundation

/// Cloud providers we surface in Settings → Cloud (maps to Pi `auth login` ids).
enum CloudProviderOption: String, CaseIterable, Identifiable, Hashable {
    case openrouter
    case openai
    case anthropic
    case google
    case xai
    case groq
    case mistral
    case deepseek
    case githubCopilot

    var id: String { rawValue }

    /// Pi / auth.json provider id.
    var piID: String {
        switch self {
        case .openrouter: return "openrouter"
        case .openai: return "openai"
        case .anthropic: return "anthropic"
        case .google: return "google"
        case .xai: return "xai"
        case .groq: return "groq"
        case .mistral: return "mistral"
        case .deepseek: return "deepseek"
        case .githubCopilot: return "github-copilot"
        }
    }

    var displayName: String {
        switch self {
        case .openrouter: return "OpenRouter"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .google: return "Google"
        case .xai: return "xAI"
        case .groq: return "Groq"
        case .mistral: return "Mistral"
        case .deepseek: return "DeepSeek"
        case .githubCopilot: return "GitHub Copilot"
        }
    }

    enum AuthCapability {
        /// Only an API key (e.g. OpenRouter).
        case apiKeyOnly
        /// Browser/account sign-in or API key (e.g. OpenAI).
        case oauthOrApiKey
        /// Account sign-in only.
        case oauthOnly
    }

    var auth: AuthCapability {
        switch self {
        case .openrouter, .groq, .mistral, .deepseek, .xai:
            return .apiKeyOnly
        case .openai, .anthropic, .google:
            return .oauthOrApiKey
        case .githubCopilot:
            return .oauthOnly
        }
    }

    var supportsAPIKey: Bool {
        switch auth {
        case .apiKeyOnly, .oauthOrApiKey: return true
        case .oauthOnly: return false
        }
    }

    var supportsOAuth: Bool {
        switch auth {
        case .oauthOrApiKey, .oauthOnly: return true
        case .apiKeyOnly: return false
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .openrouter: return "sk-or-…"
        case .openai: return "sk-…"
        case .anthropic: return "sk-ant-…"
        case .google: return "AIza…"
        case .xai: return "xai-…"
        default: return "API key"
        }
    }
}

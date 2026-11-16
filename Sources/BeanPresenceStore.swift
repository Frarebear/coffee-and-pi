import Foundation

/// Presence states for the coffee-shop UI (and table orchestration).
enum BeanPresenceState: Equatable, Hashable {
    case idle
    case walking
    case seated(tableID: UUID)
    case speaking(tableID: UUID)
    case handoff(fromThreadID: UUID)

    var label: String {
        switch self {
        case .idle: return "idle"
        case .walking: return "walking"
        case .seated: return "seated"
        case .speaking: return "speaking"
        case .handoff: return "handoff"
        }
    }
}

/// Observable bus the coffee-shop floor reads for Bean movement / chat bubbles.
@MainActor
final class BeanPresenceStore: ObservableObject {
    @Published private(set) var states: [UUID: BeanPresenceState] = [:]

    func state(for beanID: UUID) -> BeanPresenceState {
        states[beanID] ?? .idle
    }

    func set(_ beanID: UUID, _ state: BeanPresenceState) {
        states[beanID] = state
        objectWillChange.send()
    }

    func setMany(_ beanIDs: [UUID], _ state: BeanPresenceState) {
        for id in beanIDs {
            states[id] = state
        }
        objectWillChange.send()
    }

    func clearTable(_ tableID: UUID) {
        for (id, state) in states {
            switch state {
            case .seated(let t) where t == tableID:
                states[id] = .idle
            case .speaking(let t) where t == tableID:
                states[id] = .idle
            default:
                break
            }
        }
        objectWillChange.send()
    }

    func resetAllIdle(except keep: Set<UUID> = []) {
        for id in states.keys where !keep.contains(id) {
            states[id] = .idle
        }
        objectWillChange.send()
    }
}

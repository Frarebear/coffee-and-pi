import Foundation

/// Tracks authenticated WebSocket clients and which chats they subscribed to.
/// Phone stays a thin client — Mac pushes chat state over the node API.
@MainActor
final class NodeWSHub {
    struct Client {
        let id: UUID
        var chatIDs: Set<UUID>
        let send: @MainActor (String) -> Void
    }

    private var clients: [UUID: Client] = [:]

    @discardableResult
    func add(id: UUID = UUID(), send: @escaping @MainActor (String) -> Void) -> UUID {
        clients[id] = Client(id: id, chatIDs: [], send: send)
        return id
    }

    func remove(_ id: UUID) {
        clients.removeValue(forKey: id)
    }

    func subscribe(_ id: UUID, chatID: UUID) {
        clients[id]?.chatIDs.insert(chatID)
    }

    func unsubscribe(_ id: UUID, chatID: UUID) {
        clients[id]?.chatIDs.remove(chatID)
    }

    func publish(chatID: UUID, json: String) {
        for client in clients.values where client.chatIDs.contains(chatID) {
            client.send(json)
        }
    }

    var clientCount: Int { clients.count }
}

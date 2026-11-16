import Foundation

/// Advertises this Coffee & Pi node on the LAN via Bonjour (`_coffeeandpi._tcp`).
final class NodeBonjour: NSObject, NetServiceDelegate {
    private var service: NetService?
    private let type = "_coffeeandpi._tcp."

    func start(name: String, port: Int, nodeID: String) {
        stop()
        let svc = NetService(domain: "local.", type: type, name: name, port: Int32(port))
        svc.includesPeerToPeer = true
        svc.delegate = self
        let txt: [String: Data] = [
            "id": Data(nodeID.utf8),
            "name": Data(name.utf8),
            "v": Data("1".utf8),
        ]
        svc.setTXTRecord(NetService.data(fromTXTRecord: txt))
        svc.publish()
        service = svc
    }

    func stop() {
        service?.stop()
        service = nil
    }

    func netServiceDidPublish(_ sender: NetService) {
        NSLog("NodeBonjour published \(sender.name) on port \(sender.port)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        NSLog("NodeBonjour publish failed: \(errorDict)")
    }
}

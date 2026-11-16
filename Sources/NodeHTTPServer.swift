import CryptoKit
import Foundation
import Network

/// Minimal HTTP/1.1 + WebSocket upgrade server (Network.framework).
final class NodeHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data

        static func json(_ status: Int, _ object: Any) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
            return Response(
                status: status,
                headers: [
                    "Content-Type": "application/json; charset=utf-8",
                    "Content-Length": "\(data.count)",
                    "Connection": "close",
                    "Access-Control-Allow-Origin": "*",
                ],
                body: data
            )
        }

        static func text(_ status: Int, _ text: String, contentType: String = "text/plain; charset=utf-8") -> Response {
            let data = Data(text.utf8)
            return Response(
                status: status,
                headers: [
                    "Content-Type": contentType,
                    "Content-Length": "\(data.count)",
                    "Connection": "close",
                    "Access-Control-Allow-Origin": "*",
                ],
                body: data
            )
        }

        static var noContent: Response {
            Response(status: 204, headers: ["Connection": "close", "Access-Control-Allow-Origin": "*"], body: Data())
        }
    }

    typealias Handler = @Sendable (Request) async -> Response
    /// WebSocket text frames; `sessionID` identifies the connection for subscribe/push.
    typealias WSHandler = @Sendable (_ sessionID: UUID, _ message: String) async -> String?
    typealias WSAuth = @Sendable (Request) async -> Bool
    typealias WSOpen = @Sendable (_ sessionID: UUID, _ send: @escaping @Sendable (String) -> Void) -> Void
    typealias WSClose = @Sendable (_ sessionID: UUID) -> Void

    private let port: UInt16
    private let handler: Handler
    private let wsPath: String
    private let wsHandler: WSHandler?
    private let wsAuth: WSAuth?
    private let wsOpen: WSOpen?
    private let wsClose: WSClose?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.caleb.CoffeeAndPi.NodeHTTP")

    init(
        port: UInt16,
        wsPath: String = "/v1/ws",
        wsHandler: WSHandler? = nil,
        wsAuth: WSAuth? = nil,
        wsOpen: WSOpen? = nil,
        wsClose: WSClose? = nil,
        handler: @escaping Handler
    ) {
        self.port = port
        self.wsPath = wsPath
        self.wsHandler = wsHandler
        self.wsAuth = wsAuth
        self.wsOpen = wsOpen
        self.wsClose = wsClose
        self.handler = handler
    }

    var isRunning: Bool { listener != nil }

    func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("NodeHTTPServer listener failed: \(error)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeader(connection: connection, buffer: Data())
    }

    private func receiveHeader(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || (isComplete && (data == nil || data!.isEmpty) && buffer.isEmpty) {
                connection.cancel()
                return
            }
            var buf = buffer
            if let data { buf.append(data) }
            guard let range = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if buf.count > 1024 * 1024 {
                    connection.cancel()
                    return
                }
                self.receiveHeader(connection: connection, buffer: buf)
                return
            }
            let headerData = buf.subdata(in: buf.startIndex..<range.lowerBound)
            let rest = buf.subdata(in: range.upperBound..<buf.endIndex)
            guard let headerText = String(data: headerData, encoding: .utf8),
                  let requestLine = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).first
            else {
                connection.cancel()
                return
            }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else {
                connection.cancel()
                return
            }
            let method = String(parts[0]).uppercased()
            let rawPath = String(parts[1])
            var headers: [String: String] = [:]
            for line in headerText.split(separator: "\r\n").dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
            let (path, query) = Self.splitPath(rawPath)
            let contentLength = Int(headers["content-length"] ?? "0") ?? 0

            let finish: (Data) -> Void = { body in
                if method == "OPTIONS" {
                    self.send(
                        Response(
                            status: 204,
                            headers: [
                                "Access-Control-Allow-Origin": "*",
                                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                                "Access-Control-Allow-Headers": "Authorization, Content-Type",
                                "Connection": "close",
                            ],
                            body: Data()
                        ),
                        on: connection
                    )
                    return
                }
                let req = Request(method: method, path: path, query: query, headers: headers, body: body)
                let upgrade = (headers["upgrade"] ?? "").lowercased() == "websocket"
                if upgrade, path == self.wsPath, let wsHandler = self.wsHandler {
                    Task {
                        if let auth = self.wsAuth, await !auth(req) {
                            self.send(.json(401, ["error": "unauthorized"]), on: connection)
                            return
                        }
                        self.upgradeWebSocket(connection: connection, headers: headers, handler: wsHandler)
                    }
                    return
                }
                Task {
                    let response = await self.handler(req)
                    self.send(response, on: connection)
                }
            }

            if contentLength <= rest.count {
                finish(Data(rest.prefix(contentLength)))
            } else {
                self.receiveBody(connection: connection, needed: contentLength, buffer: rest, done: finish)
            }
        }
    }

    private func receiveBody(connection: NWConnection, needed: Int, buffer: Data, done: @escaping (Data) -> Void) {
        if buffer.count >= needed {
            done(Data(buffer.prefix(needed)))
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: max(needed - buffer.count, 1)) { [weak self] data, _, _, error in
            guard let self, error == nil, let data else {
                connection.cancel()
                return
            }
            var buf = buffer
            buf.append(data)
            self.receiveBody(connection: connection, needed: needed, buffer: buf, done: done)
        }
    }

    private func send(_ response: Response, on connection: NWConnection) {
        let reason: [Int: String] = [
            200: "OK", 201: "Created", 202: "Accepted", 204: "No Content",
            400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
            404: "Not Found", 409: "Conflict", 429: "Too Many Requests",
            500: "Internal Server Error",
        ]
        var header = "HTTP/1.1 \(response.status) \(reason[response.status] ?? "OK")\r\n"
        for (k, v) in response.headers {
            header += "\(k): \(v)\r\n"
        }
        header += "\r\n"
        var data = Data(header.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - WebSocket (text frames)

    private func upgradeWebSocket(connection: NWConnection, headers: [String: String], handler: @escaping WSHandler) {
        guard let key = headers["sec-websocket-key"] else {
            send(.text(400, "Missing Sec-WebSocket-Key"), on: connection)
            return
        }
        let accept = Self.websocketAccept(key)
        let handshake = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(accept)\r
        \r

        """
        let sessionID = UUID()
        let sendText: @Sendable (String) -> Void = { [weak connection] text in
            guard let connection else { return }
            let frame = Self.encodeWSFrame(opcode: 0x1, payload: Array(text.utf8))
            connection.send(content: frame, completion: .contentProcessed { _ in })
        }
        connection.send(content: Data(handshake.utf8), completion: .contentProcessed { [weak self] _ in
            self?.wsOpen?(sessionID, sendText)
            self?.wsReadLoop(connection: connection, sessionID: sessionID, buffer: Data(), handler: handler)
        })
    }

    private func wsReadLoop(connection: NWConnection, sessionID: UUID, buffer: Data, handler: @escaping WSHandler) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete {
                self.wsClose?(sessionID)
                connection.cancel()
                return
            }
            var buf = buffer
            if let data { buf.append(data) }
            while let decoded = Self.decodeWSFrame(buf) {
                buf = decoded.rest
                if decoded.opcode == 0x8 {
                    self.wsClose?(sessionID)
                    connection.cancel()
                    return
                }
                if decoded.opcode == 0x9 {
                    // ping → pong
                    connection.send(content: Self.encodeWSFrame(opcode: 0xA, payload: decoded.payload), completion: .contentProcessed { _ in })
                    continue
                }
                guard decoded.opcode == 0x1,
                      let text = String(bytes: decoded.payload, encoding: .utf8)
                else { continue }
                Task {
                    if let reply = await handler(sessionID, text), !reply.isEmpty {
                        connection.send(content: Self.encodeWSFrame(opcode: 0x1, payload: Array(reply.utf8)), completion: .contentProcessed { _ in })
                    }
                }
            }
            self.wsReadLoop(connection: connection, sessionID: sessionID, buffer: buf, handler: handler)
        }
    }

    private static func splitPath(_ raw: String) -> (String, [String: String]) {
        guard let q = raw.firstIndex(of: "?") else { return (raw, [:]) }
        let path = String(raw[..<q])
        let queryString = String(raw[raw.index(after: q)...])
        var query: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let k = kv.first.map(String.init) else { continue }
            let v = kv.count > 1 ? String(kv[1]).removingPercentEncoding ?? String(kv[1]) : ""
            query[k.removingPercentEncoding ?? k] = v
        }
        return (path, query)
    }

    private static func websocketAccept(_ key: String) -> String {
        let combined = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        let digest = Insecure.SHA1.hash(data: combined)
        return Data(digest).base64EncodedString()
    }

    private static func encodeWSFrame(opcode: UInt8, payload: [UInt8]) -> Data {
        var out: [UInt8] = [0x80 | opcode]
        if payload.count < 126 {
            out.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            out.append(126)
            out.append(UInt8((payload.count >> 8) & 0xFF))
            out.append(UInt8(payload.count & 0xFF))
        } else {
            out.append(127)
            for i in (0..<8).reversed() {
                out.append(UInt8((payload.count >> (i * 8)) & 0xFF))
            }
        }
        out.append(contentsOf: payload)
        return Data(out)
    }

    private static func decodeWSFrame(_ data: Data) -> (opcode: UInt8, payload: [UInt8], rest: Data)? {
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data)
        let opcode = bytes[0] & 0x0F
        let masked = (bytes[1] & 0x80) != 0
        var len = Int(bytes[1] & 0x7F)
        var offset = 2
        if len == 126 {
            guard bytes.count >= 4 else { return nil }
            len = (Int(bytes[2]) << 8) | Int(bytes[3])
            offset = 4
        } else if len == 127 {
            guard bytes.count >= 10 else { return nil }
            len = 0
            for i in 0..<8 { len = (len << 8) | Int(bytes[2 + i]) }
            offset = 10
        }
        let maskLen = masked ? 4 : 0
        guard bytes.count >= offset + maskLen + len else { return nil }
        var payload = Array(bytes[(offset + maskLen)..<(offset + maskLen + len)])
        if masked {
            let mask = Array(bytes[offset..<(offset + 4)])
            for i in 0..<payload.count {
                payload[i] ^= mask[i % 4]
            }
        }
        let rest = Data(bytes[(offset + maskLen + len)...])
        return (opcode, payload, rest)
    }
}

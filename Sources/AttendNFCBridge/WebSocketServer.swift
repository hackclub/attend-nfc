import Foundation
import Network

class WebSocketServer {
    let port: UInt16
    var nfcReader: NFCReader?
    var onConnectionCountChanged: ((Int) -> Void)?
    
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var webSockets: [ObjectIdentifier: WebSocketConnection] = [:]
    private let queue = DispatchQueue(label: "nfc-bridge-server")
    private let connectionsLock = NSLock()
    
    init(port: Int) {
        self.port = UInt16(port)
    }
    
    func start(completion: @escaping (Error?) -> Void) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            completion(error)
            return
        }
        
        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("WebSocket server listening on ws://127.0.0.1:\(self.port)")
                completion(nil)
            case .failed(let error):
                completion(error)
            default:
                break
            }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
        
        listener?.start(queue: queue)
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            
            switch state {
            case .ready:
                self.readHTTPRequest(connection)
            case .failed, .cancelled:
                self.removeConnection(id)
            default:
                break
            }
        }
        
        connection.start(queue: queue)
    }
    
    private func readHTTPRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else { return }
            
            guard let request = String(data: data, encoding: .utf8) else { return }
            
            if request.contains("Upgrade: websocket") {
                self.upgradeToWebSocket(connection, request: request)
            } else {
                self.sendHTTPResponse(connection, status: "400 Bad Request", body: "WebSocket upgrade required")
            }
        }
    }
    
    private func upgradeToWebSocket(_ connection: NWConnection, request: String) {
        guard let keyLine = request.split(separator: "\r\n").first(where: { $0.hasPrefix("Sec-WebSocket-Key:") }),
              let key = keyLine.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) else {
            sendHTTPResponse(connection, status: "400 Bad Request", body: "Missing WebSocket key")
            return
        }
        
        let acceptKey = computeWebSocketAcceptKey(key)
        
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(acceptKey)\r
        \r
        
        """
        
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            guard let self = self, error == nil else { return }
            
            let id = ObjectIdentifier(connection)
            let wsConnection = WebSocketConnection(connection: connection)
            
            self.connectionsLock.lock()
            self.connections[id] = connection
            self.webSockets[id] = wsConnection
            let count = self.connections.count
            self.connectionsLock.unlock()
            
            DispatchQueue.main.async {
                self.onConnectionCountChanged?(count)
            }
            
            self.sendWebSocketMessage(wsConnection, message: "{\"type\":\"connected\",\"message\":\"Attend NFC Bridge connected\",\"version\":\"1.0.0\"}")
            self.readWebSocketFrame(wsConnection)
        })
    }
    
    private func computeWebSocketAcceptKey(_ key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = key + magic
        let hash = sha1(combined)
        return Data(hash).base64EncodedString()
    }
    
    private func sha1(_ string: String) -> [UInt8] {
        let data = Array(string.utf8)
        
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0
        
        var message = data
        let ml = UInt64(data.count * 8)
        
        message.append(0x80)
        while (message.count % 64) != 56 {
            message.append(0x00)
        }
        
        for i in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((ml >> i) & 0xFF))
        }
        
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            
            for i in 0..<16 {
                let j = chunkStart + i * 4
                w[i] = UInt32(message[j]) << 24 | UInt32(message[j+1]) << 16 | UInt32(message[j+2]) << 8 | UInt32(message[j+3])
            }
            
            for i in 16..<80 {
                w[i] = (w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16]).rotateLeft(1)
            }
            
            var a = h0, b = h1, c = h2, d = h3, e = h4
            
            for i in 0..<80 {
                var f: UInt32
                var k: UInt32
                
                if i < 20 {
                    f = (b & c) | ((~b) & d)
                    k = 0x5A827999
                } else if i < 40 {
                    f = b ^ c ^ d
                    k = 0x6ED9EBA1
                } else if i < 60 {
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1BBCDC
                } else {
                    f = b ^ c ^ d
                    k = 0xCA62C1D6
                }
                
                let temp = a.rotateLeft(5) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = b.rotateLeft(30)
                b = a
                a = temp
            }
            
            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
        }
        
        var result = [UInt8]()
        for h in [h0, h1, h2, h3, h4] {
            result.append(UInt8((h >> 24) & 0xFF))
            result.append(UInt8((h >> 16) & 0xFF))
            result.append(UInt8((h >> 8) & 0xFF))
            result.append(UInt8(h & 0xFF))
        }
        
        return result
    }
    
    private func readWebSocketFrame(_ ws: WebSocketConnection) {
        ws.connection.receive(minimumIncompleteLength: 2, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, data.count >= 2 else {
                if isComplete || error != nil {
                    self?.removeConnection(ObjectIdentifier(ws.connection))
                }
                return
            }
            
            let bytes = Array(data)
            let opcode = bytes[0] & 0x0F
            let masked = (bytes[1] & 0x80) != 0
            var payloadLength = Int(bytes[1] & 0x7F)
            var offset = 2
            
            if payloadLength == 126 && bytes.count >= 4 {
                payloadLength = Int(bytes[2]) << 8 | Int(bytes[3])
                offset = 4
            } else if payloadLength == 127 && bytes.count >= 10 {
                payloadLength = 0
                for i in 0..<8 {
                    payloadLength = (payloadLength << 8) | Int(bytes[2 + i])
                }
                offset = 10
            }
            
            var maskKey: [UInt8] = []
            if masked && bytes.count >= offset + 4 {
                maskKey = Array(bytes[offset..<(offset + 4)])
                offset += 4
            }
            
            guard bytes.count >= offset + payloadLength else {
                self.readWebSocketFrame(ws)
                return
            }
            
            var payload = Array(bytes[offset..<(offset + payloadLength)])
            
            if masked {
                for i in 0..<payload.count {
                    payload[i] ^= maskKey[i % 4]
                }
            }
            
            switch opcode {
            case 0x01: // Text
                if let text = String(bytes: payload, encoding: .utf8) {
                    self.handleMessage(ws: ws, text: text)
                }
            case 0x08: // Close
                self.removeConnection(ObjectIdentifier(ws.connection))
                return
            case 0x09: // Ping
                self.sendPong(ws, data: payload)
            default:
                break
            }
            
            self.readWebSocketFrame(ws)
        }
    }
    
    private func sendPong(_ ws: WebSocketConnection, data: [UInt8]) {
        var frame: [UInt8] = [0x8A]
        if data.count <= 125 {
            frame.append(UInt8(data.count))
        }
        frame.append(contentsOf: data)
        ws.connection.send(content: Data(frame), completion: .idempotent)
    }
    
    private func sendWebSocketMessage(_ ws: WebSocketConnection, message: String) {
        let payload = Array(message.utf8)
        var frame: [UInt8] = [0x81]
        
        if payload.count <= 125 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 65535 {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for i in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((payload.count >> i) & 0xFF))
            }
        }
        
        frame.append(contentsOf: payload)
        ws.connection.send(content: Data(frame), completion: .idempotent)
    }
    
    private func sendHTTPResponse(_ connection: NWConnection, status: String, body: String) {
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/plain\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func removeConnection(_ id: ObjectIdentifier) {
        connectionsLock.lock()
        connections[id]?.cancel()
        connections.removeValue(forKey: id)
        webSockets.removeValue(forKey: id)
        let count = connections.count
        connectionsLock.unlock()
        
        DispatchQueue.main.async {
            self.onConnectionCountChanged?(count)
        }
    }
    
    private func handleMessage(ws: WebSocketConnection, text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            sendWebSocketMessage(ws, message: "{\"type\":\"error\",\"message\":\"Invalid message format\"}")
            return
        }
        
        switch action {
        case "ping":
            let timestamp = ISO8601DateFormatter().string(from: Date())
            sendWebSocketMessage(ws, message: "{\"type\":\"pong\",\"timestamp\":\"\(timestamp)\"}")
            
        case "write":
            // Support both old format (url) and new format (badge_url + attend_token)
            let badgeUrl = json["badge_url"] as? String ?? json["url"] as? String
            let attendToken = json["attend_token"] as? String
            
            guard let url = badgeUrl else {
                sendWebSocketMessage(ws, message: "{\"type\":\"error\",\"message\":\"Missing 'badge_url' or 'url' parameter for write action\"}")
                return
            }
            handleWrite(ws: ws, badgeUrl: url, attendToken: attendToken)
            
        case "status":
            let connected = nfcReader?.readerName != nil
            let name = nfcReader?.readerName ?? ""
            sendWebSocketMessage(ws, message: "{\"type\":\"status\",\"readerConnected\":\(connected),\"readerName\":\"\(name)\"}")
            
        default:
            sendWebSocketMessage(ws, message: "{\"type\":\"error\",\"message\":\"Unknown action: \(action)\"}")
        }
    }
    
    private func handleWrite(ws: WebSocketConnection, badgeUrl: String, attendToken: String?) {
        guard let reader = nfcReader else {
            sendWebSocketMessage(ws, message: "{\"type\":\"write_result\",\"success\":false,\"error\":\"No NFC reader available\"}")
            return
        }
        
        sendWebSocketMessage(ws, message: "{\"type\":\"write_pending\",\"message\":\"Present NFC tag to write...\"}")
        
        DispatchQueue.global().async { [weak self] in
            var success = false
            var attempts = 0
            let maxAttempts = 30
            
            while attempts < maxAttempts && !success {
                success = reader.writeNDEFDual(badgeUrl: badgeUrl, attendToken: attendToken)
                if !success {
                    Thread.sleep(forTimeInterval: 0.5)
                }
                attempts += 1
            }
            
            if success {
                self?.sendWebSocketMessage(ws, message: "{\"type\":\"write_result\",\"success\":true,\"badge_url\":\"\(badgeUrl)\"}")
            } else {
                self?.sendWebSocketMessage(ws, message: "{\"type\":\"write_result\",\"success\":false,\"error\":\"Failed to write to NFC tag. Ensure tag is present and writable.\"}")
            }
        }
    }
    
    func broadcastTagRead(_ tagData: TagData) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        guard let jsonData = try? encoder.encode(tagData),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }
        
        let message = "{\"type\":\"tag_read\",\"tag\":\(jsonString)}"
        
        connectionsLock.lock()
        let currentSockets = Array(webSockets.values)
        connectionsLock.unlock()
        
        for ws in currentSockets {
            sendWebSocketMessage(ws, message: message)
        }
    }
    
    func shutdown() {
        listener?.cancel()
        connectionsLock.lock()
        for (_, connection) in connections {
            connection.cancel()
        }
        connections.removeAll()
        webSockets.removeAll()
        connectionsLock.unlock()
    }
}

class WebSocketConnection {
    let connection: NWConnection
    
    init(connection: NWConnection) {
        self.connection = connection
    }
}

extension UInt32 {
    func rotateLeft(_ n: Int) -> UInt32 {
        return (self << n) | (self >> (32 - n))
    }
}

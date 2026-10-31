import Foundation
import Network
import OSLog

/// Read-only bridge, bound to IPv4 loopback. Mutable state is queue-confined.
final class WidgetLocalServer {
    private let endpoint: WidgetLocalEndpoint
    private let queue = DispatchQueue(label: "dev.quotabar.widget-bridge")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var summary: Data?
    private var state = "正在启动本机统计连接…"
    private let logger = Logger(subsystem: "dev.quotabar", category: "WidgetBridge")

    init(endpoint: WidgetLocalEndpoint) { self.endpoint = endpoint }
    var status: String { queue.sync { state } }
    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: endpoint.port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] status in
            guard let self else { return }
            switch status {
            case .ready: self.state = "本机统计连接已就绪。小组件由 macOS 定时刷新。"
            case .failed: self.state = "本机统计连接启动失败，请退出后重新打开 QuotaBar。"
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }
    func update(_ data: Data) {
        guard data.count <= WidgetLocalClient.maximumBytes else { return }
        queue.async { self.summary = data }
    }
    func stop() {
        queue.sync {
            listener?.cancel(); listener = nil
            connections.values.forEach { $0.cancel() }; connections.removeAll()
        }
    }
    deinit { listener?.cancel(); connections.values.forEach { $0.cancel() } }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.close(id) }
        receive(connection, id: id, accumulated: Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8193) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            guard buffer.count <= 8192 else { self.send(431, connection: connection, id: id); return }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                let status = Self.authorize(buffer, token: self.endpoint.token, port: self.endpoint.port)
                self.send(status, connection: connection, id: id)
            } else if complete || error != nil { self.close(id) }
            else { self.receive(connection, id: id, accumulated: buffer) }
        }
    }
    static func authorize(_ data: Data, token: String, port: UInt16) -> Int {
        guard let request = String(data: data, encoding: .utf8),
              let headerEnd = request.range(of: "\r\n\r\n"), headerEnd.upperBound == request.endIndex else { return 400 }
        let lines = request[..<headerEnd.lowerBound].components(separatedBy: "\r\n")
        guard let first = lines.first else { return 400 }
        let parts = first.split(separator: " ")
        guard parts.count == 3, parts[2] == "HTTP/1.1" else { return 400 }
        guard parts[0] == "GET" else { return 405 }
        guard parts[1] == "/v1/summary" else { return 404 }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return 400 }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { return 400 }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] == "127.0.0.1:\(port)", headers["origin"] == nil,
              headers["transfer-encoding"] == nil, headers["content-length"].map({ $0 == "0" }) ?? true else { return 400 }
        return headers["authorization"] == "Bearer \(token)" ? 200 : 401
    }
    private func send(_ status: Int, connection: NWConnection, id: UUID) {
        let status = status == 200 && summary == nil ? 503 : status
        let body = status == 200 ? summary! : Data()
        let header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Unavailable")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in self?.close(id) })
        if status == 200 { logger.info("Served aggregate snapshot, bytes=\(body.count)") }
    }
    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
}

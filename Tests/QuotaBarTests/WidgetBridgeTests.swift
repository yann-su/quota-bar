import XCTest
import Darwin
import QuotaCore
@testable import QuotaBar

final class WidgetBridgeTests: XCTestCase {
    private let token = String(repeating: "a", count: 64)
    private func request(_ first: String = "GET /v1/summary HTTP/1.1", token: String? = nil, extra: String = "") -> Data {
        Data("\(first)\r\nHost: 127.0.0.1:54321\r\nAuthorization: Bearer \(token ?? self.token)\r\n\(extra)\r\n".utf8)
    }
    private func status(_ data: Data) -> Int { WidgetLocalServer.authorize(data, token: token, port: 54321) }

    func testEndpointRejectsMalformedConfigurationAndUsesLiteralLoopback() throws {
        XCTAssertNil(WidgetLocalEndpoint(port: 80, token: token))
        XCTAssertNil(WidgetLocalEndpoint(port: 65536, token: token))
        XCTAssertNil(WidgetLocalEndpoint(port: 54321, token: "short"))
        XCTAssertNil(WidgetLocalEndpoint(port: 54321, token: String(repeating: "g", count: 64)))
        let endpoint = try XCTUnwrap(WidgetLocalEndpoint(port: 54321, token: token))
        XCTAssertEqual(endpoint.url.host, "127.0.0.1")
        XCTAssertEqual(endpoint.url.path, "/v1/summary")
        XCTAssertNil(endpoint.url.query)
    }
    func testOnlyAuthenticatedReadOnlyRequestsAreAccepted() {
        XCTAssertEqual(status(request()), 200)
        XCTAssertEqual(status(request(token: String(repeating: "b", count: 64))), 401)
        XCTAssertEqual(status(request("POST /v1/summary HTTP/1.1")), 405)
        XCTAssertEqual(status(request("GET /other HTTP/1.1")), 404)
        XCTAssertEqual(status(request(extra: "Origin: https://example.com\r\n")), 400)
        XCTAssertEqual(status(request(extra: "Transfer-Encoding: chunked\r\n")), 400)
        XCTAssertEqual(status(request(extra: "Content-Length: 20\r\n")), 400)
        XCTAssertEqual(status(request(extra: "Authorization: Bearer \(token)\r\n")), 400)
        XCTAssertEqual(status(request() + Data("body".utf8)), 400)
        let remoteHost = String(decoding: request(), as: UTF8.self).replacingOccurrences(of: "127.0.0.1:54321", with: "example.com")
        XCTAssertEqual(status(Data(remoteHost.utf8)), 400)
    }
    private func unusedPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                guard Darwin.bind(descriptor, pointer, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                guard getsockname(descriptor, pointer, &length) == 0 else { throw POSIXError(.EIO) }
            }
        }
        return Int(address.sin_port.bigEndian)
    }
    func testRealLoopbackFetchTracksUpdatesAndRejectsWrongCredential() async throws {
        let endpoint = try XCTUnwrap(WidgetLocalEndpoint(port: unusedPort(), token: token))
        let server = WidgetLocalServer(endpoint: endpoint)
        try server.start()
        defer { server.stop() }
        let report = TokenReport(records: [], coverage: [:], scannedAt: Date())
        let snapshot = WidgetSnapshot(report: report)
        server.update(try JSONEncoder().encode(snapshot))
        // Listener startup is asynchronous. Bound this wait to two seconds.
        var loaded: WidgetSnapshot?
        for _ in 0..<20 {
            if let value = try? await WidgetLocalClient.fetch(endpoint) { loaded = value; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(loaded, snapshot)
        let wrong = try XCTUnwrap(WidgetLocalEndpoint(port: Int(endpoint.port), token: String(repeating: "b", count: 64)))
        do { _ = try await WidgetLocalClient.fetch(wrong); XCTFail("Wrong credential was accepted") } catch {}
        var newer = snapshot
        newer.generatedAt = snapshot.generatedAt.addingTimeInterval(60)
        server.update(try JSONEncoder().encode(newer))
        let result = try await WidgetLocalClient.fetch(endpoint)
        XCTAssertEqual(result, newer)
        var future = newer; future.version += 1
        server.update(try JSONEncoder().encode(future))
        do { _ = try await WidgetLocalClient.fetch(endpoint); XCTFail("Unknown schema was accepted") } catch {}
    }
}

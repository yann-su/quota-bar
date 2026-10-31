import Foundation
import QuotaCore
import OSLog

enum WidgetKinds {
    static let sevenDays = "QuotaBarUsageWidget"
    static let today = "QuotaBarUsageToday"
    static let thirtyDays = "QuotaBarUsageThirtyDays"
    static let all = [sevenDays, today, thirtyDays]
}

/// The build inserts matching installation-specific values in both bundles.
struct WidgetLocalEndpoint {
    let port: UInt16
    let token: String
    init?(port: Int, token: String) {
        guard (1024...65535).contains(port), token.count == 64,
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.port = UInt16(port); self.token = token
    }
    static var configured: WidgetLocalEndpoint? {
        guard let port = Bundle.main.object(forInfoDictionaryKey: "QuotaBarLocalPort") as? Int,
              let token = Bundle.main.object(forInfoDictionaryKey: "QuotaBarLocalToken") as? String else { return nil }
        return WidgetLocalEndpoint(port: port, token: token)
    }
    var url: URL { URL(string: "http://127.0.0.1:\(port)/v1/summary")! }
}

private final class NoWidgetRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum WidgetLocalClient {
    static let maximumBytes = 64 * 1024
    static func fetch(_ endpoint: WidgetLocalEndpoint) async throws -> WidgetSnapshot {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration, delegate: NoWidgetRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint.url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= maximumBytes else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        guard snapshot.version == WidgetSnapshot.currentVersion else { throw URLError(.cannotParseResponse) }
        Logger(subsystem: "dev.quotabar", category: "WidgetBridge").info("Read aggregate snapshot, bytes=\(data.count), providers=\(snapshot.providers.count)")
        return snapshot
    }

    /// Cache in the extension's own container, never an App Group.
    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaBarWidgetCache", isDirectory: true)
    }
    static func load() async -> (snapshot: WidgetSnapshot?, issue: WidgetLoadIssue?) {
        guard let endpoint = WidgetLocalEndpoint.configured else { return (nil, .notConfigured) }
        do {
            let snapshot = try await fetch(endpoint)
            try? WidgetSnapshotFile.write(snapshot, directory: cacheDirectory)
            return (snapshot, nil)
        } catch {
            return (WidgetSnapshotFile.read(directory: cacheDirectory), .hostUnavailable)
        }
    }
}

enum WidgetLoadIssue {
    case notConfigured, hostUnavailable
    var title: String {
        switch self {
        case .notConfigured: return "请安装小组件版本"
        case .hostUnavailable: return "请打开 QuotaBar"
        }
    }
    var detail: String {
        switch self {
        case .notConfigured: return "使用包含原生扩展的 QuotaBar 安装包。"
        case .hostUnavailable: return "保持菜单栏应用运行，以同步本机 Token 统计。"
        }
    }
}

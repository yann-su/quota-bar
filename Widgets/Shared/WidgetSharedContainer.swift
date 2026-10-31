import Foundation
import QuotaCore

enum WidgetSharedContainer {
    static let kind = "QuotaBarUsageWidget"
    static var directory: URL? {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "QuotaBarAppGroup") as? String,
              !identifier.isEmpty, !identifier.contains("$(") else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)?
            .appendingPathComponent("Library/Application Support/QuotaBar", isDirectory: true)
    }
    static func read() -> WidgetSnapshot? {
        return directory.flatMap { WidgetSnapshotFile.read(directory: $0) }
    }
    static func load() -> (snapshot: WidgetSnapshot?, issue: WidgetLoadIssue?) {
        guard let directory else { return (nil, .notConfigured) }
        do { return (try WidgetSnapshotFile.load(directory: directory), nil) }
        catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) {
                return (nil, .accessDenied)
            }
            if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                return (nil, .noSummary)
            }
            return (nil, .unreadable)
        }
    }
}

enum WidgetLoadIssue {
    case notConfigured, noSummary, accessDenied, unreadable
    var title: String {
        switch self {
        case .notConfigured, .accessDenied: return "需要配置组件签名"
        case .noSummary: return "先打开 QuotaBar"
        case .unreadable: return "统计摘要待更新"
        }
    }
    var detail: String {
        switch self {
        case .notConfigured, .accessDenied: return "共享统计未获系统授权。完成应用签名后重新添加组件。"
        case .noSummary: return "读取本机 Token 用量后，小组件会显示统计。"
        case .unreadable: return "打开 QuotaBar，同步统计摘要后重试。"
        }
    }
}

#if canImport(UserNotifications)
import Foundation
import UserNotifications
#if canImport(OSLog)
import OSLog
#endif

/// Base class for an App Notification Service Extension that wants Engage rich-media support.
/// It only materializes the APNs `engage.image_url` attachment and never requests permission.
open class EngageNotificationServiceExtension: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var pendingHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var downloadTask: URLSessionDownloadTask?

    open override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        EngageExtensionLogger.info("received requestId=\(request.identifier)")
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            EngageExtensionLogger.warning("mutable content unavailable requestId=\(request.identifier)")
            contentHandler(request.content)
            return
        }
        lock.lock()
        pendingHandler = contentHandler
        bestAttemptContent = content
        lock.unlock()

        guard let engage = request.content.userInfo["engage"] as? [String: Any],
              let rawURL = engage["image_url"] as? String,
              let url = URL(string: rawURL),
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            EngageExtensionLogger.debug("rich media absent requestId=\(request.identifier)")
            finish(with: content)
            return
        }

        EngageExtensionLogger.debug(
            "rich media download started requestId=\(request.identifier) host=\(url.host ?? "unknown")"
        )
        let task = URLSession.shared.downloadTask(with: url) { [weak self] temporaryURL, response, error in
            guard let self else { return }
            if let temporaryURL,
               let attachment = try? self.makeAttachment(
                   temporaryURL: temporaryURL,
                   remoteURL: url,
                   response: response
               ) {
                content.attachments = content.attachments + [attachment]
                EngageExtensionLogger.info("rich media attached requestId=\(request.identifier)")
            } else if let error {
                EngageExtensionLogger.error(
                    "rich media download failed requestId=\(request.identifier) " +
                    "errorType=\(String(reflecting: type(of: error)))"
                )
            } else {
                EngageExtensionLogger.warning("rich media attachment unavailable requestId=\(request.identifier)")
            }
            self.finish(with: content)
        }
        lock.lock()
        downloadTask = task
        lock.unlock()
        task.resume()
    }

    open override func serviceExtensionTimeWillExpire() {
        EngageExtensionLogger.warning("extension time expiring")
        lock.lock()
        downloadTask?.cancel()
        let content = bestAttemptContent
        lock.unlock()
        if let content { finish(with: content) }
    }

    private func makeAttachment(
        temporaryURL: URL,
        remoteURL: URL,
        response: URLResponse?
    ) throws -> UNNotificationAttachment {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(
            "engage-push-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let suggested = response?.suggestedFilename ?? remoteURL.lastPathComponent
        let filename = suggested.isEmpty ? "attachment" : suggested
        let destination = directory.appendingPathComponent(filename)
        try manager.moveItem(at: temporaryURL, to: destination)
        EngageExtensionLogger.debug("attachment materialized extension=\(destination.pathExtension)")
        return try UNNotificationAttachment(identifier: "engage-rich-media", url: destination)
    }

    private func finish(with content: UNNotificationContent) {
        lock.lock()
        guard let handler = pendingHandler else {
            lock.unlock()
            EngageExtensionLogger.debug("finish ignored reason=already_completed")
            return
        }
        pendingHandler = nil
        bestAttemptContent = nil
        downloadTask = nil
        lock.unlock()
        EngageExtensionLogger.info("content handler completing attachments=\(content.attachments.count)")
        handler(content)
    }
}

private enum EngageExtensionLogger {
    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "io.engage.sdk", category: "Engage")
    #endif

    static func debug(_ value: String) { emit("DEBUG", value) }
    static func info(_ value: String) { emit("INFO", value) }
    static func warning(_ value: String) { emit("WARN", value) }
    static func error(_ value: String) { emit("ERROR", value) }

    private static func emit(_ level: String, _ value: String) {
        let line = "[\(level)] [Push.ServiceExtension] \(value)"
        #if canImport(OSLog)
        logger.log("\(line, privacy: .public)")
        #else
        print("Engage \(line)")
        #endif
    }
}
#endif

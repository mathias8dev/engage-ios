#if canImport(UserNotifications)
import Foundation
import UserNotifications

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
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
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
            finish(with: content)
            return
        }

        let task = URLSession.shared.downloadTask(with: url) { [weak self] temporaryURL, response, _ in
            guard let self else { return }
            if let temporaryURL,
               let attachment = try? self.makeAttachment(
                   temporaryURL: temporaryURL,
                   remoteURL: url,
                   response: response
               ) {
                content.attachments = content.attachments + [attachment]
            }
            self.finish(with: content)
        }
        lock.lock()
        downloadTask = task
        lock.unlock()
        task.resume()
    }

    open override func serviceExtensionTimeWillExpire() {
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
        return try UNNotificationAttachment(identifier: "engage-rich-media", url: destination)
    }

    private func finish(with content: UNNotificationContent) {
        lock.lock()
        guard let handler = pendingHandler else { lock.unlock(); return }
        pendingHandler = nil
        bestAttemptContent = nil
        downloadTask = nil
        lock.unlock()
        handler(content)
    }
}
#endif

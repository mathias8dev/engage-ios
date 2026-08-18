import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

public enum ForegroundPresentation: Sendable { case show, silent }

public struct PushConfig: @unchecked Sendable {
    public let foregroundPresentation: ForegroundPresentation
    #if canImport(UserNotifications)
    public let notificationCategories: Set<UNNotificationCategory>
    #endif

    public init(foregroundPresentation: ForegroundPresentation = .show) {
        self.foregroundPresentation = foregroundPresentation
        #if canImport(UserNotifications)
        notificationCategories = []
        #endif
    }

    #if canImport(UserNotifications)
    public init(
        foregroundPresentation: ForegroundPresentation = .show,
        notificationCategories: Set<UNNotificationCategory>
    ) {
        self.foregroundPresentation = foregroundPresentation
        self.notificationCategories = notificationCategories
    }
    #endif
}

public struct EngageConfig: @unchecked Sendable {
    public let appKey: String
    public let endpoint: URL
    /// Previous endpoints whose pre-2.1 endpoint-scoped storage belongs to this App Key.
    ///
    /// Set this only when changing the endpoint in the same release that adopts stable
    /// App-Key-scoped storage. The current endpoint is always considered automatically.
    public let legacyEndpoints: [URL]
    public let push: PushConfig
    public let logLevel: EngageLogLevel

    public init(
        appKey: String,
        endpoint: URL = URL(string: "https://api.engage.io/v1/")!,
        legacyEndpoints: [URL] = [],
        push: PushConfig = PushConfig(),
        logLevel: EngageLogLevel = .info
    ) {
        precondition(appKey.hasPrefix("eng_app_"), "EngageConfig.appKey must start with eng_app_")
        self.appKey = appKey
        self.endpoint = endpoint
        self.legacyEndpoints = legacyEndpoints
        self.push = push
        self.logLevel = logLevel
    }
}

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
    public let push: PushConfig
    public let logLevel: EngageLogLevel

    public init(
        appKey: String,
        endpoint: URL = URL(string: "https://api.engage.io/v1/")!,
        push: PushConfig = PushConfig(),
        logLevel: EngageLogLevel = .info
    ) {
        precondition(appKey.hasPrefix("eng_app_"), "EngageConfig.appKey must start with eng_app_")
        self.appKey = appKey
        self.endpoint = endpoint
        self.push = push
        self.logLevel = logLevel
    }
}

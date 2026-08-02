import Foundation
import EngageCore
@_spi(Modules) import EngageCore
#if canImport(UIKit)
import UIKit
import UserNotifications

public enum PushSubscriptionState: String, Sendable { case optedIn = "OPTED_IN", optedOut = "OPTED_OUT" }
public enum PushPermission: String, Sendable {
    case notDetermined = "NOT_DETERMINED"
    case denied = "DENIED"
    case authorized = "AUTHORIZED"
    case provisional = "PROVISIONAL"
    case ephemeral = "EPHEMERAL"
}
public enum PushError: Error, Sendable { case localPersistenceFailed, operationNotPersisted }
public struct PushStatus: Sendable {
    public let permission: PushPermission
    public let subscription: PushSubscriptionState
    public let tokenRegistered: Bool
}
public enum PushEvent: Sendable {
    case received(deliveryId: String, messageId: String, data: [String: String])
    case opened(deliveryId: String, messageId: String, deepLink: URL?, data: [String: String])
    case dismissed(deliveryId: String, messageId: String)
    case actionSelected(deliveryId: String, messageId: String, actionKey: String, data: [String: String])
    case registrationFailed(message: String)
}

public final class Push: @unchecked Sendable {
    private let context: EngageModuleContext
    private let persistence = PushPersistence()
    private let center = UNUserNotificationCenter.current()
    private let eventBus = EngageSignalBus<PushEvent>()
    private let lock = NSLock()
    private var token: String?
    private var delegateProxy: PushNotificationDelegate?
    private var previousPrivacy: PrivacyState

    public let status: EngageState<PushStatus>
    public var events: AsyncStream<PushEvent> { eventBus.events }

    init(context: EngageModuleContext) {
        self.context = context
        if !context.installationActive.value { try? persistence.wipe() }
        let stored = persistence.value
        let subscription = PushSubscriptionState(rawValue: stored.subscription) ?? .optedIn
        token = stored.token
        previousPrivacy = context.privacy.value
        status = EngageState(PushStatus(permission: .notDetermined, subscription: subscription, tokenRegistered: false))
        context.register(
            EngageModuleRegistration(
                id: "engage-push-apns",
                features: [.push],
                syncModules: [.push],
                wipe: { [weak self] in try self?.wipe() }
            )
        )
        Task {
            await installDelegate()
            let categories = await center.notificationCategories()
                .union(context.config.push.notificationCategories)
            await center.setNotificationCategories(categories)
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
            await refreshPermission()
            observeRuntime()
            _ = await queueSubscriptionIfNeeded()
            await synchronizeToken()
        }
    }

    /// Forwards the APNs token delivered by
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    ///
    /// Engage calls `registerForRemoteNotifications()` but deliberately does not swizzle the
    /// application delegate. This is the only APNs registration callback the host App must forward.
    public func didRegisterForRemoteNotifications(deviceToken: Data) {
        storeDeviceToken(deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    /// Forwards an APNs registration failure for diagnostics and subscribers.
    public func didFailToRegisterForRemoteNotifications(error: Error) {
        eventBus.emit(.registrationFailed(message: String(describing: error)))
    }

    private func storeDeviceToken(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        lock.lock(); token = normalized; lock.unlock()
        try? persistence.edit { $0.token = normalized }
        Task { await submitTokenIfNeeded(normalized) }
    }

    public func optIn() async throws {
        try persistSubscription(.optedIn)
        guard await queueSubscriptionIfNeeded() else { throw PushError.operationNotPersisted }
        if let token = currentToken() { await submitTokenIfNeeded(token) }
    }

    public func optOut() async throws {
        try persistSubscription(.optedOut)
        guard await queueSubscriptionIfNeeded() else { throw PushError.operationNotPersisted }
    }

    private func observeRuntime() {
        Task { [weak self] in
            guard let self else { return }
            for await documents in context.documents(.push).updates {
                guard let state = documents.first(where: { $0.key == "state" })?.payload else { continue }
                let old = status.value
                let subscription = state.string("subscription")
                    .flatMap(PushSubscriptionState.init(rawValue:)) ?? old.subscription
                if !persistence.value.pendingSubscription, subscription != old.subscription {
                    try? persistence.edit { $0.subscription = subscription.rawValue }
                }
                status.set(PushStatus(
                    permission: old.permission,
                    subscription: persistence.value.pendingSubscription ? old.subscription : subscription,
                    tokenRegistered: state.bool("tokenRegistered") ?? old.tokenRegistered
                ))
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await _ in context.enabledFeatures.updates { await synchronizeToken() }
        }
        Task { [weak self] in
            guard let self else { return }
            for await privacy in context.privacy.updates {
                if previousPrivacy == .optedOut, privacy == .optedIn {
                    _ = await queueSubscriptionIfNeeded(force: true)
                    await refreshPermission()
                    await synchronizeToken()
                }
                previousPrivacy = privacy
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await signal in context.signals.events {
                if case .appOpened = signal {
                    await refreshPermission()
                    _ = await queueSubscriptionIfNeeded()
                    if let token = currentToken() { await submitTokenIfNeeded(token) }
                } else if case .networkAvailable = signal {
                    _ = await queueSubscriptionIfNeeded()
                }
            }
        }
    }

    @MainActor private func installDelegate() {
        let proxy = PushNotificationDelegate(owner: self, downstream: center.delegate)
        delegateProxy = proxy
        center.delegate = proxy
    }

    private func refreshPermission() async {
        let settings = await center.notificationSettings()
        let permission: PushPermission
        switch settings.authorizationStatus {
        case .notDetermined: permission = .notDetermined
        case .denied: permission = .denied
        case .authorized: permission = .authorized
        case .provisional: permission = .provisional
        case .ephemeral: permission = .ephemeral
        @unknown default: permission = .denied
        }
        let old = status.value
        status.set(PushStatus(permission: permission, subscription: old.subscription, tokenRegistered: old.tokenRegistered))
        guard context.privacy.value == .optedIn,
              persistence.value.reportedPermission != permission.rawValue else { return }
        if await context.enqueue(type: "PUSH_PERMISSION_SET", payload: ["state": .string(permission.rawValue)]) {
            try? persistence.edit { $0.reportedPermission = permission.rawValue }
        }
    }

    private func submitTokenIfNeeded(_ value: String) async {
        guard context.privacy.value == .optedIn, context.enabledFeatures.value.contains(.push) else { return }
        let hash = stableTokenHash(value)
        guard persistence.value.registeredTokenHash != hash else { return }
        if await context.enqueue(type: "PUSH_TOKEN_SET", payload: ["token": .string(value)]) {
            try? persistence.edit { $0.registeredTokenHash = hash }
        }
    }

    private func synchronizeToken() async {
        guard context.privacy.value == .optedIn else { return }
        guard context.enabledFeatures.value.contains(.push) else {
            if persistence.value.registeredTokenHash != PushStoredState.disabledMarker {
                if await context.enqueue(type: "PUSH_TOKEN_SET", payload: ["token": .null]) {
                    try? persistence.edit { $0.registeredTokenHash = PushStoredState.disabledMarker }
                    let old = status.value
                    status.set(PushStatus(
                        permission: old.permission,
                        subscription: old.subscription,
                        tokenRegistered: false
                    ))
                }
            }
            return
        }
        if let token = currentToken() { await submitTokenIfNeeded(token) }
    }

    private func persistSubscription(_ value: PushSubscriptionState) throws {
        do {
            try persistence.edit {
                $0.subscription = value.rawValue
                $0.pendingSubscription = true
            }
        }
        catch { throw PushError.localPersistenceFailed }
        let old = status.value
        status.set(PushStatus(permission: old.permission, subscription: value, tokenRegistered: old.tokenRegistered))
    }

    private func currentToken() -> String? { lock.lock(); defer { lock.unlock() }; return token }

    private func queueSubscriptionIfNeeded(force: Bool = false) async -> Bool {
        let stored = persistence.value
        guard force || stored.pendingSubscription else { return true }
        guard context.privacy.value == .optedIn else { return true }
        let queued = await context.enqueue(
            type: "PUSH_SUBSCRIPTION_SET",
            payload: ["state": .string(stored.subscription)]
        )
        if queued {
            try? persistence.edit { $0.pendingSubscription = false }
        }
        return queued
    }

    private func wipe() throws {
        try persistence.wipe()
        lock.lock(); token = nil; lock.unlock()
        status.set(PushStatus(permission: status.value.permission, subscription: .optedIn, tokenRegistered: false))
    }

    fileprivate func willPresent(_ notification: UNNotification) -> UNNotificationPresentationOptions {
        guard let payload = PushPayload(notification.request.content.userInfo), canRun else { return [] }
        eventBus.emit(.received(deliveryId: payload.deliveryId, messageId: payload.messageId, data: payload.customData))
        Task { await receipt(payload.deliveryId, type: "DELIVERED") }
        return context.config.push.foregroundPresentation == .show ? [.banner, .list, .sound, .badge] : []
    }

    fileprivate func didReceive(_ response: UNNotificationResponse) {
        guard let payload = PushPayload(response.notification.request.content.userInfo), canRun else { return }
        if response.actionIdentifier == UNNotificationDismissActionIdentifier {
            eventBus.emit(.dismissed(deliveryId: payload.deliveryId, messageId: payload.messageId))
            return
        }
        Task { await receipt(payload.deliveryId, type: "OPENED") }
        if response.actionIdentifier != UNNotificationDefaultActionIdentifier {
            eventBus.emit(.actionSelected(
                deliveryId: payload.deliveryId, messageId: payload.messageId,
                actionKey: response.actionIdentifier, data: payload.customData
            ))
            Task { _ = await context.executeAction(response.actionIdentifier, arguments: payload.arguments) }
        } else {
            eventBus.emit(.opened(
                deliveryId: payload.deliveryId, messageId: payload.messageId,
                deepLink: payload.deepLink, data: payload.customData
            ))
            if payload.actionType == "CUSTOM", let action = payload.actionValue {
                Task { _ = await context.executeAction(action, arguments: payload.arguments) }
            }
        }
    }

    private var canRun: Bool {
        context.privacy.value == .optedIn && context.enabledFeatures.value.contains(.push)
    }
    private func receipt(_ deliveryId: String, type: String) async {
        await context.enqueue(type: "PUSH_RECEIPT_RECORDED", payload: [
            "deliveryId": .string(deliveryId), "type": .string(type),
        ])
    }
}

private final class PushNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    weak var owner: Push?
    weak var downstream: UNUserNotificationCenterDelegate?
    init(owner: Push, downstream: UNUserNotificationCenterDelegate?) {
        self.owner = owner; self.downstream = downstream
    }
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let engage = owner?.willPresent(notification) ?? []
        let app = await downstream?.userNotificationCenter?(center, willPresent: notification) ?? []
        return engage.union(app)
    }
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        owner?.didReceive(response)
        await downstream?.userNotificationCenter?(center, didReceive: response)
    }
}

private struct PushPayload {
    let deliveryId: String, messageId: String
    let actionType: String, actionValue: String?
    let arguments: EngagePayload
    let customData: [String: String]
    var deepLink: URL? {
        ["DEEPLINK", "WEB_URL"].contains(actionType) ? actionValue.flatMap(URL.init(string:)) : nil
    }

    init?(_ userInfo: [AnyHashable: Any]) {
        guard let engage = userInfo["engage"] as? [String: Any],
              let delivery = engage["engage_delivery_id"] as? String,
              let message = engage["engage_message_id"] as? String else { return nil }
        deliveryId = delivery; messageId = message
        actionType = engage["engage_action_type"] as? String ?? "OPEN_APP"
        actionValue = engage["engage_action_value"] as? String
        let strings = engage.compactMapValues { $0 as? String }
        arguments = Dictionary(uniqueKeysWithValues: strings.compactMap { key, value in
            key.hasPrefix("engage_action_arg_") ? (String(key.dropFirst(18)), .string(value)) : nil
        })
        customData = strings.filter { !$0.key.hasPrefix("engage_") }
    }
}

private func stableTokenHash(_ value: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    value.utf8.forEach { hash = (hash ^ UInt64($0)) &* 0x100000001b3 }
    return String(hash, radix: 16)
}

/// Public entry point when the standalone `EngagePush` Swift Package product is used.
///
/// `EngageSDK` activates this module automatically. With a modular installation, call
/// `EngageCore.start(config:)` first, then retain or use the value returned by `activate()`.
public enum PushModule {
    @discardableResult
    public static func activate() -> Push { PushHolder.shared }

    public static var shared: Push { activate() }
}
private enum PushHolder { static let shared = Push(context: EngageCore.moduleContext) }
#endif

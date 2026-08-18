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
    private let persistence: PushPersistence
    private let center = UNUserNotificationCenter.current()
    private let eventBus = EngageSignalBus<PushEvent>()
    private let lock = NSLock()
    private var token: String?
    private var previousPrivacy: PrivacyState

    public let status: EngageState<PushStatus>
    public var events: AsyncStream<PushEvent> { eventBus.events }

    init(context: EngageModuleContext) {
        self.context = context
        persistence = PushPersistence(directory: context.storageDirectory(module: "push"))
        EngageLogger.info(
            "Push",
            "initializing generation=\(context.generation.value) installationId=\(context.installationId.value ?? "none")"
        )
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
            EngageLogger.debug("Push", "startup task started")
            await installDelegate()
            let categories = await center.notificationCategories()
                .union(context.config.push.notificationCategories)
            center.setNotificationCategories(categories)
            EngageLogger.debug("Push", "notification categories registered count=\(categories.count)")
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
            EngageLogger.info("Push", "APNs registration requested")
            await refreshPermission()
            observeRuntime()
            _ = await queueSubscriptionIfNeeded()
            await synchronizeToken()
            EngageLogger.info("Push", "startup task completed")
        }
    }

    /// Forwards the APNs token delivered by
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    ///
    /// Engage calls `registerForRemoteNotifications()` but deliberately does not swizzle the
    /// application delegate. This is the only APNs registration callback the host App must forward.
    public func didRegisterForRemoteNotifications(deviceToken: Data) {
        EngageLogger.info("Push", "APNs registration succeeded tokenBytes=\(deviceToken.count)")
        storeDeviceToken(deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    /// Forwards an APNs registration failure for diagnostics and subscribers.
    public func didFailToRegisterForRemoteNotifications(error: Error) {
        EngageLogger.error("Push", "APNs registration failed", error: error)
        eventBus.emit(.registrationFailed(message: String(describing: error)))
    }

    private func storeDeviceToken(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            EngageLogger.warning("Push", "empty APNs token ignored")
            return
        }
        let tokenHash = stableTokenHash(normalized)
        EngageLogger.debug("Push", "APNs token storing hashPrefix=\(tokenHash.prefix(12)) length=\(normalized.count)")
        lock.lock(); token = normalized; lock.unlock()
        do { try persistence.edit { $0.token = normalized } }
        catch { EngageLogger.error("Push", "APNs token persistence failed", error: error) }
        Task { await submitTokenIfNeeded(normalized) }
    }

    public func optIn() async throws {
        EngageLogger.info("Push", "opt-in requested")
        try persistSubscription(.optedIn)
        guard await queueSubscriptionIfNeeded() else { throw PushError.operationNotPersisted }
        if let token = currentToken() { await submitTokenIfNeeded(token) }
        EngageLogger.info("Push", "opt-in queued")
    }

    public func optOut() async throws {
        EngageLogger.info("Push", "opt-out requested")
        try persistSubscription(.optedOut)
        guard await queueSubscriptionIfNeeded() else { throw PushError.operationNotPersisted }
        EngageLogger.info("Push", "opt-out queued")
    }

    private func observeRuntime() {
        Task { [weak self] in
            guard let self else { return }
            for await documents in context.documents(.push).updates {
                EngageLogger.debug("Push", "remote documents received count=\(documents.count)")
                guard let state = documents.first(where: { $0.key == "state" })?.payload else {
                    EngageLogger.verbose("Push", "remote state absent")
                    continue
                }
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
                EngageLogger.info(
                    "Push",
                    "status synchronized permission=\(status.value.permission) subscription=\(status.value.subscription) " +
                        "tokenRegistered=\(status.value.tokenRegistered)"
                )
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await features in context.enabledFeatures.updates {
                EngageLogger.debug("Push", "enabled features changed pushEnabled=\(features.contains(.push))")
                await synchronizeToken()
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await privacy in context.privacy.updates {
                EngageLogger.debug("Push", "privacy changed previous=\(previousPrivacy) current=\(privacy)")
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
                let signalType: String
                switch signal {
                case .event: signalType = "event"
                case .screenViewed: signalType = "screenViewed"
                case .screenCleared: signalType = "screenCleared"
                case .appOpened: signalType = "appOpened"
                case .appBackgrounded: signalType = "appBackgrounded"
                case .networkAvailable: signalType = "networkAvailable"
                case .localDataWiped: signalType = "localDataWiped"
                }
                EngageLogger.verbose("Push", "signal received type=\(signalType)")
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
        PushDelegateCoordinator.attach(self, center: center)
        EngageLogger.info("Push", "notification delegate attached")
    }

    private func refreshPermission() async {
        EngageLogger.debug("Push", "permission refresh started")
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
        EngageLogger.info("Push", "permission resolved state=\(permission)")
        guard context.privacy.value == .optedIn,
              persistence.value.reportedPermission != permission.rawValue else {
            EngageLogger.verbose("Push", "permission signal skipped reason=unchanged_or_privacy")
            return
        }
        if await context.enqueue(type: "PUSH_PERMISSION_SET", payload: ["state": .string(permission.rawValue)]) {
            try? persistence.edit { $0.reportedPermission = permission.rawValue }
            EngageLogger.info("Push", "permission signal queued state=\(permission)")
        }
    }

    private func submitTokenIfNeeded(_ value: String) async {
        guard context.privacy.value == .optedIn, context.enabledFeatures.value.contains(.push) else {
            EngageLogger.debug("Push", "token submission skipped reason=privacy_or_feature")
            return
        }
        let hash = stableTokenHash(value)
        guard persistence.value.registeredTokenHash != hash else {
            EngageLogger.verbose("Push", "token submission skipped hashPrefix=\(hash.prefix(12)) reason=unchanged")
            return
        }
        EngageLogger.debug("Push", "token submission queueing hashPrefix=\(hash.prefix(12))")
        if await context.enqueue(type: "PUSH_TOKEN_SET", payload: ["token": .string(value)]) {
            try? persistence.edit { $0.registeredTokenHash = hash }
            EngageLogger.info("Push", "token submission queued hashPrefix=\(hash.prefix(12))")
        }
    }

    private func synchronizeToken() async {
        guard context.privacy.value == .optedIn else {
            EngageLogger.debug("Push", "token synchronization skipped reason=privacy")
            return
        }
        EngageLogger.debug("Push", "token synchronization started pushEnabled=\(context.enabledFeatures.value.contains(.push))")
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
                    EngageLogger.info("Push", "remote token disabled")
                }
            }
            return
        }
        if let token = currentToken() { await submitTokenIfNeeded(token) }
        else { EngageLogger.debug("Push", "token synchronization deferred reason=no_local_token") }
    }

    private func persistSubscription(_ value: PushSubscriptionState) throws {
        EngageLogger.debug("Push", "subscription persisting state=\(value)")
        do {
            try persistence.edit {
                $0.subscription = value.rawValue
                $0.pendingSubscription = true
            }
        }
        catch {
            EngageLogger.error("Push", "subscription persistence failed state=\(value)", error: error)
            throw PushError.localPersistenceFailed
        }
        let old = status.value
        status.set(PushStatus(permission: old.permission, subscription: value, tokenRegistered: old.tokenRegistered))
        EngageLogger.info("Push", "subscription persisted state=\(value)")
    }

    private func currentToken() -> String? { lock.lock(); defer { lock.unlock() }; return token }

    private func queueSubscriptionIfNeeded(force: Bool = false) async -> Bool {
        let stored = persistence.value
        guard force || stored.pendingSubscription else {
            EngageLogger.verbose("Push", "subscription queue skipped reason=no_pending_change")
            return true
        }
        guard context.privacy.value == .optedIn else {
            EngageLogger.debug("Push", "subscription queue deferred reason=privacy")
            return true
        }
        EngageLogger.debug("Push", "subscription queueing state=\(stored.subscription) force=\(force)")
        let queued = await context.enqueue(
            type: "PUSH_SUBSCRIPTION_SET",
            payload: ["state": .string(stored.subscription)]
        )
        if queued {
            try? persistence.edit { $0.pendingSubscription = false }
        }
        EngageLogger.info("Push", "subscription queue result state=\(stored.subscription) queued=\(queued)")
        return queued
    }

    private func wipe() throws {
        EngageLogger.warning("Push", "local state wipe started")
        try persistence.wipe()
        lock.lock(); token = nil; lock.unlock()
        status.set(PushStatus(permission: status.value.permission, subscription: .optedIn, tokenRegistered: false))
        EngageLogger.warning("Push", "local state wiped")
    }

    fileprivate func willPresent(_ notification: UNNotification) -> UNNotificationPresentationOptions {
        guard let payload = PushPayload(notification.request.content.userInfo) else {
            EngageLogger.verbose("Push", "foreground notification ignored reason=not_engage")
            return []
        }
        if let target = payload.installationId, target != context.installationId.value {
            EngageLogger.debug(
                "Push",
                "foreground notification ignored deliveryId=\(payload.deliveryId) reason=installation_mismatch"
            )
            return []
        }
        guard canRun else {
            EngageLogger.debug("Push", "foreground notification ignored deliveryId=\(payload.deliveryId) reason=disabled")
            return []
        }
        do {
            guard try persistence.claimDelivery(payload.deliveryId) else {
                EngageLogger.debug(
                    "Push",
                    "foreground notification ignored deliveryId=\(payload.deliveryId) reason=duplicate_delivery"
                )
                return []
            }
        } catch {
            EngageLogger.error("Push", "foreground delivery claim failed", error: error)
            return []
        }
        EngageLogger.info(
            "Push",
            "foreground notification received deliveryId=\(payload.deliveryId) messageId=\(payload.messageId) " +
                "customKeys=\(payload.customData.keys.sorted())"
        )
        eventBus.emit(.received(deliveryId: payload.deliveryId, messageId: payload.messageId, data: payload.customData))
        Task { await receipt(payload.deliveryId, type: "DELIVERED") }
        let presentation: UNNotificationPresentationOptions =
            context.config.push.foregroundPresentation == .show ? [.banner, .list, .sound, .badge] : []
        EngageLogger.debug("Push", "foreground presentation deliveryId=\(payload.deliveryId) show=\(!presentation.isEmpty)")
        return presentation
    }

    fileprivate func didReceive(_ response: UNNotificationResponse) {
        guard let payload = PushPayload(response.notification.request.content.userInfo) else {
            EngageLogger.verbose("Push", "notification response ignored reason=not_engage")
            return
        }
        if let target = payload.installationId, target != context.installationId.value {
            EngageLogger.debug(
                "Push",
                "notification response ignored deliveryId=\(payload.deliveryId) reason=installation_mismatch"
            )
            return
        }
        guard canRun else {
            EngageLogger.debug("Push", "notification response ignored deliveryId=\(payload.deliveryId) reason=disabled")
            return
        }
        EngageLogger.info(
            "Push",
            "notification response deliveryId=\(payload.deliveryId) messageId=\(payload.messageId) " +
                "actionIdentifier=\(response.actionIdentifier)"
        )
        if response.actionIdentifier == UNNotificationDismissActionIdentifier {
            eventBus.emit(.dismissed(deliveryId: payload.deliveryId, messageId: payload.messageId))
            EngageLogger.info("Push", "notification dismissed deliveryId=\(payload.deliveryId)")
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
            if payload.actionType == "WEB_URL" {
                openWebURL(payload)
            } else if payload.actionType == "CUSTOM", let action = payload.actionValue {
                Task { _ = await context.executeAction(action, arguments: payload.arguments) }
            }
        }
    }

    private func openWebURL(_ payload: PushPayload) {
        guard let url = payload.webURL else {
            EngageLogger.warning(
                "Push",
                "web URL ignored deliveryId=\(payload.deliveryId) reason=invalid_destination"
            )
            return
        }
        let deliveryId = payload.deliveryId
        Task { @MainActor in
            UIApplication.shared.open(url, options: [:]) { opened in
                if opened {
                    EngageLogger.info("Push", "web URL opened deliveryId=\(deliveryId) host=\(url.host ?? "none")")
                } else {
                    EngageLogger.warning("Push", "web URL open failed deliveryId=\(deliveryId) reason=no_handler")
                }
            }
        }
    }

    private var canRun: Bool {
        context.privacy.value == .optedIn && context.enabledFeatures.value.contains(.push)
    }
    private func receipt(_ deliveryId: String, type: String) async {
        EngageLogger.debug("Push", "receipt queueing deliveryId=\(deliveryId) type=\(type)")
        let queued = await context.enqueue(type: "PUSH_RECEIPT_RECORDED", payload: [
            "deliveryId": .string(deliveryId), "type": .string(type),
        ])
        EngageLogger.info("Push", "receipt queue result deliveryId=\(deliveryId) type=\(type) queued=\(queued)")
    }
}

private enum BufferedPushEvent {
    case notification(UNNotification)
    case response(UNNotificationResponse)
}

private final class PushNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private weak var owner: Push?
    private weak var downstream: UNUserNotificationCenterDelegate?
    private var buffered: [BufferedPushEvent] = []

    func install(on center: UNUserNotificationCenter) {
        lock.lock()
        if center.delegate !== self { downstream = center.delegate }
        lock.unlock()
        center.delegate = self
    }

    func attach(_ owner: Push) {
        lock.lock()
        self.owner = owner
        let pending = buffered
        buffered.removeAll()
        lock.unlock()
        for event in pending {
            switch event {
            case .notification(let notification): _ = owner.willPresent(notification)
            case .response(let response): owner.didReceive(response)
            }
        }
        EngageLogger.info("Push.Delegate", "owner attached buffered=\(pending.count)")
    }

    private func targetOrBuffer(_ event: BufferedPushEvent) -> Push? {
        lock.lock(); defer { lock.unlock() }
        guard let owner else {
            buffered.append(event)
            if buffered.count > 64 { buffered.removeFirst(buffered.count - 64) }
            EngageLogger.debug("Push.Delegate", "event buffered pending=\(buffered.count)")
            return nil
        }
        return owner
    }

    private var downstreamDelegate: UNUserNotificationCenterDelegate? {
        lock.lock(); defer { lock.unlock() }
        return downstream
    }
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        EngageLogger.verbose("Push.Delegate", "willPresent forwarding")
        let engage = targetOrBuffer(.notification(notification))?.willPresent(notification) ?? []
        let forwarded: Void? = downstreamDelegate?.userNotificationCenter?(
            center,
            willPresent: notification,
            withCompletionHandler: { app in completionHandler(engage.union(app)) }
        )
        if forwarded == nil { completionHandler(engage) }
    }
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        EngageLogger.verbose("Push.Delegate", "didReceive forwarding actionIdentifier=\(response.actionIdentifier)")
        targetOrBuffer(.response(response))?.didReceive(response)
        let forwarded: Void? = downstreamDelegate?.userNotificationCenter?(
            center,
            didReceive: response,
            withCompletionHandler: completionHandler
        )
        if forwarded == nil { completionHandler() }
    }
}

private enum PushDelegateCoordinator {
    static let proxy = PushNotificationDelegate()

    static func prepare(center: UNUserNotificationCenter = .current()) {
        proxy.install(on: center)
        EngageLogger.info("Push.Delegate", "launch delegate prepared")
    }

    static func attach(_ owner: Push, center: UNUserNotificationCenter) {
        prepare(center: center)
        proxy.attach(owner)
    }
}

private struct PushPayload {
    let deliveryId: String, messageId: String
    let installationId: String?
    let actionType: String, actionValue: String?
    let arguments: EngagePayload
    let customData: [String: String]
    var deepLink: URL? {
        actionType == "DEEPLINK" ? actionValue.flatMap(URL.init(string:)) : nil
    }
    var webURL: URL? {
        guard actionType == "WEB_URL", let url = actionValue.flatMap(URL.init(string:)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    init?(_ userInfo: [AnyHashable: Any]) {
        guard let engage = userInfo["engage"] as? [String: Any],
              let delivery = engage["engage_delivery_id"] as? String,
              let message = engage["engage_message_id"] as? String else {
            EngageLogger.verbose("Push.Payload", "payload rejected reason=missing_technical_ids")
            return nil
        }
        deliveryId = delivery; messageId = message
        installationId = engage["engage_installation_id"] as? String
        actionType = engage["engage_action_type"] as? String ?? "OPEN_APP"
        actionValue = engage["engage_action_value"] as? String
        let strings = engage.compactMapValues { $0 as? String }
        arguments = Dictionary(uniqueKeysWithValues: strings.compactMap { key, value in
            key.hasPrefix("engage_action_arg_") ? (String(key.dropFirst(18)), .string(value)) : nil
        })
        customData = strings.filter { !$0.key.hasPrefix("engage_") }
        EngageLogger.debug(
            "Push.Payload",
            "payload parsed deliveryId=\(deliveryId) messageId=\(messageId) actionType=\(actionType) " +
                "argumentKeys=\(arguments.keys.sorted()) customKeys=\(customData.keys.sorted())"
        )
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
    /// Installs a buffering notification delegate synchronously during application launch.
    public static func prepareForLaunch() {
        if Thread.isMainThread {
            PushDelegateCoordinator.prepare()
        } else {
            DispatchQueue.main.sync { PushDelegateCoordinator.prepare() }
        }
    }

    @discardableResult
    public static func activate() -> Push {
        EngageLogger.debug("Push", "module activation requested")
        return PushHolder.shared
    }

    public static var shared: Push { activate() }
}
private enum PushHolder { static let shared = Push(context: EngageCore.moduleContext) }
#endif

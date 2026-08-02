import Foundation

public enum EngageCore {
    private static let storage = EngageGlobalStorage()

    public static let state = EngageState<Bool>(false)

    public static func start(config: EngageConfig) {
        guard let created = storage.start(config: config) else { return }
        state.set(true)
        Task { await created.start() }
    }

    static func requireRuntime() -> CoreRuntime {
        storage.requireRuntime()
    }

    @_spi(Modules) public static var moduleContext: EngageModuleContext {
        let runtime = requireRuntime()
        return EngageModuleContext(runtime: runtime, config: runtime.config)
    }

    static func registerModule(_ registration: EngageModuleRegistration, runtime: CoreRuntime) {
        storage.register(registration)
        Task { await runtime.register(registration) }
    }

    static var moduleRegistrationsSnapshot: [EngageModuleRegistration] {
        storage.registrations
    }

    public static var installation: Installation { Installation(runtime: requireRuntime()) }
    public static var profile: Profile { Profile(runtime: requireRuntime()) }
    public static var events: Events {
        storage.requireEvents()
    }
    public static var actions: Actions { Actions(runtime: requireRuntime()) }
    public static var sdkFeatures: SdkFeatures { SdkFeatures(runtime: requireRuntime()) }
    public static var flags: FeatureFlags {
        storage.requireFlags()
    }
    public static var preferenceCenter: PreferenceCenter {
        storage.requirePreferenceCenter()
    }
    public static var privacy: Privacy { Privacy(runtime: requireRuntime()) }
}

private final class EngageGlobalStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var runtime: CoreRuntime?
    private var startedConfig: EngageConfig?
    private var events: Events?
    private var flags: FeatureFlags?
    private var preferenceCenter: PreferenceCenter?
    private var modules: [String: EngageModuleRegistration] = [:]

    func start(config: EngageConfig) -> CoreRuntime? {
        lock.lock(); defer { lock.unlock() }
        if let startedConfig {
            precondition(
                startedConfig.appKey == config.appKey && startedConfig.endpoint == config.endpoint,
                "Engage is already started with another App configuration"
            )
            return nil
        }
        let created = CoreRuntime(config: config, directory: engageStorageDirectory())
        runtime = created
        startedConfig = config
        events = Events(runtime: created)
        flags = FeatureFlags(runtime: created)
        preferenceCenter = PreferenceCenter(runtime: created)
        return created
    }

    func requireRuntime() -> CoreRuntime {
        lock.lock(); defer { lock.unlock() }
        guard let runtime else { preconditionFailure("Engage.start(config:) must be called first") }
        return runtime
    }

    func requireEvents() -> Events {
        lock.lock(); defer { lock.unlock() }
        guard let events else { preconditionFailure("Engage.start(config:) must be called first") }
        return events
    }

    func requireFlags() -> FeatureFlags {
        lock.lock(); defer { lock.unlock() }
        guard let flags else { preconditionFailure("Engage.start(config:) must be called first") }
        return flags
    }

    func requirePreferenceCenter() -> PreferenceCenter {
        lock.lock(); defer { lock.unlock() }
        guard let preferenceCenter else { preconditionFailure("Engage.start(config:) must be called first") }
        return preferenceCenter
    }

    func register(_ registration: EngageModuleRegistration) {
        lock.lock(); modules[registration.id] = registration; lock.unlock()
    }

    var registrations: [EngageModuleRegistration] {
        lock.lock(); defer { lock.unlock() }
        return Array(modules.values)
    }
}

public struct Installation: Sendable {
    private let runtime: CoreRuntime
    init(runtime: CoreRuntime) { self.runtime = runtime }
    public var id: EngageState<String?> { runtime.installationId }
    public func issueBindingCode() async throws -> String { try await runtime.issueBindingCode() }
    public func editAttributes(_ edit: (inout AttributeEditor) -> Void) {
        var editor = AttributeEditor(); edit(&editor)
        guard !editor.isEmpty else { return }
        Task { try? await runtime.enqueue(type: "INSTALLATION_ATTRIBUTES_EDITED", payload: editor.payload) }
    }
    public func editSubscriptions(_ edit: (inout InstallationSubscriptionEditor) -> Void) {
        var editor = InstallationSubscriptionEditor(); edit(&editor)
        guard !editor.changes.isEmpty else { return }
        Task {
            try? await runtime.enqueue(
                type: "INSTALLATION_SUBSCRIPTIONS_EDITED",
                payload: ["changes": .array(editor.changes.map { .object($0) })]
            )
        }
    }
}

public struct Profile: Sendable {
    private let runtime: CoreRuntime
    init(runtime: CoreRuntime) { self.runtime = runtime }
    public func editAttributes(_ edit: (inout AttributeEditor) -> Void) {
        var editor = AttributeEditor(); edit(&editor)
        guard !editor.isEmpty else { return }
        Task { try? await runtime.enqueue(type: "PROFILE_ATTRIBUTES_EDITED", payload: editor.payload) }
    }
    public func editTags(_ edit: (inout TagEditor) -> Void) {
        var editor = TagEditor(); edit(&editor)
        guard !editor.additions.isEmpty || !editor.removals.isEmpty else { return }
        Task {
            try? await runtime.enqueue(type: "PROFILE_TAGS_EDITED", payload: [
                "add": .array(editor.additions.sorted().map(JSONValue.string)),
                "remove": .array(editor.removals.sorted().map(JSONValue.string)),
            ])
        }
    }
    public func editSubscriptions(_ edit: (inout ProfileSubscriptionEditor) -> Void) {
        var editor = ProfileSubscriptionEditor(); edit(&editor)
        guard !editor.changes.isEmpty else { return }
        Task {
            try? await runtime.enqueue(
                type: "PROFILE_SUBSCRIPTIONS_EDITED",
                payload: ["changes": .array(editor.changes.map { .object($0) })]
            )
        }
    }
}

public struct AttributeEditor: Sendable {
    fileprivate var values: EngagePayload = [:]
    fileprivate var removals: Set<String> = []
    public init() {}
    public mutating func set(_ key: String, _ value: String) { set(key, .string(value)) }
    public mutating func set(_ key: String, _ value: Bool) { set(key, .bool(value)) }
    public mutating func set(_ key: String, _ value: Int) { set(key, .integer(Int64(value))) }
    public mutating func set(_ key: String, _ value: Int64) { set(key, .integer(value)) }
    public mutating func set(_ key: String, _ value: Double) {
        precondition(value.isFinite, "Attribute numbers must be finite")
        set(key, .number(value))
    }
    public mutating func set(_ key: String, _ value: Date) {
        set(key, .string(CoreRuntime.timestamp(value)))
    }
    public mutating func set(_ key: String, _ value: JSONValue) {
        precondition(CoreRuntime.keyPattern(key)); removals.remove(key); values[key] = value
    }
    public mutating func remove(_ key: String) {
        precondition(CoreRuntime.keyPattern(key)); values[key] = nil; removals.insert(key)
    }
    fileprivate var isEmpty: Bool { values.isEmpty && removals.isEmpty }
    fileprivate var payload: EngagePayload {
        ["set": .object(values), "remove": .array(removals.sorted().map(JSONValue.string))]
    }
}

public struct TagEditor: Sendable {
    fileprivate var additions: Set<String> = [], removals: Set<String> = []
    public init() {}
    public mutating func add(_ tag: String) { validate(tag); removals.remove(tag); additions.insert(tag) }
    public mutating func remove(_ tag: String) { validate(tag); additions.remove(tag); removals.insert(tag) }
    private func validate(_ tag: String) {
        precondition(
            !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && tag.count <= 64,
            "Tags must contain between 1 and 64 characters"
        )
    }
}

public enum Channel: String, Codable, Sendable {
    case email = "EMAIL"
    case sms = "SMS"
    case push = "PUSH"
    case whatsapp = "WHATSAPP"
}

public struct InstallationSubscriptionEditor: Sendable {
    fileprivate var changes: [EngagePayload] = []
    public init() {}
    public mutating func subscribe(_ list: String) { edit(list, subscribed: true) }
    public mutating func unsubscribe(_ list: String) { edit(list, subscribed: false) }

    private mutating func edit(_ list: String, subscribed: Bool) {
        precondition(CoreRuntime.keyPattern(list))
        changes.removeAll { $0.string("list") == list }
        changes.append(["list": .string(list), "subscribed": .bool(subscribed)])
    }
}

public struct ProfileSubscriptionEditor: Sendable {
    fileprivate var changes: [EngagePayload] = []
    public init() {}

    public mutating func subscribe(_ list: String, channels: Set<Channel>) {
        edit(list, channels: channels, subscribed: true)
    }

    public mutating func unsubscribe(_ list: String, channels: Set<Channel>) {
        edit(list, channels: channels, subscribed: false)
    }

    private mutating func edit(_ list: String, channels: Set<Channel>, subscribed: Bool) {
        precondition(CoreRuntime.keyPattern(list))
        precondition(!channels.isEmpty, "At least one subscription channel is required")
        for channel in channels {
            changes.removeAll { $0.string("list") == list && $0.string("channel") == channel.rawValue }
            changes.append([
                "list": .string(list), "channel": .string(channel.rawValue), "subscribed": .bool(subscribed),
            ])
        }
    }
}

public struct EventEditor: Sendable {
    fileprivate var properties: EngagePayload = [:]
    fileprivate var value: Double?
    fileprivate var transactionId: String?
    public init() {}
    public mutating func set(_ key: String, _ value: String) { set(key, .string(value)) }
    public mutating func set(_ key: String, _ value: Bool) { set(key, .bool(value)) }
    public mutating func set(_ key: String, _ value: Int) { set(key, .integer(Int64(value))) }
    public mutating func set(_ key: String, _ value: Int64) { set(key, .integer(value)) }
    public mutating func set(_ key: String, _ value: Double) {
        precondition(value.isFinite, "Event property numbers must be finite")
        set(key, .number(value))
    }
    public mutating func set(_ key: String, _ value: JSONValue) {
        precondition(CoreRuntime.keyPattern(key), "Event property keys must be lowercase product keys")
        properties[key] = value
    }
    public mutating func setValue(_ value: Double?) {
        precondition(value?.isFinite != false, "Event value must be finite")
        self.value = value
    }
    public mutating func setTransactionId(_ value: String?) {
        precondition(value?.count ?? 0 <= 255, "Event transactionId must contain at most 255 characters")
        transactionId = value
    }
}

public final class Events: @unchecked Sendable {
    private let runtime: CoreRuntime
    private let lock = NSLock()
    private var currentScreen: String?, previousScreen: String?
    private var visibleSince: TimeInterval?, accumulated: TimeInterval = 0
    init(runtime: CoreRuntime) {
        self.runtime = runtime
        Task { [weak self] in
            for await signal in runtime.signals.events {
                guard let self else { return }
                switch signal {
                case .appBackgrounded: self.pauseVisibility()
                case .appOpened: self.resumeVisibility()
                case .localDataWiped: self.resetScreen()
                default: break
                }
            }
        }
        Task { [weak self] in
            for await privacy in runtime.privacy.updates where privacy == .optedOut {
                self?.resetScreen()
            }
        }
        Task { [weak self] in
            for await features in runtime.enabledFeatures.updates
            where !features.contains(.analytics) && !features.contains(.inApp) {
                self?.resetScreen()
            }
        }
    }

    public func track(_ name: String, edit: (inout EventEditor) -> Void = { _ in }) {
        precondition(name.range(of: "^[a-z][a-z0-9_]{1,63}$", options: .regularExpression) != nil)
        var editor = EventEditor(); edit(&editor)
        guard runtime.privacy.value == .optedIn else { return }
        if runtime.enabledFeatures.value.contains(.inApp) {
            runtime.signals.emit(.event(name: name, properties: editor.properties))
        }
        guard runtime.enabledFeatures.value.contains(.analytics) else { return }
        var payload: EngagePayload = ["name": .string(name), "properties": .object(editor.properties)]
        if let value = editor.value { payload["value"] = .number(value) }
        if let transactionId = editor.transactionId { payload["transactionId"] = .string(transactionId) }
        Task { try? await runtime.enqueue(type: "EVENT_TRACKED", payload: payload) }
    }

    public func trackScreen(_ key: String) {
        precondition(CoreRuntime.keyPattern(key))
        let features = runtime.enabledFeatures.value
        guard runtime.privacy.value == .optedIn, features.contains(.analytics) || features.contains(.inApp) else { return }
        lock.lock()
        guard currentScreen != key else { lock.unlock(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let duration = visibleSince.map { accumulated + max(0, now - $0) }
        let previous = currentScreen
        previousScreen = previous
        currentScreen = key
        visibleSince = runtime.foreground.value ? now : nil
        accumulated = 0
        lock.unlock()
        if features.contains(.inApp) { runtime.signals.emit(.screenViewed(key)) }
        guard features.contains(.analytics) else { return }
        var payload: EngagePayload = ["screenKey": .string(key)]
        if let previous { payload["previousScreenKey"] = .string(previous) }
        if let duration {
            payload["previousVisibleDurationMillis"] = .integer(Int64(floor(duration * 1000)))
        }
        Task { try? await runtime.enqueue(type: "SCREEN_VIEWED", payload: payload) }
    }

    public func clearScreen() {
        let features = runtime.enabledFeatures.value
        guard runtime.privacy.value == .optedIn, features.contains(.analytics) || features.contains(.inApp) else { return }
        lock.lock()
        guard let screen = currentScreen else { lock.unlock(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let duration = accumulated + (visibleSince.map { max(0, now - $0) } ?? 0)
        currentScreen = nil; previousScreen = nil; visibleSince = nil; accumulated = 0
        lock.unlock()
        if features.contains(.inApp) { runtime.signals.emit(.screenCleared) }
        if features.contains(.analytics) {
            Task {
                try? await runtime.enqueue(type: "SCREEN_CLEARED", payload: [
                    "screenKey": .string(screen),
                    "visibleDurationMillis": .integer(Int64(floor(duration * 1000))),
                ])
            }
        }
    }

    public func flush() async throws { try await runtime.flush() }

    private func pauseVisibility() {
        lock.lock(); defer { lock.unlock() }
        if let visibleSince {
            accumulated += max(0, ProcessInfo.processInfo.systemUptime - visibleSince)
            self.visibleSince = nil
        }
    }
    private func resumeVisibility() {
        lock.lock(); defer { lock.unlock() }
        if currentScreen != nil && visibleSince == nil {
            visibleSince = ProcessInfo.processInfo.systemUptime
        }
    }
    private func resetScreen() {
        lock.lock(); defer { lock.unlock() }
        currentScreen = nil; previousScreen = nil; visibleSince = nil; accumulated = 0
    }
}

public enum ActionResult: Sendable, Equatable { case completed, rejected }
public struct EngageAction: Sendable {
    public let name: String
    public let arguments: ActionArguments
}

public struct ActionArguments: Sendable {
    private let values: EngagePayload
    init(_ values: EngagePayload) { self.values = values }
    public func string(_ key: String) -> String? { values.string(key) }
    public func boolean(_ key: String) -> Bool? { values.bool(key) }
    public func number(_ key: String) -> Double? { values.number(key) }
    public func requireString(_ key: String) -> String {
        guard let value = string(key) else { preconditionFailure("Missing action argument: \(key)") }
        return value
    }
    public var payload: EngagePayload { values }
}

public final class ActionRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?
    init(cancellation: @escaping () -> Void) { self.cancellation = cancellation }
    public func cancel() {
        lock.lock(); let value = cancellation; cancellation = nil; lock.unlock()
        value?()
    }
}

public struct Actions: Sendable {
    private let runtime: CoreRuntime
    init(runtime: CoreRuntime) { self.runtime = runtime }
    public func register(
        _ name: String,
        handler: @escaping @Sendable (EngageAction) async -> ActionResult
    ) -> ActionRegistration {
        precondition(CoreRuntime.keyPattern(name), "Action keys must use lowercase product keys")
        let id = UUID()
        let registration = ActionRegistration {
            Task { await runtime.unregisterAction(name, id: id) }
        }
        Task {
            await runtime.registerAction(name, id: id) { payload in
                await handler(EngageAction(name: name, arguments: ActionArguments(payload))) == .completed
            }
        }
        return registration
    }
}

public struct SdkFeatures: Sendable {
    private let runtime: CoreRuntime
    init(runtime: CoreRuntime) { self.runtime = runtime }
    public var enabled: EngageState<Set<SdkFeature>> { runtime.enabledFeatures }
    public func edit(_ edit: (inout SdkFeatureEditor) -> Void) async throws {
        var editor = SdkFeatureEditor(enabled: enabled.value)
        edit(&editor)
        try await runtime.editFeatures(editor.value)
    }
}

public struct SdkFeatureEditor: Sendable {
    fileprivate var value: Set<SdkFeature>
    fileprivate init(enabled: Set<SdkFeature>) { value = enabled }
    public mutating func enable(_ feature: SdkFeature) { value.insert(feature) }
    public mutating func disable(_ feature: SdkFeature) { value.remove(feature) }
}

public struct Privacy: Sendable {
    private let runtime: CoreRuntime
    init(runtime: CoreRuntime) { self.runtime = runtime }
    public var state: EngageState<PrivacyState> { runtime.privacy }
    public func optOut() async throws { try await runtime.optOut() }
    public func optIn() async throws { try await runtime.optIn() }
    public func optOutAndWipe() async throws { try await runtime.optOutAndWipe() }
}

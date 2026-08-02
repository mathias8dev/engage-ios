import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Network)
import Network
#endif

@_spi(Modules) public struct EngageModuleRegistration: Sendable {
    public let id: String
    public let features: Set<SdkFeature>
    public let syncModules: Set<SyncModule>
    public let wipe: @Sendable () async throws -> Void

    public init(
        id: String,
        features: Set<SdkFeature>,
        syncModules: Set<SyncModule>,
        wipe: @escaping @Sendable () async throws -> Void
    ) {
        self.id = id; self.features = features; self.syncModules = syncModules; self.wipe = wipe
    }
}

@_spi(Modules) public final class EngageModuleContext: @unchecked Sendable {
    private let runtime: CoreRuntime
    public let config: EngageConfig
    public let installationId: EngageState<String?>
    public let generation: EngageState<Int64>
    public let privacy: EngageState<PrivacyState>
    public let installationActive: EngageState<Bool>
    public let enabledFeatures: EngageState<Set<SdkFeature>>
    public let foreground: EngageState<Bool>
    public let signals: EngageSignalBus<EngageSignal>

    init(runtime: CoreRuntime, config: EngageConfig) {
        self.runtime = runtime; self.config = config
        installationId = runtime.installationId; generation = runtime.generation
        privacy = runtime.privacy; enabledFeatures = runtime.enabledFeatures; signals = runtime.signals
        installationActive = runtime.installationActive
        foreground = runtime.foreground
    }

    public func register(_ registration: EngageModuleRegistration) {
        EngageCore.registerModule(registration, runtime: runtime)
    }

    public func documents(_ module: SyncModule) -> EngageState<[RemoteDocument]> {
        let state = EngageState<[RemoteDocument]>([])
        let snapshots = runtime.syncSnapshot
        Task {
            for await snapshot in snapshots.updates {
                let compatible = snapshot.generation == self.generation.value
                state.set(compatible ? snapshot.documents.filter { $0.module == module } : [])
            }
        }
        return state
    }

    @discardableResult
    public func enqueue(
        type: String,
        payload: EngagePayload,
        operationId: String = UUID().uuidString.lowercased()
    ) async -> Bool {
        do {
            try await runtime.enqueue(type: type, payload: payload, operationId: operationId)
            return true
        } catch {
            return false
        }
    }

    public func refresh() async { try? await runtime.refresh() }

    public func authorizedRequest(
        method: String,
        path: String,
        query: [String: String] = [:],
        body: EngagePayload? = nil
    ) async throws -> AuthorizedResponse {
        try await runtime.authorizedRequest(method: method, path: path, query: query, body: body)
    }

    public func executeAction(_ name: String, arguments: EngagePayload) async -> Bool {
        await runtime.executeAction(name, arguments: arguments)
    }
}

actor CoreRuntime {
    nonisolated let config: EngageConfig
    nonisolated let installationId: EngageState<String?>
    nonisolated let generation: EngageState<Int64>
    nonisolated let privacy: EngageState<PrivacyState>
    nonisolated let installationActive: EngageState<Bool>
    nonisolated let enabledFeatures: EngageState<Set<SdkFeature>>
    nonisolated let syncSnapshot: EngageState<SyncSnapshot>
    nonisolated let outboxRevision = EngageState<Int64>(0)
    nonisolated let foreground = EngageState(false)
    nonisolated let signals = EngageSignalBus<EngageSignal>()

    private let persistence: CorePersistence
    private let client: MobileEdgeClient
    private var session: InstallationSession?
    private var modules: [String: EngageModuleRegistration] = [:]
    private var availableFeatures: Set<SdkFeature> = [.analytics, .preferences, .featureFlags]
    private var disabledFeatures: Set<SdkFeature>
    private var installationEnabled: Bool
    private struct RegisteredAction {
        let id: UUID
        let execute: @Sendable (EngagePayload) async -> Bool
    }
    private var actions: [String: RegisteredAction] = [:]
    private var cancelledActionRegistrations: Set<UUID> = []
    private var knownActionRegistrations: Set<UUID> = []
    private var refreshTask: Task<Void, Error>?
    private var automaticRefreshTask: Task<Void, Never>?
    private var automaticRefreshPending = false
    private var periodicRefreshTask: Task<Void, Never>?
    private var bindingPollTask: Task<Void, Never>?
    private var pendingBinding: PendingBinding?
    private var revocationTask: Task<Void, Never>?
    private var privacyFlushTask: Task<Void, Never>?
    private var foregroundActive = false
    #if canImport(UIKit)
    private var lifecycleObservers: [NSObjectProtocol] = []
    #endif
    #if canImport(Network)
    private var networkMonitor: EngageNetworkMonitor?
    #endif

    init(config: EngageConfig, directory: URL) {
        self.config = config
        let storage = CorePersistence(directory: directory)
        let initial = storage.initialState
        persistence = storage
        client = MobileEdgeClient(endpoint: config.endpoint, appKey: config.appKey)
        session = initial.session
        disabledFeatures = initial.disabledFeatures
        installationEnabled = initial.installationEnabled
        installationId = EngageState(initial.session?.installationId)
        generation = EngageState(initial.session?.generation ?? 0)
        privacy = EngageState(initial.privacy)
        installationActive = EngageState(initial.installationEnabled)
        enabledFeatures = EngageState(availableFeatures.subtracting(initial.disabledFeatures))
        syncSnapshot = EngageState(initial.sync)
    }

    func start() async {
        startRevocationReplay()
        #if canImport(UIKit)
        let lifecycle = await MainActor.run { () -> (Bool, [NSObjectProtocol]) in
            let active = UIApplication.shared.applicationState != .background
            let foreground = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { await self?.handleForeground() } }
            let background = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { await self?.handleBackground() } }
            return (active, [foreground, background])
        }
        foregroundActive = lifecycle.0
        foreground.set(lifecycle.0)
        lifecycleObservers = lifecycle.1
        #else
        foregroundActive = true
        foreground.set(true)
        #endif
        #if canImport(Network)
        let monitor = EngageNetworkMonitor { [weak self] in
            Task { await self?.networkBecameAvailable() }
        }
        networkMonitor = monitor
        monitor.start()
        #endif
        if privacy.value == .optedIn { requestAutomaticRefresh() }
        else { startPrivacyFlush() }
        schedulePeriodicRefresh()
    }

    func register(_ registration: EngageModuleRegistration) {
        guard modules[registration.id] == nil else { return }
        modules[registration.id] = registration
        availableFeatures.formUnion(registration.features)
        enabledFeatures.set(availableFeatures.subtracting(disabledFeatures))
        if !installationEnabled {
            Task { try? await registration.wipe() }
        }
        requestAutomaticRefresh()
    }

    func editFeatures(_ enabled: Set<SdkFeature>) async throws {
        let requested = enabled.intersection(availableFeatures)
        let candidate = disabledFeatures
            .subtracting(availableFeatures)
            .union(availableFeatures.subtracting(requested))
        try await persistence.setDisabledFeatures(candidate)
        disabledFeatures = candidate
        enabledFeatures.set(availableFeatures.subtracting(disabledFeatures))
        requestAutomaticRefresh()
    }

    func registerAction(
        _ name: String,
        id: UUID,
        action: @escaping @Sendable (EngagePayload) async -> Bool
    ) {
        precondition(Self.keyPattern(name), "Action keys must use lowercase product keys")
        if cancelledActionRegistrations.remove(id) != nil { return }
        knownActionRegistrations.insert(id)
        actions[name] = RegisteredAction(id: id, execute: action)
    }

    func unregisterAction(_ name: String, id: UUID) {
        if knownActionRegistrations.remove(id) != nil {
            if actions[name]?.id == id { actions[name] = nil }
        } else {
            cancelledActionRegistrations.insert(id)
        }
    }

    func executeAction(_ name: String, arguments: EngagePayload) async -> Bool {
        guard privacy.value == .optedIn, let action = actions[name] else { return false }
        return await action.execute(arguments)
    }

    func enqueue(type: String, payload: EngagePayload, operationId: String = UUID().uuidString.lowercased()) async throws {
        await awaitBindingIfProfileScoped(type)
        guard installationEnabled else { throw EngageRuntimeError.installationWiped }
        guard privacy.value == .optedIn || type == "PRIVACY_STATE_SET" else { return }
        let operation = SdkOperation(
            operationId: operationId,
            generation: session?.generation ?? 0,
            type: type,
            occurredAt: Self.timestamp(),
            payload: payload
        )
        try await persistence.enqueue(operation)
        outboxRevision.set(outboxRevision.value + 1)
        requestAutomaticRefresh(afterNanoseconds: 1_000_000_000)
    }

    func ensureInstallation(allowOptedOut: Bool = false) async throws -> InstallationSession {
        guard installationEnabled else { throw EngageRuntimeError.installationWiped }
        guard allowOptedOut || privacy.value == .optedIn else { throw EngageRuntimeError.optedOut }
        if let session { return session }
        let bundle = Bundle.main
        let remote = try await client.bootstrap(
            BootstrapRequest(
                locale: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
                timezone: TimeZone.current.identifier,
                sdkVersion: "0.1.0",
                appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                deviceModel: Self.deviceModel(),
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                recoveryToken: await persistence.recoveryToken()
            )
        )
        let created = allowOptedOut && privacy.value == .optedOut
            ? remote.withPrivacy(.optedOut)
            : remote
        try await saveSession(created)
        return created
    }

    func issueBindingCode() async throws -> String {
        let active = try await ensureInstallation()
        let response = try await client.bindingCode(credential: active.credential)
        startBindingPoll(generation: active.generation, expiresAt: response.expiresAt)
        return response.code
    }

    func flush() async throws {
        let active = try await ensureInstallation(allowOptedOut: privacy.value == .optedOut)
        while true {
            let allowed: Set<String>? = privacy.value == .optedOut ? ["PRIVACY_STATE_SET"] : nil
            let operations = await persistence.operations(allowedTypes: allowed)
            guard !operations.isEmpty else { return }
            let batchId = UUID().uuidString.lowercased()
            let response = try await client.operations(
                OperationBatchRequest(batchId: batchId, operations: operations),
                credential: active.credential
            )
            guard response.batchId == batchId else { throw EngageRuntimeError.invalidResponse }
            let expected = Set(operations.map(\.operationId))
            let returned = response.results.map(\.operationId)
            guard returned.count == Set(returned).count, Set(returned) == expected else {
                throw EngageRuntimeError.invalidResponse
            }
            try await persistence.settle(response.results)
            outboxRevision.set(outboxRevision.value + 1)
        }
    }

    func refresh() async throws {
        if let refreshTask {
            try await refreshTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.performRefresh()
        }
        refreshTask = task
        do {
            try await task.value
            refreshTask = nil
        } catch {
            refreshTask = nil
            throw error
        }
    }

    private func performRefresh() async throws {
        guard privacy.value == .optedIn else { return }
        let active = try await ensureInstallation()
        let remote = try await client.installation(credential: active.credential)
        let boundaryChanged = remote.generation != active.generation || remote.privacy != active.privacy
        if boundaryChanged {
            try await persistence.clearSync()
            syncSnapshot.set(.empty)
        }
        if boundaryChanged || remote.pushSubscription != active.pushSubscription || remote.updatedAt != active.serverTime {
            try await saveSession(
                InstallationSession(
                    installationId: active.installationId,
                    credential: active.credential,
                    revocationCredential: active.revocationCredential,
                    recoveryToken: active.recoveryToken,
                    generation: remote.generation,
                    privacy: remote.privacy,
                    pushSubscription: remote.pushSubscription,
                    serverTime: remote.updatedAt
                )
            )
        }
        try await flush()
        guard remote.privacy == .optedIn else {
            cancelFunctionalRefreshes()
            return
        }
        var requested: Set<SyncModule> = []
        if enabledFeatures.value.contains(.preferences) { requested.insert(.preferences) }
        if enabledFeatures.value.contains(.featureFlags) { requested.insert(.featureFlags) }
        modules.values.forEach { module in
            if !module.features.isDisjoint(with: enabledFeatures.value) { requested.formUnion(module.syncModules) }
        }
        guard !requested.isEmpty else {
            schedulePeriodicRefresh()
            return
        }
        let current = await persistence.snapshot()
        let response = try await client.sync(
            SyncRequest(cursor: current.generation == remote.generation ? current.cursor : nil, modules: requested),
            credential: active.credential
        )
        guard response.generation == remote.generation else { throw EngageRuntimeError.invalidResponse }
        try await persistence.applySync(response, modules: requested)
        syncSnapshot.set(await persistence.snapshot())
        schedulePeriodicRefresh()
    }

    func optOut() async throws {
        guard privacy.value != .optedOut else { return }
        let operation = SdkOperation(
            operationId: UUID().uuidString.lowercased(),
            generation: session?.generation ?? 0,
            type: "PRIVACY_STATE_SET",
            occurredAt: Self.timestamp(),
            payload: ["state": .string("OPTED_OUT")]
        )
        try await persistence.recordOptOut(operation)
        if let active = session { session = active.withPrivacy(.optedOut) }
        privacy.set(.optedOut)
        outboxRevision.set(outboxRevision.value + 1)
        cancelFunctionalRefreshes()
        startPrivacyFlush()
    }

    func optIn() async throws {
        guard privacy.value != .optedIn || !installationEnabled else { return }
        privacyFlushTask?.cancel()
        privacyFlushTask = nil
        if !installationEnabled {
            let registrations = EngageCore.moduleRegistrationsSnapshot
            registrations.forEach { modules[$0.id] = $0 }
            for module in modules.values { try await module.wipe() }
            try await persistence.wipeFunctionalState()
            session = nil
            installationId.set(nil)
            generation.set(0)
            syncSnapshot.set(.empty)
        }
        let operation = SdkOperation(
            operationId: UUID().uuidString.lowercased(),
            generation: session?.generation ?? 0,
            type: "PRIVACY_STATE_SET",
            occurredAt: Self.timestamp(),
            payload: ["state": .string("OPTED_IN")]
        )
        try await persistence.recordOptIn(operation)
        installationEnabled = true
        installationActive.set(true)
        if let active = session { session = active.withPrivacy(.optedIn) }
        privacy.set(.optedIn)
        outboxRevision.set(outboxRevision.value + 1)
        requestAutomaticRefresh()
        startRevocationReplay()
    }

    func optOutAndWipe() async throws {
        let revocation = session.map {
            RevocationEnvelope(operationId: UUID().uuidString.lowercased(), credential: $0.revocationCredential)
        }
        try await persistence.beginWipe(revocation: revocation)
        privacy.set(.optedOut)
        installationEnabled = false
        installationActive.set(false)
        privacyFlushTask?.cancel()
        privacyFlushTask = nil
        cancelFunctionalRefreshes()
        defer { startRevocationReplay() }
        let registrations = EngageCore.moduleRegistrationsSnapshot
        registrations.forEach { modules[$0.id] = $0 }
        var firstFailure: Error?
        for module in modules.values {
            do { try await module.wipe() }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        var coreWiped = false
        do {
            try await persistence.wipeFunctionalState()
            coreWiped = true
        } catch {
            if firstFailure == nil { firstFailure = error }
        }
        if coreWiped {
            self.session = nil
            installationId.set(nil); generation.set(0); syncSnapshot.set(.empty)
            outboxRevision.set(outboxRevision.value + 1)
            signals.emit(.localDataWiped)
        }
        if let firstFailure { throw firstFailure }
    }

    func authorizedRequest(
        method: String, path: String, query: [String: String], body: EngagePayload?
    ) async throws -> AuthorizedResponse {
        guard privacy.value == .optedIn else { throw EngageRuntimeError.optedOut }
        let active = try await ensureInstallation()
        return try await client.authorized(
            path: path, method: method, query: query, body: body, credential: active.credential
        )
    }

    func containsExposure(_ id: String) async -> Bool { await persistence.containsExposure(id) }
    func markExposure(_ id: String) async throws { try await persistence.markExposure(id) }

    func preferenceProjectionSource() async -> PreferenceProjectionSource {
        PreferenceProjectionSource(
            snapshot: syncSnapshot.value,
            pending: await persistence.operations(),
            generation: generation.value,
            privacy: privacy.value,
            enabledFeatures: enabledFeatures.value
        )
    }

    private func saveSession(_ value: InstallationSession) async throws {
        try await persistence.saveSession(value)
        session = value
        installationId.set(value.installationId); generation.set(value.generation); privacy.set(value.privacy)
    }

    private func requestAutomaticRefresh(afterNanoseconds delay: UInt64 = 0) {
        guard privacy.value == .optedIn, installationEnabled else { return }
        automaticRefreshPending = true
        guard automaticRefreshTask == nil else { return }
        automaticRefreshTask = Task { [weak self] in
            await self?.automaticRefreshLoop(initialDelay: delay)
        }
    }

    private func automaticRefreshLoop(initialDelay: UInt64) async {
        if initialDelay > 0 {
            try? await Task.sleep(nanoseconds: initialDelay)
        }
        var retryDelay: UInt64 = 1_000_000_000
        while !Task.isCancelled, privacy.value == .optedIn, installationEnabled {
            automaticRefreshPending = false
            do {
                try await refresh()
                retryDelay = 1_000_000_000
                if !automaticRefreshPending { break }
            } catch {
                do {
                    try await Task.sleep(nanoseconds: retryDelay)
                } catch {
                    break
                }
                retryDelay = min(retryDelay * 2, 900_000_000_000)
            }
        }
        automaticRefreshTask = nil
        if automaticRefreshPending, privacy.value == .optedIn, installationEnabled {
            requestAutomaticRefresh()
        }
    }

    private func schedulePeriodicRefresh() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
        guard foregroundActive, privacy.value == .optedIn, installationEnabled else { return }
        let seconds = min(max(syncSnapshot.value.refreshAfterSeconds, 30), 24 * 60 * 60)
        periodicRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            } catch {
                return
            }
            await self?.periodicRefreshFired()
        }
    }

    private func periodicRefreshFired() {
        periodicRefreshTask = nil
        guard foregroundActive, privacy.value == .optedIn else { return }
        requestAutomaticRefresh()
    }

    private func startBindingPoll(generation initialGeneration: Int64, expiresAt: String) {
        bindingPollTask?.cancel()
        let expiration = Self.parseTimestamp(expiresAt) ?? Date().addingTimeInterval(5 * 60)
        pendingBinding = PendingBinding(initialGeneration: initialGeneration, expiration: expiration)
        bindingPollTask = Task { [weak self] in
            await self?.pollBinding(initialGeneration: initialGeneration, expiration: expiration)
        }
    }

    private func pollBinding(initialGeneration: Int64, expiration: Date) async {
        while !Task.isCancelled,
              Date() < expiration,
              privacy.value == .optedIn,
              generation.value == initialGeneration {
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                try await refresh()
            } catch is CancellationError {
                break
            } catch {
                // The normal refresh scheduler handles backoff. Polling remains bounded by code expiry.
            }
        }
        if pendingBinding?.initialGeneration == initialGeneration { pendingBinding = nil }
        bindingPollTask = nil
    }

    private func awaitBindingIfProfileScoped(_ type: String) async {
        guard Self.profileScopedOperations.contains(type), let pending = pendingBinding else { return }
        while generation.value == pending.initialGeneration,
              Date() < pending.expiration,
              privacy.value == .optedIn,
              !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { break }
        }
        if generation.value != pending.initialGeneration || Date() >= pending.expiration {
            pendingBinding = nil
        }
    }

    private func startRevocationReplay() {
        guard revocationTask == nil else { return }
        revocationTask = Task { [weak self] in await self?.replayRevocation() }
    }

    private func startPrivacyFlush() {
        guard installationEnabled, privacy.value == .optedOut, privacyFlushTask == nil else { return }
        privacyFlushTask = Task { [weak self] in await self?.privacyFlushLoop() }
    }

    private func privacyFlushLoop() async {
        var delay: UInt64 = 1_000_000_000
        while !Task.isCancelled, installationEnabled, privacy.value == .optedOut {
            let operations = await persistence.operations(allowedTypes: ["PRIVACY_STATE_SET"])
            guard !operations.isEmpty else { break }
            do {
                try await flush()
                delay = 1_000_000_000
            } catch {
                do { try await Task.sleep(nanoseconds: delay) } catch { break }
                delay = min(delay * 2, 900_000_000_000)
            }
        }
        privacyFlushTask = nil
    }

    private func cancelFunctionalRefreshes() {
        automaticRefreshPending = false
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
        bindingPollTask?.cancel()
        bindingPollTask = nil
    }

    private func replayRevocation() async {
        var delay: UInt64 = 1_000_000_000
        while let envelope = await persistence.pendingRevocation() {
            do {
                try await client.revoke(envelope)
                try await persistence.clearRevocation(operationId: envelope.operationId)
                delay = 1_000_000_000
            } catch {
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 900_000_000_000)
            }
        }
        revocationTask = nil
    }

    private func handleForeground() {
        foregroundActive = true
        foreground.set(true)
        guard privacy.value == .optedIn else { return }
        signals.emit(.appOpened)
        requestAutomaticRefresh()
        schedulePeriodicRefresh()
    }
    private func handleBackground() {
        foregroundActive = false
        foreground.set(false)
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
        guard privacy.value == .optedIn else { return }
        signals.emit(.appBackgrounded)
    }

    private func networkBecameAvailable() {
        signals.emit(.networkAvailable)
        if privacy.value == .optedIn { requestAutomaticRefresh() }
        else { startPrivacyFlush() }
    }

    static func timestamp(_ date: Date = Date()) -> String { ISO8601DateFormatter().string(from: date) }
    static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private struct PendingBinding {
        let initialGeneration: Int64
        let expiration: Date
    }

    private static let profileScopedOperations: Set<String> = [
        "PROFILE_ATTRIBUTES_EDITED",
        "PROFILE_TAGS_EDITED",
        "PROFILE_SUBSCRIPTIONS_EDITED",
    ]
    static func keyPattern(_ value: String) -> Bool {
        value.range(of: "^[a-z][a-z0-9_.-]{0,127}$", options: .regularExpression) != nil
    }
    static func deviceModel() -> String? {
        #if canImport(UIKit)
        UIDevice.current.model
        #else
        nil
        #endif
    }
}

enum EngageRuntimeError: Error { case installationWiped, optedOut, invalidResponse }

private extension InstallationSession {
    func withPrivacy(_ privacy: PrivacyState) -> InstallationSession {
        InstallationSession(
            installationId: installationId,
            credential: credential,
            revocationCredential: revocationCredential,
            recoveryToken: recoveryToken,
            generation: generation,
            privacy: privacy,
            pushSubscription: pushSubscription,
            serverTime: serverTime
        )
    }
}

#if canImport(Network)
private final class EngageNetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.engage.sdk.network")
    private let onAvailable: @Sendable () -> Void
    private var wasSatisfied = false

    init(onAvailable: @escaping @Sendable () -> Void) { self.onAvailable = onAvailable }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            if satisfied, !self.wasSatisfied { self.onAvailable() }
            self.wasSatisfied = satisfied
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
#endif

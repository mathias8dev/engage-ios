import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
        EngageLogger.debug("Core.Module", "registration forwarded id=\(registration.id)")
        EngageCore.registerModule(registration, runtime: runtime)
    }

    /// Returns an app-configuration-scoped directory for durable optional-module state.
    public func storageDirectory(module: String) -> URL {
        precondition(
            module.range(of: "^[a-z][a-z0-9-]{0,63}$", options: .regularExpression) != nil,
            "Engage module storage names must be lowercase product keys"
        )
        let directory = runtime.storageDirectory
            .appendingPathComponent(module, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public func documents(_ module: SyncModule) -> EngageState<[RemoteDocument]> {
        EngageLogger.debug("Core.Module", "documents observed module=\(module)")
        let state = EngageState<[RemoteDocument]>([])
        let snapshots = runtime.syncSnapshot
        Task {
            for await snapshot in snapshots.updates {
                let compatible = snapshot.generation == self.generation.value
                let documents = compatible ? snapshot.documents.filter { $0.module == module } : []
                EngageLogger.verbose(
                    "Core.Module",
                    "documents emitted module=\(module) compatible=\(compatible) count=\(documents.count)"
                )
                state.set(documents)
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
            EngageLogger.debug(
                "Core.Module",
                "operation enqueue requested operationId=\(operationId) type=\(type) payloadKeys=\(payload.keys.sorted())"
            )
            try await runtime.enqueue(type: type, payload: payload, operationId: operationId)
            EngageLogger.debug("Core.Module", "operation accepted operationId=\(operationId) type=\(type)")
            return true
        } catch {
            EngageLogger.error("Core.Module", "operation rejected operationId=\(operationId) type=\(type)", error: error)
            return false
        }
    }

    public func refresh() async {
        EngageLogger.debug("Core.Module", "refresh requested")
        do { try await runtime.refresh() }
        catch { EngageLogger.error("Core.Module", "refresh failed", error: error) }
    }

    public func authorizedRequest(
        method: String,
        path: String,
        query: [String: String] = [:],
        body: EngagePayload? = nil
    ) async throws -> AuthorizedResponse {
        EngageLogger.debug(
            "Core.Module",
            "authorized request method=\(method) path=\(path) queryKeys=\(query.keys.sorted()) bodyKeys=\(body?.keys.sorted() ?? [])"
        )
        return try await runtime.authorizedRequest(method: method, path: path, query: query, body: body)
    }

    public func executeAction(_ name: String, arguments: EngagePayload) async -> Bool {
        EngageLogger.debug("Core.Module", "action requested name=\(name) argumentKeys=\(arguments.keys.sorted())")
        return await runtime.executeAction(name, arguments: arguments)
    }
}

actor CoreRuntime {
    nonisolated let config: EngageConfig
    nonisolated let storageDirectory: URL
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

    init(
        config: EngageConfig,
        directory: URL,
        urlSession: URLSession = .shared,
        secureStorageBackend: SecureStorageBackend = .platform
    ) {
        self.config = config
        storageDirectory = directory
        let storage = CorePersistence(
            directory: directory,
            secureStorageBackend: secureStorageBackend
        )
        let initial = storage.initialState
        persistence = storage
        client = MobileEdgeClient(endpoint: config.endpoint, appKey: config.appKey, session: urlSession)
        session = initial.session
        disabledFeatures = initial.disabledFeatures
        installationEnabled = initial.installationEnabled
        installationId = EngageState(initial.session?.installationId)
        generation = EngageState(initial.session?.generation ?? 0)
        privacy = EngageState(initial.privacy)
        installationActive = EngageState(initial.installationEnabled)
        enabledFeatures = EngageState(availableFeatures.subtracting(initial.disabledFeatures))
        syncSnapshot = EngageState(initial.sync)
        EngageLogger.info(
            "Core.Runtime",
            "initialized installationId=\(initial.session?.installationId ?? "none") " +
                "generation=\(initial.session?.generation ?? 0) privacy=\(initial.privacy) " +
                "installationActive=\(initial.installationEnabled)"
        )
    }

    func start() async {
        EngageLogger.info("Core.Runtime", "runtime starting")
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
        EngageLogger.info("Core.Lifecycle", "initial foreground=\(foregroundActive)")
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
        EngageLogger.info("Core.Runtime", "runtime started")
    }

    func register(_ registration: EngageModuleRegistration) {
        guard modules[registration.id] == nil else {
            EngageLogger.debug("Core.Module", "registration ignored id=\(registration.id) reason=duplicate")
            return
        }
        EngageLogger.info(
            "Core.Module",
            "registering id=\(registration.id) features=\(registration.features) syncModules=\(registration.syncModules)"
        )
        modules[registration.id] = registration
        availableFeatures.formUnion(registration.features)
        enabledFeatures.set(availableFeatures.subtracting(disabledFeatures))
        if !installationEnabled {
            EngageLogger.warning("Core.Module", "wiping newly registered module id=\(registration.id) reason=installation_wiped")
            Task {
                do { try await registration.wipe() }
                catch {
                    EngageLogger.error(
                        "Core.Module",
                        "registered module wipe failed id=\(registration.id)",
                        error: error
                    )
                }
            }
        }
        requestAutomaticRefresh()
    }

    func editFeatures(_ enabled: Set<SdkFeature>) async throws {
        EngageLogger.info("Core.Features", "edit requested enabled=\(enabled)")
        let requested = enabled.intersection(availableFeatures)
        let candidate = disabledFeatures
            .subtracting(availableFeatures)
            .union(availableFeatures.subtracting(requested))
        try await persistence.setDisabledFeatures(candidate)
        disabledFeatures = candidate
        enabledFeatures.set(availableFeatures.subtracting(disabledFeatures))
        EngageLogger.info("Core.Features", "edit applied enabled=\(enabledFeatures.value)")
        requestAutomaticRefresh()
    }

    func registerAction(
        _ name: String,
        id: UUID,
        action: @escaping @Sendable (EngagePayload) async -> Bool
    ) {
        precondition(Self.keyPattern(name), "Action keys must use lowercase product keys")
        if cancelledActionRegistrations.remove(id) != nil {
            EngageLogger.debug("Core.Actions", "registration ignored name=\(name) id=\(id) reason=pre_cancelled")
            return
        }
        knownActionRegistrations.insert(id)
        actions[name] = RegisteredAction(id: id, execute: action)
        EngageLogger.info("Core.Actions", "registered name=\(name) id=\(id)")
    }

    func unregisterAction(_ name: String, id: UUID) {
        if knownActionRegistrations.remove(id) != nil {
            if actions[name]?.id == id { actions[name] = nil }
            EngageLogger.info("Core.Actions", "unregistered name=\(name) id=\(id)")
        } else {
            cancelledActionRegistrations.insert(id)
            EngageLogger.debug("Core.Actions", "pre-cancelled name=\(name) id=\(id)")
        }
    }

    func executeAction(_ name: String, arguments: EngagePayload) async -> Bool {
        guard privacy.value == .optedIn else {
            EngageLogger.debug("Core.Actions", "execution rejected name=\(name) reason=privacy")
            return false
        }
        guard let action = actions[name] else {
            EngageLogger.debug("Core.Actions", "execution rejected name=\(name) reason=no_handler")
            return false
        }
        EngageLogger.info("Core.Actions", "executing name=\(name) argumentKeys=\(arguments.keys.sorted())")
        let completed = await action.execute(arguments)
        EngageLogger.info("Core.Actions", "executed name=\(name) completed=\(completed)")
        return completed
    }

    func enqueue(type: String, payload: EngagePayload, operationId: String = UUID().uuidString.lowercased()) async throws {
        EngageLogger.debug(
            "Core.Outbox",
            "enqueue started operationId=\(operationId) type=\(type) generation=\(session?.generation ?? 0) " +
                "payloadKeys=\(payload.keys.sorted())"
        )
        await awaitBindingIfProfileScoped(type)
        guard installationEnabled else {
            EngageLogger.warning("Core.Outbox", "enqueue rejected operationId=\(operationId) reason=installation_wiped")
            throw EngageRuntimeError.installationWiped
        }
        guard privacy.value == .optedIn || type == "PRIVACY_STATE_SET" else {
            EngageLogger.debug("Core.Outbox", "enqueue ignored operationId=\(operationId) reason=opted_out")
            return
        }
        let operation = SdkOperation(
            operationId: operationId,
            generation: session?.generation ?? 0,
            type: type,
            occurredAt: Self.timestamp(),
            payload: payload
        )
        try await persistence.enqueue(operation)
        outboxRevision.set(outboxRevision.value + 1)
        EngageLogger.info("Core.Outbox", "enqueued operationId=\(operationId) type=\(type)")
        requestAutomaticRefresh(afterNanoseconds: 1_000_000_000)
    }

    func ensureInstallation(allowOptedOut: Bool = false) async throws -> InstallationSession {
        guard installationEnabled else { throw EngageRuntimeError.installationWiped }
        guard allowOptedOut || privacy.value == .optedIn else { throw EngageRuntimeError.optedOut }
        if let session {
            EngageLogger.verbose(
                "Core.Installation",
                "using existing installationId=\(session.installationId) generation=\(session.generation)"
            )
            return session
        }
        EngageLogger.info("Core.Installation", "bootstrap started allowOptedOut=\(allowOptedOut)")
        let bundle = Bundle.main
        let remote = try await client.bootstrap(
            BootstrapRequest(
                locale: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
                timezone: TimeZone.current.identifier,
                sdkVersion: EngageSDKInfo.version,
                appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                deviceModel: await Self.deviceModel(),
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                recoveryToken: await persistence.recoveryToken()
            )
        )
        let created = allowOptedOut && privacy.value == .optedOut
            ? remote.withPrivacy(.optedOut)
            : remote
        try await saveSession(created)
        EngageLogger.info(
            "Core.Installation",
            "bootstrap completed installationId=\(created.installationId) generation=\(created.generation)"
        )
        return created
    }

    func issueBindingCode() async throws -> String {
        EngageLogger.info("Core.Binding", "binding code requested")
        let active = try await ensureInstallation()
        let response = try await client.bindingCode(credential: active.credential)
        startBindingPoll(generation: active.generation, expiresAt: response.expiresAt)
        EngageLogger.info("Core.Binding", "binding code issued generation=\(active.generation) length=\(response.code.count)")
        return response.code
    }

    func flush() async throws {
        EngageLogger.debug("Core.Outbox", "flush started privacy=\(privacy.value)")
        let active = try await ensureInstallation(allowOptedOut: privacy.value == .optedOut)
        while true {
            let allowed: Set<String>? = privacy.value == .optedOut ? ["PRIVACY_STATE_SET"] : nil
            let operations = await persistence.operations(allowedTypes: allowed)
            guard !operations.isEmpty else {
                EngageLogger.debug("Core.Outbox", "flush completed reason=empty")
                return
            }
            let batchId = UUID().uuidString.lowercased()
            EngageLogger.info("Core.Outbox", "batch sending batchId=\(batchId) count=\(operations.count)")
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
            EngageLogger.info("Core.Outbox", "batch settled batchId=\(batchId) results=\(response.results.count)")
        }
    }

    func refresh() async throws {
        if let refreshTask {
            EngageLogger.debug("Core.Sync", "refresh coalesced")
            try await refreshTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.performRefresh()
        }
        refreshTask = task
        EngageLogger.debug("Core.Sync", "refresh task created")
        do {
            try await task.value
            refreshTask = nil
            EngageLogger.info("Core.Sync", "refresh completed")
        } catch {
            refreshTask = nil
            EngageLogger.error("Core.Sync", "refresh failed", error: error)
            throw error
        }
    }

    private func performRefresh() async throws {
        guard privacy.value == .optedIn else {
            EngageLogger.debug("Core.Sync", "refresh skipped reason=privacy")
            return
        }
        EngageLogger.debug("Core.Sync", "remote reconciliation started")
        let active = try await ensureInstallation()
        let remote = try await client.installation(credential: active.credential)
        let boundaryChanged = remote.generation != active.generation || remote.privacy != active.privacy
        EngageLogger.debug(
            "Core.Sync",
            "installation received installationId=\(active.installationId) remoteGeneration=\(remote.generation) " +
                "boundaryChanged=\(boundaryChanged) privacy=\(remote.privacy)"
        )
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
            EngageLogger.info("Core.Sync", "functional sync stopped reason=remote_opted_out")
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
            EngageLogger.debug("Core.Sync", "document sync skipped reason=no_modules")
            schedulePeriodicRefresh()
            return
        }
        let current = await persistence.snapshot()
        EngageLogger.info("Core.Sync", "document sync sending modules=\(requested) hasCursor=\(current.cursor != nil)")
        let response = try await client.sync(
            SyncRequest(cursor: current.generation == remote.generation ? current.cursor : nil, modules: requested),
            credential: active.credential
        )
        guard response.generation == remote.generation else { throw EngageRuntimeError.invalidResponse }
        try await persistence.applySync(response, modules: requested)
        syncSnapshot.set(await persistence.snapshot())
        EngageLogger.info(
            "Core.Sync",
            "document sync applied revision=\(response.revision) documents=\(response.documents.count)"
        )
        schedulePeriodicRefresh()
    }

    func optOut() async throws {
        guard privacy.value != .optedOut else {
            EngageLogger.debug("Core.Privacy", "opt-out ignored reason=already_opted_out")
            return
        }
        EngageLogger.warning("Core.Privacy", "opt-out started")
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
        EngageLogger.warning("Core.Privacy", "opt-out persisted operationId=\(operation.operationId)")
    }

    func optIn() async throws {
        guard privacy.value != .optedIn || !installationEnabled else {
            EngageLogger.debug("Core.Privacy", "opt-in ignored reason=already_opted_in")
            return
        }
        EngageLogger.info("Core.Privacy", "opt-in started installationActive=\(installationEnabled)")
        privacyFlushTask?.cancel()
        privacyFlushTask = nil
        if !installationEnabled {
            let registrations = EngageCore.moduleRegistrationsSnapshot
            registrations.forEach { modules[$0.id] = $0 }
            for module in modules.values { try await module.wipe() }
            EngageLogger.warning("Core.Privacy", "module state reset before opt-in modules=\(modules.count)")
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
        EngageLogger.info("Core.Privacy", "opt-in persisted operationId=\(operation.operationId)")
    }

    func optOutAndWipe() async throws {
        EngageLogger.warning("Core.Privacy", "opt-out-and-wipe started installationId=\(session?.installationId ?? "none")")
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
            do {
                EngageLogger.debug("Core.Privacy", "module wipe started id=\(module.id)")
                try await module.wipe()
                EngageLogger.debug("Core.Privacy", "module wipe completed id=\(module.id)")
            } catch {
                EngageLogger.error("Core.Privacy", "module wipe failed id=\(module.id)", error: error)
                if firstFailure == nil { firstFailure = error }
            }
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
            EngageLogger.warning("Core.Privacy", "functional state wiped")
        }
        if let firstFailure { throw firstFailure }
        EngageLogger.warning("Core.Privacy", "opt-out-and-wipe completed")
    }

    func authorizedRequest(
        method: String, path: String, query: [String: String], body: EngagePayload?
    ) async throws -> AuthorizedResponse {
        guard privacy.value == .optedIn else {
            EngageLogger.debug("Core.Network", "authorized request rejected method=\(method) path=\(path) reason=privacy")
            throw EngageRuntimeError.optedOut
        }
        let active = try await ensureInstallation()
        EngageLogger.debug(
            "Core.Network",
            "authorized request forwarding method=\(method) path=\(path) queryKeys=\(query.keys.sorted())"
        )
        return try await client.authorized(
            path: path, method: method, query: query, body: body, credential: active.credential
        )
    }

    func containsExposure(_ id: String) async -> Bool {
        let contains = await persistence.containsExposure(id)
        EngageLogger.verbose("Core.Flags", "exposure lookup operationId=\(id) found=\(contains)")
        return contains
    }
    func markExposure(_ id: String) async throws {
        EngageLogger.debug("Core.Flags", "exposure persisting operationId=\(id)")
        try await persistence.markExposure(id)
    }

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
        EngageLogger.debug(
            "Core.Installation",
            "session saving installationId=\(value.installationId) generation=\(value.generation) privacy=\(value.privacy)"
        )
        try await persistence.saveSession(value)
        session = value
        installationId.set(value.installationId); generation.set(value.generation); privacy.set(value.privacy)
        EngageLogger.info(
            "Core.Installation",
            "session active installationId=\(value.installationId) generation=\(value.generation) privacy=\(value.privacy)"
        )
    }

    private func requestAutomaticRefresh(afterNanoseconds delay: UInt64 = 0) {
        guard privacy.value == .optedIn, installationEnabled else {
            EngageLogger.verbose(
                "Core.Sync",
                "automatic refresh ignored privacy=\(privacy.value) installationActive=\(installationEnabled)"
            )
            return
        }
        automaticRefreshPending = true
        guard automaticRefreshTask == nil else {
            EngageLogger.verbose("Core.Sync", "automatic refresh marked pending")
            return
        }
        EngageLogger.debug("Core.Sync", "automatic refresh scheduled delayNanoseconds=\(delay)")
        automaticRefreshTask = Task { [weak self] in
            await self?.automaticRefreshLoop(initialDelay: delay)
        }
    }

    private func automaticRefreshLoop(initialDelay: UInt64) async {
        if initialDelay > 0 {
            try? await Task.sleep(nanoseconds: initialDelay)
        }
        var retryDelay: UInt64 = 1_000_000_000
        EngageLogger.debug("Core.Sync", "automatic refresh loop started")
        while !Task.isCancelled, privacy.value == .optedIn, installationEnabled {
            automaticRefreshPending = false
            do {
                try await refresh()
                retryDelay = 1_000_000_000
                if !automaticRefreshPending { break }
            } catch {
                EngageLogger.warning(
                    "Core.Sync",
                    "automatic refresh retry scheduled delayNanoseconds=\(retryDelay)",
                    error: error
                )
                do {
                    try await Task.sleep(nanoseconds: retryDelay)
                } catch {
                    break
                }
                retryDelay = min(retryDelay * 2, 900_000_000_000)
            }
        }
        automaticRefreshTask = nil
        EngageLogger.debug("Core.Sync", "automatic refresh loop stopped pending=\(automaticRefreshPending)")
        if automaticRefreshPending, privacy.value == .optedIn, installationEnabled {
            requestAutomaticRefresh()
        }
    }

    private func schedulePeriodicRefresh() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
        guard foregroundActive, privacy.value == .optedIn, installationEnabled else {
            EngageLogger.verbose(
                "Core.Sync",
                "periodic refresh not scheduled foreground=\(foregroundActive) privacy=\(privacy.value) " +
                    "installationActive=\(installationEnabled)"
            )
            return
        }
        let seconds = min(max(syncSnapshot.value.refreshAfterSeconds, 30), 24 * 60 * 60)
        EngageLogger.debug("Core.Sync", "periodic refresh scheduled seconds=\(seconds)")
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
        guard foregroundActive, privacy.value == .optedIn else {
            EngageLogger.debug("Core.Sync", "periodic refresh ignored after timer")
            return
        }
        EngageLogger.debug("Core.Sync", "periodic refresh timer fired")
        requestAutomaticRefresh()
    }

    private func startBindingPoll(generation initialGeneration: Int64, expiresAt: String) {
        bindingPollTask?.cancel()
        let expiration = Self.parseTimestamp(expiresAt) ?? Date().addingTimeInterval(5 * 60)
        pendingBinding = PendingBinding(initialGeneration: initialGeneration, expiration: expiration)
        EngageLogger.debug(
            "Core.Binding",
            "poll scheduled generation=\(initialGeneration) expirationParsed=\(Self.parseTimestamp(expiresAt) != nil)"
        )
        bindingPollTask = Task { [weak self] in
            await self?.pollBinding(initialGeneration: initialGeneration, expiration: expiration)
        }
    }

    private func pollBinding(initialGeneration: Int64, expiration: Date) async {
        EngageLogger.debug("Core.Binding", "poll started generation=\(initialGeneration)")
        while !Task.isCancelled,
              Date() < expiration,
              privacy.value == .optedIn,
              generation.value == initialGeneration {
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                try await refresh()
            } catch is CancellationError {
                EngageLogger.debug("Core.Binding", "poll cancelled generation=\(initialGeneration)")
                break
            } catch {
                EngageLogger.warning("Core.Binding", "poll refresh failed generation=\(initialGeneration)", error: error)
                // The normal refresh scheduler handles backoff. Polling remains bounded by code expiry.
            }
        }
        if pendingBinding?.initialGeneration == initialGeneration { pendingBinding = nil }
        bindingPollTask = nil
        EngageLogger.info(
            "Core.Binding",
            "poll stopped initialGeneration=\(initialGeneration) currentGeneration=\(generation.value)"
        )
    }

    private func awaitBindingIfProfileScoped(_ type: String) async {
        guard Self.profileScopedOperations.contains(type), let pending = pendingBinding else { return }
        EngageLogger.debug("Core.Binding", "profile operation waiting type=\(type) generation=\(pending.initialGeneration)")
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
        EngageLogger.debug(
            "Core.Binding",
            "profile operation released type=\(type) currentGeneration=\(generation.value)"
        )
    }

    private func startRevocationReplay() {
        guard revocationTask == nil else {
            EngageLogger.verbose("Core.Privacy", "revocation replay already running")
            return
        }
        EngageLogger.debug("Core.Privacy", "revocation replay scheduled")
        revocationTask = Task { [weak self] in await self?.replayRevocation() }
    }

    private func startPrivacyFlush() {
        guard installationEnabled, privacy.value == .optedOut, privacyFlushTask == nil else {
            EngageLogger.verbose(
                "Core.Privacy",
                "privacy flush not started installationActive=\(installationEnabled) privacy=\(privacy.value) " +
                    "running=\(privacyFlushTask != nil)"
            )
            return
        }
        EngageLogger.debug("Core.Privacy", "privacy flush scheduled")
        privacyFlushTask = Task { [weak self] in await self?.privacyFlushLoop() }
    }

    private func privacyFlushLoop() async {
        var delay: UInt64 = 1_000_000_000
        EngageLogger.debug("Core.Privacy", "privacy flush loop started")
        while !Task.isCancelled, installationEnabled, privacy.value == .optedOut {
            let operations = await persistence.operations(allowedTypes: ["PRIVACY_STATE_SET"])
            guard !operations.isEmpty else { break }
            do {
                try await flush()
                delay = 1_000_000_000
            } catch {
                EngageLogger.warning(
                    "Core.Privacy",
                    "privacy flush retry scheduled delayNanoseconds=\(delay)",
                    error: error
                )
                do { try await Task.sleep(nanoseconds: delay) } catch { break }
                delay = min(delay * 2, 900_000_000_000)
            }
        }
        privacyFlushTask = nil
        EngageLogger.debug("Core.Privacy", "privacy flush loop stopped")
    }

    private func cancelFunctionalRefreshes() {
        EngageLogger.debug("Core.Sync", "functional refreshes cancelling")
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
        EngageLogger.debug("Core.Privacy", "revocation replay started")
        while let envelope = await persistence.pendingRevocation() {
            do {
                EngageLogger.info("Core.Privacy", "revocation sending operationId=\(envelope.operationId)")
                try await client.revoke(envelope)
                try await persistence.clearRevocation(operationId: envelope.operationId)
                EngageLogger.info("Core.Privacy", "revocation confirmed operationId=\(envelope.operationId)")
                delay = 1_000_000_000
            } catch {
                EngageLogger.warning(
                    "Core.Privacy",
                    "revocation retry operationId=\(envelope.operationId) delayNanoseconds=\(delay)",
                    error: error
                )
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 900_000_000_000)
            }
        }
        revocationTask = nil
        EngageLogger.debug("Core.Privacy", "revocation replay stopped")
    }

    private func handleForeground() {
        EngageLogger.info("Core.Lifecycle", "application entered foreground")
        foregroundActive = true
        foreground.set(true)
        guard privacy.value == .optedIn else { return }
        signals.emit(.appOpened)
        requestAutomaticRefresh()
        schedulePeriodicRefresh()
    }
    private func handleBackground() {
        EngageLogger.info("Core.Lifecycle", "application entered background")
        foregroundActive = false
        foreground.set(false)
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
        guard privacy.value == .optedIn else { return }
        signals.emit(.appBackgrounded)
    }

    private func networkBecameAvailable() {
        EngageLogger.info("Core.Network", "network became available")
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
    @MainActor static func deviceModel() -> String? {
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

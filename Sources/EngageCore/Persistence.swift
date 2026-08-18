import Foundation
#if canImport(Security)
import Security
#endif

private struct PersistedSession: Codable, Sendable {
    let installationId: String
    let generation: Int64
    let privacy: PrivacyState
    let pushSubscription: String
    let serverTime: String

    init(_ session: InstallationSession) {
        installationId = session.installationId
        generation = session.generation
        privacy = session.privacy
        pushSubscription = session.pushSubscription
        serverTime = session.serverTime
    }

    func materialize(with secrets: SessionSecrets) -> InstallationSession? {
        guard secrets.installationId == installationId else { return nil }
        return InstallationSession(
            installationId: installationId,
            credential: secrets.credential,
            revocationCredential: secrets.revocationCredential,
            recoveryToken: secrets.recoveryToken,
            generation: generation,
            privacy: privacy,
            pushSubscription: pushSubscription,
            serverTime: serverTime
        )
    }

    func withPrivacy(_ privacy: PrivacyState) -> PersistedSession {
        PersistedSession(
            installationId: installationId,
            generation: generation,
            privacy: privacy,
            pushSubscription: pushSubscription,
            serverTime: serverTime
        )
    }

    private init(
        installationId: String,
        generation: Int64,
        privacy: PrivacyState,
        pushSubscription: String,
        serverTime: String
    ) {
        self.installationId = installationId
        self.generation = generation
        self.privacy = privacy
        self.pushSubscription = pushSubscription
        self.serverTime = serverTime
    }
}

private struct SessionSecrets: Codable, Sendable {
    let installationId: String
    let credential: String
    let revocationCredential: String
    let recoveryToken: String

    init(_ session: InstallationSession) {
        installationId = session.installationId
        credential = session.credential
        revocationCredential = session.revocationCredential
        recoveryToken = session.recoveryToken
    }
}

/// Minimal privacy record that survives deletion of every functional store.
private struct PrivacyControl: Codable, Sendable {
    var suspendedAfterWipe: Bool
    var revocations: [RevocationEnvelope]

    private enum CodingKeys: String, CodingKey {
        case suspendedAfterWipe, revocations, revocation
    }

    init(suspendedAfterWipe: Bool, revocations: [RevocationEnvelope]) {
        self.suspendedAfterWipe = suspendedAfterWipe
        self.revocations = revocations
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        suspendedAfterWipe = try values.decode(Bool.self, forKey: .suspendedAfterWipe)
        revocations = try values.decodeIfPresent([RevocationEnvelope].self, forKey: .revocations)
            ?? values.decodeIfPresent(RevocationEnvelope.self, forKey: .revocation).map { [$0] }
            ?? []
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(suspendedAfterWipe, forKey: .suspendedAfterWipe)
        try values.encode(revocations, forKey: .revocations)
    }
}

private struct PersistedState: Codable {
    var session: PersistedSession?
    var privacy: PrivacyState = .optedIn
    var outbox: [SdkOperation] = []
    var sync: SyncSnapshot = .empty
    var exposedOperationIds: Set<String> = []
    var disabledFeatures: Set<SdkFeature> = []
    var wiped = false
}

/// Shape used before credentials were migrated to Keychain.
private struct LegacyPersistedState: Codable {
    var session: InstallationSession?
    var privacy: PrivacyState = .optedIn
    var outbox: [SdkOperation] = []
    var sync: SyncSnapshot = .empty
    var exposedOperationIds: Set<String> = []
    var disabledFeatures: Set<SdkFeature> = []
}

struct CoreInitialState: Sendable {
    let session: InstallationSession?
    let privacy: PrivacyState
    let sync: SyncSnapshot
    let disabledFeatures: Set<SdkFeature>
    let installationEnabled: Bool
}

actor CorePersistence {
    nonisolated let initialState: CoreInitialState

    private let stateURL: URL
    private let legacyRevocationURL: URL
    private let secureStore: SecureBlobStore
    private var state: PersistedState
    private var sessionSecrets: SessionSecrets?
    private var privacyControl: PrivacyControl?

    init(directory: URL, secureStorageBackend: SecureStorageBackend = .platform) {
        EngageLogger.debug("Core.Storage", "persistence loading directory=\(directory.lastPathComponent)")
        stateURL = directory.appendingPathComponent("core-state.json")
        legacyRevocationURL = directory.appendingPathComponent("privacy-revocation.json")
        secureStore = SecureBlobStore(
            directory: directory,
            service: "io.engage.sdk.credentials.\(directory.lastPathComponent)",
            legacyService: legacyKeychainService(for: directory),
            backend: secureStorageBackend
        )

        let decoder = JSONDecoder()
        let existingData = try? Data(contentsOf: stateURL)
        let legacy = existingData.flatMap { try? decoder.decode(LegacyPersistedState.self, from: $0) }
        let decoded = existingData.flatMap { try? decoder.decode(PersistedState.self, from: $0) }
        var mayRewriteFunctionalState = decoded != nil || existingData == nil

        var loadedState = decoded ?? PersistedState(
            session: legacy?.session.map(PersistedSession.init),
            privacy: legacy?.privacy ?? .optedIn,
            outbox: legacy?.outbox ?? [],
            sync: legacy?.sync ?? .empty,
            exposedOperationIds: legacy?.exposedOperationIds ?? [],
            disabledFeatures: legacy?.disabledFeatures ?? [],
            wiped: false
        )

        var loadedSecrets = secureStore.read(SessionSecrets.self, account: .session)
        if loadedSecrets == nil, let oldSession = legacy?.session {
            let candidate = SessionSecrets(oldSession)
            loadedSecrets = candidate
            do {
                try secureStore.write(candidate, account: .session)
                mayRewriteFunctionalState = true
            } catch {
                // Preserve the legacy state until Keychain accepts the migration.
                mayRewriteFunctionalState = false
            }
        }

        var loadedControl = secureStore.read(PrivacyControl.self, account: .privacyControl)
        let legacySecureRevocation = secureStore.read(RevocationEnvelope.self, account: .revocation)
        var loadedRevocation = loadedControl?.revocations.first ?? legacySecureRevocation
        var migratedLegacyRevocation = false
        if loadedControl == nil, let loadedRevocation {
            loadedControl = PrivacyControl(suspendedAfterWipe: true, revocations: [loadedRevocation])
            if (try? secureStore.write(loadedControl, account: .privacyControl)) != nil {
                migratedLegacyRevocation = true
                try? secureStore.delete(account: .revocation)
            }
        } else if loadedRevocation == nil,
           let data = try? Data(contentsOf: legacyRevocationURL),
           let legacyEnvelope = try? decoder.decode(RevocationEnvelope.self, from: data) {
            loadedRevocation = legacyEnvelope
            loadedControl = PrivacyControl(suspendedAfterWipe: true, revocations: [legacyEnvelope])
            if (try? secureStore.write(loadedControl, account: .privacyControl)) != nil {
                migratedLegacyRevocation = true
            }
        }

        if loadedControl == nil, loadedState.wiped {
            loadedControl = PrivacyControl(
                suspendedAfterWipe: true,
                revocations: loadedRevocation.map { [$0] } ?? []
            )
            try? secureStore.write(loadedControl, account: .privacyControl)
        }

        if loadedControl?.suspendedAfterWipe == true {
            // Complete a wipe interrupted after its durable privacy boundary was written.
            loadedState.session = nil
            loadedState.outbox = []
            loadedState.sync = .empty
            loadedState.exposedOperationIds = []
            loadedState.privacy = .optedOut
            loadedState.wiped = true
            loadedSecrets = nil
            try? secureStore.delete(account: .session)
        }

        let materialized = loadedState.session.flatMap { metadata in
            loadedSecrets.flatMap(metadata.materialize)
        }
        if loadedState.session != nil, materialized == nil {
            // Metadata without matching credentials cannot authorize requests and must never be reused.
            loadedState.session = nil
            loadedState.sync = .empty
            loadedState.outbox = loadedState.outbox.filter { $0.type == "PRIVACY_STATE_SET" }
        }

        state = loadedState
        sessionSecrets = loadedSecrets
        privacyControl = loadedControl
        initialState = CoreInitialState(
            session: loadedControl?.suspendedAfterWipe == true ? nil : materialized,
            privacy: loadedControl?.suspendedAfterWipe == true ? .optedOut : loadedState.privacy,
            sync: loadedState.sync,
            disabledFeatures: loadedState.disabledFeatures,
            installationEnabled: !loadedState.wiped && loadedControl?.suspendedAfterWipe != true
        )
        EngageLogger.info(
            "Core.Storage",
            "persistence loaded installationId=\(materialized?.installationId ?? "none") " +
                "generation=\(materialized?.generation ?? 0) privacy=\(initialState.privacy) " +
                "outbox=\(loadedState.outbox.count) documents=\(loadedState.sync.documents.count) " +
                "pendingRevocations=\(loadedControl?.revocations.count ?? 0)"
        )

        // Rewrites migrated state without credentials. Keep the legacy file privacy-compatible
        // for a downgrade, but remove any credentials that older SDK versions stored in plaintext.
        if mayRewriteFunctionalState {
            do {
                try Self.persist(loadedState, to: stateURL)
                if let legacyStateURL = legacyCoreStateURL(for: directory) {
                    var safeLegacyState = loadedState
                    safeLegacyState.session = nil
                    try Self.persist(safeLegacyState, to: legacyStateURL)
                }
            } catch {
                EngageLogger.error("Core.Storage", "legacy functional state rewrite failed", error: error)
            }
        }
        if migratedLegacyRevocation { try? FileManager.default.removeItem(at: legacyRevocationURL) }
    }

    func recoveryToken() -> String? {
        EngageLogger.verbose("Core.Storage", "recovery token read present=\(sessionSecrets?.recoveryToken != nil)")
        return sessionSecrets?.recoveryToken
    }

    func saveSession(_ session: InstallationSession) throws {
        EngageLogger.debug(
            "Core.Storage",
            "session persist started installationId=\(session.installationId) generation=\(session.generation)"
        )
        let secrets = SessionSecrets(session)
        let previousSecrets = sessionSecrets
        try secureStore.write(secrets, account: .session)
        do {
            try mutateState {
                state.session = PersistedSession(session)
                state.privacy = session.privacy
                state.wiped = false
            }
            sessionSecrets = secrets
            EngageLogger.info(
                "Core.Storage",
                "session persisted installationId=\(session.installationId) generation=\(session.generation)"
            )
        } catch {
            if let previousSecrets {
                try? secureStore.write(previousSecrets, account: .session)
            } else {
                try? secureStore.delete(account: .session)
            }
            throw error
        }
    }

    func setPrivacy(_ value: PrivacyState) throws {
        EngageLogger.debug("Core.Storage", "privacy persisting state=\(value)")
        try mutateState {
            state.privacy = value
            if let session = state.session {
                state.session = session.withPrivacy(value)
            }
        }
    }

    func resumeAfterWipe() throws {
        guard state.wiped || privacyControl?.suspendedAfterWipe == true else {
            EngageLogger.verbose("Core.Storage", "resume after wipe ignored reason=not_wiped")
            return
        }
        EngageLogger.warning("Core.Storage", "resuming after wipe")
        try mutateState { state.wiped = false }
        try updatePrivacyControl(suspendedAfterWipe: false)
    }

    /// Persists the refusal and its server operation in one atomic state-file replacement.
    func recordOptOut(_ operation: SdkOperation) throws {
        try recordPrivacy(.optedOut, operation: operation, resumesAfterWipe: false)
    }

    /// Persists reactivation and its server operation in the same boundary, including after wipe.
    func recordOptIn(_ operation: SdkOperation) throws {
        try recordPrivacy(.optedIn, operation: operation, resumesAfterWipe: true)
    }

    private func recordPrivacy(
        _ privacy: PrivacyState,
        operation: SdkOperation,
        resumesAfterWipe: Bool
    ) throws {
        EngageLogger.debug(
            "Core.Storage",
            "privacy operation persisting operationId=\(operation.operationId) state=\(privacy) " +
                "resumesAfterWipe=\(resumesAfterWipe)"
        )
        try mutateState {
            state.privacy = privacy
            if let session = state.session {
                state.session = session.withPrivacy(privacy)
            }
            if resumesAfterWipe { state.wiped = false }
            if !state.outbox.contains(where: { $0.operationId == operation.operationId }) {
                state.outbox.append(operation)
            }
        }
        if resumesAfterWipe { try updatePrivacyControl(suspendedAfterWipe: false) }
        EngageLogger.info("Core.Storage", "privacy operation persisted operationId=\(operation.operationId)")
    }

    func enqueue(_ operation: SdkOperation) throws {
        guard !state.outbox.contains(where: { $0.operationId == operation.operationId }) else {
            EngageLogger.verbose("Core.Storage", "outbox duplicate ignored operationId=\(operation.operationId)")
            return
        }
        EngageLogger.debug(
            "Core.Storage",
            "outbox persisting operationId=\(operation.operationId) type=\(operation.type) generation=\(operation.generation)"
        )
        try mutateState { state.outbox.append(operation) }
        EngageLogger.debug("Core.Storage", "outbox persisted operationId=\(operation.operationId) size=\(state.outbox.count)")
    }

    func operations(allowedTypes: Set<String>? = nil, limit: Int = 100) -> [SdkOperation] {
        let operations = state.outbox
            .filter { allowedTypes == nil || allowedTypes!.contains($0.type) }
            .prefix(limit)
            .map { $0 }
        EngageLogger.verbose(
            "Core.Storage",
            "outbox read count=\(operations.count) allowedTypes=\(allowedTypes?.sorted() ?? []) limit=\(limit)"
        )
        return operations
    }

    func settle(_ results: [OperationResult]) throws {
        EngageLogger.debug("Core.Storage", "outbox settling results=\(results.count)")
        let completed = Set(results.map(\.operationId))
        try mutateState { state.outbox.removeAll { completed.contains($0.operationId) } }
        EngageLogger.info("Core.Storage", "outbox settled completed=\(completed.count) remaining=\(state.outbox.count)")
    }

    func snapshot() -> SyncSnapshot { state.sync }

    func applySync(_ response: SyncResponse, modules: Set<SyncModule>) throws {
        EngageLogger.debug(
            "Core.Storage",
            "sync applying generation=\(response.generation) revision=\(response.revision) " +
                "modules=\(modules) documents=\(response.documents.count) tombstones=\(response.tombstones.count) " +
                "fullSnapshot=\(response.fullSnapshot)"
        )
        var documents = response.fullSnapshot
            ? state.sync.documents.filter { !modules.contains($0.module) }
            : state.sync.documents
        let tombstones = Set(response.tombstones.map { "\($0.module.rawValue)\u{0}\($0.key)" })
        documents.removeAll { tombstones.contains("\($0.module.rawValue)\u{0}\($0.key)") }
        response.documents.forEach { document in
            documents.removeAll { $0.module == document.module && $0.key == document.key }
            documents.append(document)
        }
        try mutateState {
            state.sync = SyncSnapshot(
                cursor: response.cursor,
                generation: response.generation,
                revision: response.revision,
                documents: documents,
                refreshAfterSeconds: max(30, response.refreshAfterSeconds)
            )
        }
        EngageLogger.info(
            "Core.Storage",
            "sync applied generation=\(response.generation) revision=\(response.revision) documents=\(documents.count)"
        )
    }

    func clearSync() throws {
        EngageLogger.warning("Core.Storage", "sync state clearing")
        try mutateState { state.sync = .empty }
    }
    func containsExposure(_ id: String) -> Bool { state.exposedOperationIds.contains(id) }
    func markExposure(_ id: String) throws {
        try mutateState { state.exposedOperationIds.insert(id) }
        EngageLogger.debug("Core.Storage", "exposure persisted operationId=\(id)")
    }
    func setDisabledFeatures(_ values: Set<SdkFeature>) throws {
        EngageLogger.debug("Core.Storage", "disabled features persisting values=\(values)")
        try mutateState { state.disabledFeatures = values }
    }

    func wipeFunctionalState() throws {
        EngageLogger.warning(
            "Core.Storage",
            "functional wipe started outbox=\(state.outbox.count) documents=\(state.sync.documents.count)"
        )
        if privacyControl?.suspendedAfterWipe != true {
            try beginWipe(revocation: nil)
        }
        let previous = state
        let previousSecrets = sessionSecrets
        try secureStore.delete(account: .session)
        do {
            try mutateState {
                state.session = nil
                state.outbox = []
                state.sync = .empty
                state.exposedOperationIds = []
                state.privacy = .optedOut
                state.wiped = true
            }
            sessionSecrets = nil
            EngageLogger.warning("Core.Storage", "functional wipe completed")
        } catch {
            state = previous
            sessionSecrets = previousSecrets
            if let previousSecrets { try? secureStore.write(previousSecrets, account: .session) }
            throw error
        }
    }

    /// Establishes the non-functional privacy boundary before any destructive wipe begins.
    func beginWipe(revocation: RevocationEnvelope?) throws {
        EngageLogger.warning(
            "Core.Storage",
            "privacy wipe boundary persisting hasRevocation=\(revocation != nil)"
        )
        var pending = privacyControl?.revocations ?? []
        if let revocation, !pending.contains(where: {
            $0.operationId == revocation.operationId || $0.credential == revocation.credential
        }) {
            pending.append(revocation)
        }
        let value = PrivacyControl(suspendedAfterWipe: true, revocations: pending)
        try secureStore.write(value, account: .privacyControl)
        privacyControl = value
        EngageLogger.warning("Core.Storage", "privacy wipe boundary persisted pendingRevocations=\(pending.count)")
    }

    func pendingRevocation() -> RevocationEnvelope? { privacyControl?.revocations.first }

    func clearRevocation(operationId: String) throws {
        guard var value = privacyControl else {
            EngageLogger.verbose("Core.Storage", "revocation clear ignored operationId=\(operationId) reason=no_control")
            return
        }
        value.revocations.removeAll { $0.operationId == operationId }
        try secureStore.write(value, account: .privacyControl)
        privacyControl = value
        EngageLogger.info(
            "Core.Storage",
            "revocation cleared operationId=\(operationId) remaining=\(value.revocations.count)"
        )
    }

    private func updatePrivacyControl(suspendedAfterWipe: Bool) throws {
        guard var value = privacyControl else { return }
        value.suspendedAfterWipe = suspendedAfterWipe
        try secureStore.write(value, account: .privacyControl)
        privacyControl = value
    }

    private func persistState() throws { try Self.persist(state, to: stateURL) }

    private func mutateState(_ mutation: () -> Void) throws {
        let previous = state
        mutation()
        do {
            try persistState()
        } catch {
            state = previous
            throw error
        }
    }

    private static func persist<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        EngageLogger.verbose("Core.Storage", "file persisted name=\(url.lastPathComponent) bytes=\(data.count)")
    }
}

private enum SecureAccount: String { case session, privacyControl = "privacy-control", revocation }

/// The platform store is always used by the SDK. The file-backed option provides deterministic,
/// isolated storage to package tests whose host process has no Keychain entitlement.
enum SecureStorageBackend: Sendable {
    case platform
    case fileSystem
}

/// Keychain-backed on Apple platforms. The file fallback only exists so the package can be tested on Linux.
private final class SecureBlobStore: @unchecked Sendable {
    private let directory: URL
    private let service: String
    private let legacyService: String?
    private let backend: SecureStorageBackend

    init(
        directory: URL,
        service: String = "io.engage.sdk.credentials",
        legacyService: String? = nil,
        backend: SecureStorageBackend = .platform
    ) {
        self.directory = directory
        self.service = service
        self.backend = backend
        #if canImport(Security)
        self.legacyService = switch backend {
        case .platform: legacyService == service ? nil : legacyService
        case .fileSystem: nil
        }
        #else
        self.legacyService = nil
        #endif
    }

    func read<T: Decodable>(_ type: T.Type, account: SecureAccount) -> T? {
        guard let data = readData(account: account) else {
            EngageLogger.verbose("Core.SecureStore", "read account=\(account.rawValue) present=false")
            return nil
        }
        let decoded = try? JSONDecoder().decode(type, from: data)
        EngageLogger.verbose(
            "Core.SecureStore",
            "read account=\(account.rawValue) present=true decoded=\(decoded != nil) bytes=\(data.count)"
        )
        return decoded
    }

    func write<T: Encodable>(_ value: T, account: SecureAccount) throws {
        let data = try JSONEncoder().encode(value)
        EngageLogger.debug("Core.SecureStore", "write account=\(account.rawValue) bytes=\(data.count)")
        try writeData(data, account: account, service: service)
        if let legacyService { try deleteData(account: account, service: legacyService) }
    }

    func delete(account: SecureAccount) throws {
        EngageLogger.debug("Core.SecureStore", "delete account=\(account.rawValue)")
        try deleteData(account: account, service: service)
        if let legacyService { try deleteData(account: account, service: legacyService) }
    }

    private func readData(account: SecureAccount) -> Data? {
        if let data = readData(account: account, service: service) { return data }
        guard let legacyService,
              let legacyData = readData(account: account, service: legacyService) else { return nil }
        do {
            try writeData(legacyData, account: account, service: service)
            try deleteData(account: account, service: legacyService)
            EngageLogger.info("Core.SecureStore", "legacy account migrated account=\(account.rawValue)")
        } catch {
            // Continue using the legacy value for this launch, but retain it so migration can retry.
            EngageLogger.error(
                "Core.SecureStore",
                "legacy account migration deferred account=\(account.rawValue)",
                error: error
            )
        }
        return legacyData
    }

    private func readData(account: SecureAccount, service: String) -> Data? {
        #if canImport(Security)
        if backend == .platform {
            var request = query(account: account, service: service)
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
            return result as? Data
        }
        #endif
        return try? Data(contentsOf: fallbackURL(account))
    }

    private func writeData(_ data: Data, account: SecureAccount, service: String) throws {
        #if canImport(Security)
        if backend == .platform {
            let selector = query(account: account, service: service)
            let updateStatus = SecItemUpdate(
                selector as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if updateStatus == errSecSuccess { return }
            guard updateStatus == errSecItemNotFound else { throw SecureStoreError(status: updateStatus) }
            var insertion = selector
            insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SecureStoreError(status: addStatus) }
            return
        }
        #endif
        try data.write(to: fallbackURL(account), options: [.atomic])
    }

    private func deleteData(account: SecureAccount, service: String) throws {
        #if canImport(Security)
        if backend == .platform {
            let status = SecItemDelete(query(account: account, service: service) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecureStoreError(status: status)
            }
            return
        }
        #endif
        do {
            try FileManager.default.removeItem(at: fallbackURL(account))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    #if canImport(Security)
    private func query(account: SecureAccount, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }
    #endif

    private func fallbackURL(_ account: SecureAccount) -> URL {
        directory.appendingPathComponent("secure-\(account.rawValue).json")
    }
}

#if canImport(Security)
private struct SecureStoreError: Error { let status: OSStatus }
#endif

private let legacyStorageMigrationLock = NSLock()
private let endpointStorageMigrationLock = NSLock()
private let legacyKeychainOwnerMarker = ".legacy-keychain-owner-v2"
private let endpointKeychainOwnerMarker = ".endpoint-keychain-owner-v3"

private struct EndpointStorageMigrationRecord: Codable {
    let sourceScope: String
    let targetScope: String
}

private struct LegacyStorageMigrationRecord: Codable {
    let ownerScope: String
    var completedItems: Set<String>
}

private struct LegacyStorageItem {
    let identifier: String
    let source: String
    let destination: String
}

private enum LegacyStorageMigrationError: Error {
    case invalidRecord
    case conflictingEndpointStorage
    case missingEndpointStorage
}

/// Claims the pre-isolation storage for the first app configuration and migrates every item once.
/// Completed-item markers deliberately survive functional wipes so legacy data cannot reappear.
func migrateLegacyStorage(from legacyRoot: URL, to scopedDirectory: URL, scope: String) throws {
    legacyStorageMigrationLock.lock()
    defer { legacyStorageMigrationLock.unlock() }

    let manager = FileManager.default
    try manager.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
    try manager.createDirectory(at: scopedDirectory, withIntermediateDirectories: true)
    let recordURL = legacyRoot.appendingPathComponent(".storage-migration-v2.json")
    var record: LegacyStorageMigrationRecord
    if manager.fileExists(atPath: recordURL.path) {
        let data = try Data(contentsOf: recordURL)
        guard let decoded = try? JSONDecoder().decode(LegacyStorageMigrationRecord.self, from: data) else {
            throw LegacyStorageMigrationError.invalidRecord
        }
        record = decoded
    } else {
        record = LegacyStorageMigrationRecord(ownerScope: scope, completedItems: [])
        try persistLegacyStorageMigration(record, to: recordURL)
    }

    guard record.ownerScope == scope else { return }
    let items = [
        LegacyStorageItem(identifier: "core-state", source: "core-state.json", destination: "core-state.json"),
        LegacyStorageItem(
            identifier: "privacy-revocation",
            source: "privacy-revocation.json",
            destination: "privacy-revocation.json"
        ),
        LegacyStorageItem(
            identifier: "secure-session-fallback",
            source: "secure-session.json",
            destination: "secure-session.json"
        ),
        LegacyStorageItem(
            identifier: "secure-privacy-fallback",
            source: "secure-privacy-control.json",
            destination: "secure-privacy-control.json"
        ),
        LegacyStorageItem(
            identifier: "secure-revocation-fallback",
            source: "secure-revocation.json",
            destination: "secure-revocation.json"
        ),
        LegacyStorageItem(
            identifier: "in-app-history",
            source: "in-app-history.json",
            destination: "in-app/in-app-history.json"
        ),
        LegacyStorageItem(
            identifier: "message-center-inbox",
            source: "inbox.json",
            destination: "message-center/inbox.json"
        ),
        LegacyStorageItem(
            identifier: "push-state",
            source: "push-state.json",
            destination: "push/push-state.json"
        ),
    ]

    for item in items where !record.completedItems.contains(item.identifier) {
        let source = legacyRoot.appendingPathComponent(item.source)
        let destination = scopedDirectory.appendingPathComponent(item.destination)
        if manager.fileExists(atPath: source.path), !manager.fileExists(atPath: destination.path) {
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try manager.copyItem(at: source, to: destination)
        }
        record.completedItems.insert(item.identifier)
        try persistLegacyStorageMigration(record, to: recordURL)
    }

    let ownerMarker = scopedDirectory.appendingPathComponent(legacyKeychainOwnerMarker)
    try Data(scope.utf8).write(to: ownerMarker, options: [.atomic])
}

private func persistLegacyStorageMigration(_ record: LegacyStorageMigrationRecord, to url: URL) throws {
    try JSONEncoder().encode(record).write(to: url, options: [.atomic])
}

private func legacyCoreStateURL(for scopedDirectory: URL) -> URL? {
    guard FileManager.default.fileExists(
        atPath: scopedDirectory.appendingPathComponent(legacyKeychainOwnerMarker).path
    ) else { return nil }
    let applicationsDirectory = scopedDirectory.deletingLastPathComponent()
    guard applicationsDirectory.lastPathComponent == "applications" else { return nil }
    let legacyURL = applicationsDirectory
        .deletingLastPathComponent()
        .appendingPathComponent("core-state.json")
    return FileManager.default.fileExists(atPath: legacyURL.path) ? legacyURL : nil
}

func engageStorageDirectory(config: EngageConfig) throws -> URL {
    let manager = FileManager.default
    let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? manager.temporaryDirectory
    return try engageStorageDirectory(config: config, base: base)
}

func engageStorageDirectory(config: EngageConfig, base: URL) throws -> URL {
    let manager = FileManager.default
    let legacyRoot = base.appendingPathComponent("io.engage.sdk", isDirectory: true)
    let applications = legacyRoot.appendingPathComponent("applications", isDirectory: true)
    let targetScope = engageStorageScope(config: config)
    let directory = applications.appendingPathComponent(targetScope, isDirectory: true)
    let endpointScopes = ([config.endpoint] + config.legacyEndpoints)
        .map { legacyEndpointStorageScope(appKey: config.appKey, endpoint: $0) }
        .reduce(into: [String]()) { scopes, scope in
            if !scopes.contains(scope) { scopes.append(scope) }
        }
    try migrateEndpointStorage(
        applications: applications,
        targetDirectory: directory,
        targetScope: targetScope,
        sourceScopes: endpointScopes
    )
    try migrateLegacyStorage(
        from: legacyRoot,
        to: directory,
        scope: targetScope
    )
    return directory
}

private func migrateEndpointStorage(
    applications: URL,
    targetDirectory: URL,
    targetScope: String,
    sourceScopes: [String]
) throws {
    endpointStorageMigrationLock.lock()
    defer { endpointStorageMigrationLock.unlock() }

    let manager = FileManager.default
    try manager.createDirectory(at: applications, withIntermediateDirectories: true)
    let recordURL = applications.appendingPathComponent(".endpoint-migration-v3-\(targetScope).json")
    var record: EndpointStorageMigrationRecord?
    if manager.fileExists(atPath: recordURL.path) {
        let data = try Data(contentsOf: recordURL)
        guard let decoded = try? JSONDecoder().decode(EndpointStorageMigrationRecord.self, from: data),
              decoded.targetScope == targetScope else {
            throw LegacyStorageMigrationError.invalidRecord
        }
        record = decoded
    } else if !manager.fileExists(atPath: targetDirectory.path),
              let sourceScope = sourceScopes.first(where: {
                  manager.fileExists(atPath: applications.appendingPathComponent($0).path)
              }) {
        let created = EndpointStorageMigrationRecord(sourceScope: sourceScope, targetScope: targetScope)
        try JSONEncoder().encode(created).write(to: recordURL, options: [.atomic])
        record = created
    }

    guard let record else { return }
    let sourceDirectory = applications.appendingPathComponent(record.sourceScope, isDirectory: true)
    let sourceExists = manager.fileExists(atPath: sourceDirectory.path)
    let targetExists = manager.fileExists(atPath: targetDirectory.path)
    if sourceExists && !targetExists {
        try manager.moveItem(at: sourceDirectory, to: targetDirectory)
    } else if sourceExists && targetExists {
        throw LegacyStorageMigrationError.conflictingEndpointStorage
    } else if !targetExists {
        throw LegacyStorageMigrationError.missingEndpointStorage
    }

    try Data(record.sourceScope.utf8).write(
        to: targetDirectory.appendingPathComponent(endpointKeychainOwnerMarker),
        options: [.atomic]
    )
    try manager.removeItem(at: recordURL)
}

func engageStorageScope(config: EngageConfig) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    config.appKey.utf8.forEach {
        hash = (hash ^ UInt64($0)) &* 0x100000001b3
    }
    return String(hash, radix: 16).leftPadding(toLength: 16, withPad: "0")
}

func legacyEndpointStorageScope(config: EngageConfig) -> String {
    legacyEndpointStorageScope(appKey: config.appKey, endpoint: config.endpoint)
}

private func legacyEndpointStorageScope(appKey: String, endpoint: URL) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    "\(endpoint.absoluteString)\u{0}\(appKey)".utf8.forEach {
        hash = (hash ^ UInt64($0)) &* 0x100000001b3
    }
    return String(hash, radix: 16).leftPadding(toLength: 16, withPad: "0")
}

private func legacyKeychainService(for directory: URL) -> String? {
    let endpointOwner = directory.appendingPathComponent(endpointKeychainOwnerMarker)
    if let data = try? Data(contentsOf: endpointOwner),
       let scope = String(data: data, encoding: .utf8),
       !scope.isEmpty {
        return "io.engage.sdk.credentials.\(scope)"
    }
    return FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(legacyKeychainOwnerMarker).path
    ) ? "io.engage.sdk.credentials" : nil
}

private extension String {
    func leftPadding(toLength: Int, withPad pad: Character) -> String {
        guard count < toLength else { return self }
        return String(repeating: String(pad), count: toLength - count) + self
    }
}

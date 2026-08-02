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

    init(directory: URL) {
        stateURL = directory.appendingPathComponent("core-state.json")
        legacyRevocationURL = directory.appendingPathComponent("privacy-revocation.json")
        secureStore = SecureBlobStore(directory: directory)

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

        // Rewrites legacy state without credentials after a successful migration.
        if mayRewriteFunctionalState { try? Self.persist(loadedState, to: stateURL) }
        if migratedLegacyRevocation { try? FileManager.default.removeItem(at: legacyRevocationURL) }
    }

    func recoveryToken() -> String? { sessionSecrets?.recoveryToken }

    func saveSession(_ session: InstallationSession) throws {
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
        try mutateState {
            state.privacy = value
            if let session = state.session {
                state.session = session.withPrivacy(value)
            }
        }
    }

    func resumeAfterWipe() throws {
        guard state.wiped || privacyControl?.suspendedAfterWipe == true else { return }
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
    }

    func enqueue(_ operation: SdkOperation) throws {
        guard !state.outbox.contains(where: { $0.operationId == operation.operationId }) else { return }
        try mutateState { state.outbox.append(operation) }
    }

    func operations(allowedTypes: Set<String>? = nil, limit: Int = 100) -> [SdkOperation] {
        state.outbox
            .filter { allowedTypes == nil || allowedTypes!.contains($0.type) }
            .prefix(limit)
            .map { $0 }
    }

    func settle(_ results: [OperationResult]) throws {
        let completed = Set(results.map(\.operationId))
        try mutateState { state.outbox.removeAll { completed.contains($0.operationId) } }
    }

    func snapshot() -> SyncSnapshot { state.sync }

    func applySync(_ response: SyncResponse, modules: Set<SyncModule>) throws {
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
    }

    func clearSync() throws { try mutateState { state.sync = .empty } }
    func containsExposure(_ id: String) -> Bool { state.exposedOperationIds.contains(id) }
    func markExposure(_ id: String) throws {
        try mutateState { state.exposedOperationIds.insert(id) }
    }
    func setDisabledFeatures(_ values: Set<SdkFeature>) throws {
        try mutateState { state.disabledFeatures = values }
    }

    func wipeFunctionalState() throws {
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
        } catch {
            state = previous
            sessionSecrets = previousSecrets
            if let previousSecrets { try? secureStore.write(previousSecrets, account: .session) }
            throw error
        }
    }

    /// Establishes the non-functional privacy boundary before any destructive wipe begins.
    func beginWipe(revocation: RevocationEnvelope?) throws {
        var pending = privacyControl?.revocations ?? []
        if let revocation, !pending.contains(where: {
            $0.operationId == revocation.operationId || $0.credential == revocation.credential
        }) {
            pending.append(revocation)
        }
        let value = PrivacyControl(suspendedAfterWipe: true, revocations: pending)
        try secureStore.write(value, account: .privacyControl)
        privacyControl = value
    }

    func pendingRevocation() -> RevocationEnvelope? { privacyControl?.revocations.first }

    func clearRevocation(operationId: String) throws {
        guard var value = privacyControl else { return }
        value.revocations.removeAll { $0.operationId == operationId }
        try secureStore.write(value, account: .privacyControl)
        privacyControl = value
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
    }
}

private enum SecureAccount: String { case session, privacyControl = "privacy-control", revocation }

/// Keychain-backed on Apple platforms. The file fallback only exists so the package can be tested on Linux.
private final class SecureBlobStore: @unchecked Sendable {
    private let directory: URL
    private let service = "io.engage.sdk.credentials"

    init(directory: URL) { self.directory = directory }

    func read<T: Decodable>(_ type: T.Type, account: SecureAccount) -> T? {
        guard let data = readData(account: account) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func write<T: Encodable>(_ value: T, account: SecureAccount) throws {
        try writeData(JSONEncoder().encode(value), account: account)
    }

    func delete(account: SecureAccount) throws {
        #if canImport(Security)
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStoreError(status: status)
        }
        #else
        try? FileManager.default.removeItem(at: fallbackURL(account))
        #endif
    }

    private func readData(account: SecureAccount) -> Data? {
        #if canImport(Security)
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
        #else
        return try? Data(contentsOf: fallbackURL(account))
        #endif
    }

    private func writeData(_ data: Data, account: SecureAccount) throws {
        #if canImport(Security)
        let selector = query(account: account)
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
        #else
        try data.write(to: fallbackURL(account), options: [.atomic])
        #endif
    }

    #if canImport(Security)
    private func query(account: SecureAccount) -> [String: Any] {
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

func engageStorageDirectory() -> URL {
    let manager = FileManager.default
    let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? manager.temporaryDirectory
    let directory = base.appendingPathComponent("io.engage.sdk", isDirectory: true)
    try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

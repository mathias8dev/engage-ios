import XCTest
@testable import EngageCore
@_spi(Modules) import EngageCore

final class EngageCoreTests: XCTestCase {
    func testDifferentApplicationConfigurationsUseDifferentStorageScopes() {
        let first = EngageConfig(
            appKey: "eng_app_first",
            endpoint: URL(string: "https://edge.example.test/v1/")!
        )
        let second = EngageConfig(
            appKey: "eng_app_second",
            endpoint: URL(string: "https://edge.example.test/v1/")!
        )

        XCTAssertNotEqual(engageStorageScope(config: first), engageStorageScope(config: second))
        XCTAssertEqual(engageStorageScope(config: first), engageStorageScope(config: first))
    }

    func testLegacyStorageMigratesToOnlyOneScopeAndCannotResurrectAfterWipe() async throws {
        let legacyRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: legacyRoot) }
        let ownerDirectory = legacyRoot
            .appendingPathComponent("applications", isDirectory: true)
            .appendingPathComponent("owner", isDirectory: true)
        let contenderDirectory = legacyRoot
            .appendingPathComponent("applications", isDirectory: true)
            .appendingPathComponent("contender", isDirectory: true)
        let operation = SdkOperation(
            operationId: "legacy-opt-out",
            generation: 3,
            type: "PRIVACY_STATE_SET",
            occurredAt: "2026-08-06T12:00:00Z",
            payload: ["state": .string("OPTED_OUT")]
        )
        let legacySession = InstallationSession(
            installationId: "legacy-installation",
            credential: "legacy-secret-credential",
            revocationCredential: "legacy-secret-revocation",
            recoveryToken: "legacy-secret-recovery",
            generation: 3,
            privacy: .optedOut,
            pushSubscription: "OPTED_OUT",
            serverTime: "2026-08-06T12:00:00Z"
        )
        let legacyState = LegacyStateFixture(
            session: legacySession,
            privacy: .optedOut,
            outbox: [operation],
            sync: .empty,
            exposedOperationIds: [],
            disabledFeatures: []
        )
        try JSONEncoder().encode(legacyState).write(
            to: legacyRoot.appendingPathComponent("core-state.json")
        )
        try Data("legacy-history".utf8).write(
            to: legacyRoot.appendingPathComponent("in-app-history.json")
        )

        try migrateLegacyStorage(from: legacyRoot, to: ownerDirectory, scope: "owner")

        let migrated = testPersistence(at: ownerDirectory)
        XCTAssertEqual(migrated.initialState.privacy, .optedOut)
        XCTAssertEqual(migrated.initialState.session, legacySession)
        let operations = await migrated.operations()
        XCTAssertEqual(operations, [operation])
        for stateURL in [
            legacyRoot.appendingPathComponent("core-state.json"),
            ownerDirectory.appendingPathComponent("core-state.json"),
        ] {
            let functionalState = try String(contentsOf: stateURL, encoding: .utf8)
            XCTAssertFalse(functionalState.contains("legacy-secret-credential"))
            XCTAssertFalse(functionalState.contains("legacy-secret-revocation"))
            XCTAssertFalse(functionalState.contains("legacy-secret-recovery"))
        }
        XCTAssertEqual(
            try Data(contentsOf: ownerDirectory.appendingPathComponent("in-app/in-app-history.json")),
            Data("legacy-history".utf8)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: ownerDirectory.appendingPathComponent(".legacy-keychain-owner-v2").path
            )
        )

        try FileManager.default.removeItem(at: ownerDirectory.appendingPathComponent("core-state.json"))
        try FileManager.default.removeItem(
            at: ownerDirectory.appendingPathComponent("in-app/in-app-history.json")
        )
        try migrateLegacyStorage(from: legacyRoot, to: ownerDirectory, scope: "owner")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ownerDirectory.appendingPathComponent("core-state.json").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ownerDirectory.appendingPathComponent("in-app/in-app-history.json").path
            )
        )

        try migrateLegacyStorage(from: legacyRoot, to: contenderDirectory, scope: "contender")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: contenderDirectory.appendingPathComponent("core-state.json").path
            )
        )
    }

    func testJSONValueRoundTripsWithoutFlatteningTypes() throws {
        let value: JSONValue = .object([
            "title": .string("Order ready"),
            "sequence": .integer(Int64.max),
            "amount": .number(42.5),
            "visible": .bool(true),
            "items": .array([.string("one"), .null]),
        ])
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), value)
    }

    func testStateIsHotAndStartsWithCurrentValue() async {
        let state = EngageState(7)
        state.set(8)
        var iterator = state.updates.makeAsyncIterator()
        let value = await iterator.next()
        XCTAssertEqual(value, 8)
    }

    func testStateIsMulticastAndConflatesPendingValues() async {
        let state = EngageState(1)
        var first = state.updates.makeAsyncIterator()
        var second = state.updates.makeAsyncIterator()

        state.set(2)
        state.set(3)

        let firstValue = await first.next()
        let secondValue = await second.next()
        XCTAssertEqual(firstValue, 3)
        XCTAssertEqual(secondValue, 3)
    }

    func testSessionCredentialsAreNotWrittenToFunctionalState() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = testPersistence(at: directory)
        let session = InstallationSession(
            installationId: "installation-1",
            credential: "secret-credential",
            revocationCredential: "secret-revocation",
            recoveryToken: "secret-recovery",
            generation: 4,
            privacy: .optedIn,
            pushSubscription: "OPTED_IN",
            serverTime: "2026-08-02T12:00:00Z"
        )

        try await persistence.saveSession(session)

        let functionalState = try String(
            contentsOf: directory.appendingPathComponent("core-state.json"),
            encoding: .utf8
        )
        XCTAssertFalse(functionalState.contains("secret-credential"))
        XCTAssertFalse(functionalState.contains("secret-revocation"))
        XCTAssertFalse(functionalState.contains("secret-recovery"))
        XCTAssertEqual(testPersistence(at: directory).initialState.session, session)
    }

    func testOptOutAndServerOperationSurviveTheSameAtomicPersistenceBoundary() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = testPersistence(at: directory)
        let operation = SdkOperation(
            operationId: "privacy-operation",
            generation: 7,
            type: "PRIVACY_STATE_SET",
            occurredAt: "2026-08-02T12:00:00Z",
            payload: ["state": .string("OPTED_OUT")]
        )

        try await persistence.recordOptOut(operation)

        let reloaded = testPersistence(at: directory)
        XCTAssertEqual(reloaded.initialState.privacy, .optedOut)
        XCTAssertTrue(reloaded.initialState.installationEnabled)
        let operations = await reloaded.operations()
        XCTAssertEqual(operations, [operation])
    }

    func testWipeRemainsSuspendedAcrossRestartUntilExplicitResume() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = testPersistence(at: directory)

        try await persistence.wipeFunctionalState()
        XCTAssertFalse(testPersistence(at: directory).initialState.installationEnabled)

        try await persistence.resumeAfterWipe()
        XCTAssertTrue(testPersistence(at: directory).initialState.installationEnabled)
    }

    func testPrivacyBoundarySurvivesCrashBeforeFunctionalWipe() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = testPersistence(at: directory)
        let session = InstallationSession(
            installationId: "installation-before-wipe",
            credential: "credential",
            revocationCredential: "revocation-credential",
            recoveryToken: "recovery",
            generation: 9,
            privacy: .optedIn,
            pushSubscription: "OPTED_IN",
            serverTime: "2026-08-02T12:00:00Z"
        )
        let envelope = RevocationEnvelope(operationId: "revoke-9", credential: "revocation-credential")
        try await persistence.saveSession(session)

        // Simulate a process death immediately after the durable privacy boundary.
        try await persistence.beginWipe(revocation: envelope)

        let reloaded = testPersistence(at: directory)
        XCTAssertEqual(reloaded.initialState.privacy, .optedOut)
        XCTAssertFalse(reloaded.initialState.installationEnabled)
        XCTAssertNil(reloaded.initialState.session)
        let pending = await reloaded.pendingRevocation()
        XCTAssertEqual(pending, envelope)

        try await reloaded.clearRevocation(operationId: envelope.operationId)
        let afterAcknowledgement = testPersistence(at: directory)
        XCTAssertEqual(afterAcknowledgement.initialState.privacy, .optedOut)
        XCTAssertFalse(afterAcknowledgement.initialState.installationEnabled)
        let cleared = await afterAcknowledgement.pendingRevocation()
        XCTAssertNil(cleared)
    }

    func testASecondWipeDoesNotReplaceAnOlderPendingRevocation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = testPersistence(at: directory)
        let first = RevocationEnvelope(operationId: "revoke-first", credential: "credential-first")
        let second = RevocationEnvelope(operationId: "revoke-second", credential: "credential-second")

        try await persistence.beginWipe(revocation: first)
        try await persistence.resumeAfterWipe()
        try await persistence.beginWipe(revocation: second)

        var pending = await persistence.pendingRevocation()
        XCTAssertEqual(pending, first)
        try await persistence.clearRevocation(operationId: first.operationId)
        pending = await persistence.pendingRevocation()
        XCTAssertEqual(pending, second)
    }

    func testOptInAfterWipePersistsReactivationAndServerOperationAtomically() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = testPersistence(at: directory)
        try await persistence.wipeFunctionalState()
        let operation = SdkOperation(
            operationId: "privacy-opt-in",
            generation: 0,
            type: "PRIVACY_STATE_SET",
            occurredAt: "2026-08-02T12:00:00Z",
            payload: ["state": .string("OPTED_IN")]
        )

        try await persistence.recordOptIn(operation)

        let reloaded = testPersistence(at: directory)
        XCTAssertEqual(reloaded.initialState.privacy, .optedIn)
        XCTAssertTrue(reloaded.initialState.installationEnabled)
        let operations = await reloaded.operations()
        XCTAssertEqual(operations, [operation])
    }

    func testActionRegistrationIsTypedAndCancelledByIdentity() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = CoreRuntime(
            config: EngageConfig(appKey: "eng_app_tests", endpoint: URL(string: "https://example.test/v1/")!),
            directory: directory
        )
        let first = UUID()
        let replacement = UUID()
        await runtime.registerAction("open_order", id: first) { _ in false }
        await runtime.registerAction("open_order", id: replacement) { payload in
            payload.string("order_id") == "order-42"
        }

        var executed = await runtime.executeAction("open_order", arguments: ["order_id": .string("order-42")])
        XCTAssertTrue(executed)
        await runtime.unregisterAction("open_order", id: first)
        executed = await runtime.executeAction("open_order", arguments: ["order_id": .string("order-42")])
        XCTAssertTrue(executed)
        await runtime.unregisterAction("open_order", id: replacement)
        executed = await runtime.executeAction("open_order", arguments: [:])
        XCTAssertFalse(executed)
    }

    func testEditingCoreFeaturesDoesNotDisableAModuleInstalledLater() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = testPersistence(at: directory)
        try await persistence.recordOptOut(SdkOperation(
            operationId: "keep-runtime-offline",
            generation: 0,
            type: "PRIVACY_STATE_SET",
            occurredAt: "2026-08-02T12:00:00Z",
            payload: ["state": .string("OPTED_OUT")]
        ))
        let runtime = CoreRuntime(
            config: EngageConfig(appKey: "eng_app_tests", endpoint: URL(string: "https://example.test/v1/")!),
            directory: directory
        )

        try await runtime.editFeatures([.preferences, .featureFlags])
        await runtime.register(EngageModuleRegistration(
            id: "push-test",
            features: [.push],
            syncModules: [.push],
            wipe: {}
        ))

        XCTAssertTrue(runtime.enabledFeatures.value.contains(.push))
        XCTAssertFalse(runtime.enabledFeatures.value.contains(.analytics))
    }

    private func temporaryDirectory() throws -> URL {
        let value = FileManager.default.temporaryDirectory
            .appendingPathComponent("engage-core-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    private func testPersistence(at directory: URL) -> CorePersistence {
        CorePersistence(directory: directory, secureStorageBackend: .fileSystem)
    }
}

private struct LegacyStateFixture: Encodable {
    let session: InstallationSession?
    let privacy: PrivacyState
    let outbox: [SdkOperation]
    let sync: SyncSnapshot
    let exposedOperationIds: Set<String>
    let disabledFeatures: Set<SdkFeature>
}

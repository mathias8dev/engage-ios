import XCTest
@testable import EngageCore
@_spi(Modules) import EngageCore

final class EngageCoreTests: XCTestCase {
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
        let persistence = CorePersistence(directory: directory)
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
        XCTAssertEqual(CorePersistence(directory: directory).initialState.session, session)
    }

    func testOptOutAndServerOperationSurviveTheSameAtomicPersistenceBoundary() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = CorePersistence(directory: directory)
        let operation = SdkOperation(
            operationId: "privacy-operation",
            generation: 7,
            type: "PRIVACY_STATE_SET",
            occurredAt: "2026-08-02T12:00:00Z",
            payload: ["state": .string("OPTED_OUT")]
        )

        try await persistence.recordOptOut(operation)

        let reloaded = CorePersistence(directory: directory)
        XCTAssertEqual(reloaded.initialState.privacy, .optedOut)
        XCTAssertTrue(reloaded.initialState.installationEnabled)
        let operations = await reloaded.operations()
        XCTAssertEqual(operations, [operation])
    }

    func testWipeRemainsSuspendedAcrossRestartUntilExplicitResume() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = CorePersistence(directory: directory)

        try await persistence.wipeFunctionalState()
        XCTAssertFalse(CorePersistence(directory: directory).initialState.installationEnabled)

        try await persistence.resumeAfterWipe()
        XCTAssertTrue(CorePersistence(directory: directory).initialState.installationEnabled)
    }

    func testPrivacyBoundarySurvivesCrashBeforeFunctionalWipe() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = CorePersistence(directory: directory)
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

        let reloaded = CorePersistence(directory: directory)
        XCTAssertEqual(reloaded.initialState.privacy, .optedOut)
        XCTAssertFalse(reloaded.initialState.installationEnabled)
        XCTAssertNil(reloaded.initialState.session)
        let pending = await reloaded.pendingRevocation()
        XCTAssertEqual(pending, envelope)

        try await reloaded.clearRevocation(operationId: envelope.operationId)
        let afterAcknowledgement = CorePersistence(directory: directory)
        XCTAssertEqual(afterAcknowledgement.initialState.privacy, .optedOut)
        XCTAssertFalse(afterAcknowledgement.initialState.installationEnabled)
        let cleared = await afterAcknowledgement.pendingRevocation()
        XCTAssertNil(cleared)
    }

    func testASecondWipeDoesNotReplaceAnOlderPendingRevocation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = CorePersistence(directory: directory)
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
        let persistence = CorePersistence(directory: directory)
        try await persistence.wipeFunctionalState()
        let operation = SdkOperation(
            operationId: "privacy-opt-in",
            generation: 0,
            type: "PRIVACY_STATE_SET",
            occurredAt: "2026-08-02T12:00:00Z",
            payload: ["state": .string("OPTED_IN")]
        )

        try await persistence.recordOptIn(operation)

        let reloaded = CorePersistence(directory: directory)
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
        let persistence = CorePersistence(directory: directory)
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
}

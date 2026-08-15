import XCTest
@testable import EngagePush

final class PushPersistenceTests: XCTestCase {
    #if canImport(UIKit)
    func testStandaloneModuleExposesPublicActivationAndAPNsCallbacks() {
        let activate: () -> Push = PushModule.activate
        let tokenCallback: (Push, Data) -> Void = { push, token in
            push.didRegisterForRemoteNotifications(deviceToken: token)
        }
        let failureCallback: (Push, Error) -> Void = { push, error in
            push.didFailToRegisterForRemoteNotifications(error: error)
        }
        _ = activate
        _ = tokenCallback
        _ = failureCallback
    }
    #endif

    func testSubscriptionTokenAndDisabledMarkerAreDurable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PushPersistence(directory: directory)
        try persistence.edit {
            $0.subscription = "OPTED_OUT"
            $0.token = "apns-token"
            $0.registeredTokenHash = PushStoredState.disabledMarker
            $0.pendingSubscription = true
        }

        XCTAssertEqual(PushPersistence(directory: directory).value, PushStoredState(
            subscription: "OPTED_OUT",
            registeredTokenHash: PushStoredState.disabledMarker,
            token: "apns-token",
            pendingSubscription: true
        ))
    }

    func testWipeRestoresFreshInstallationDefaults() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PushPersistence(directory: directory)
        try persistence.edit { $0.subscription = "OPTED_OUT"; $0.token = "token" }

        try persistence.wipe()

        XCTAssertEqual(PushPersistence(directory: directory).value, PushStoredState())
    }

    func testWipeFailureDoesNotClaimThatMemoryWasCleared() throws {
        enum ExpectedFailure: Error { case disk }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PushPersistence(
            directory: directory,
            removeItem: { _ in throw ExpectedFailure.disk }
        )
        try persistence.edit { $0.subscription = "OPTED_OUT"; $0.token = "token" }

        XCTAssertThrowsError(try persistence.wipe())

        XCTAssertEqual(persistence.value.subscription, "OPTED_OUT")
        XCTAssertEqual(persistence.value.token, "token")
        XCTAssertEqual(PushPersistence(directory: directory).value.subscription, "OPTED_OUT")
    }

    private func temporaryDirectory() throws -> URL {
        let value = FileManager.default.temporaryDirectory
            .appendingPathComponent("engage-push-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
}

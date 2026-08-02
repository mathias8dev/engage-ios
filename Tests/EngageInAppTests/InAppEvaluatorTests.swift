import XCTest
import EngageCore
@_spi(Modules) import EngageCore
@testable import EngageInApp

final class InAppEvaluatorTests: XCTestCase {
    func testStandaloneModuleExposesPublicActivation() {
        let activate: () -> InApp = InAppModule.activate
        let shared: () -> InApp = { InAppModule.shared }
        _ = activate
        _ = shared
    }

    func testVariantAllocationUsesTheSameStableSHA256BucketAsAndroid() throws {
        let fixture = try Fixture(seed: "installation", experienceId: "experience")
        let campaign = fixture.campaign(
            variants: [fixture.variant(id: "a", allocation: 50), fixture.variant(id: "b", allocation: 50)]
        )

        fixture.evaluator.replaceCampaigns([campaign])

        // SHA-256("installation:experience") maps to bucket 59.
        XCTAssertEqual(fixture.evaluator.candidates().first?.variant.id, "b")
    }

    func testDelayScreenContextAndImpressionCapAreEnforcedLocally() throws {
        let fixture = try Fixture(seed: "seed", experienceId: "campaign")
        let trigger = InAppTrigger(
            id: "checkout",
            type: .screenView,
            delaySeconds: 10,
            screenName: "checkout",
            eventName: nil,
            minimumSessions: nil,
            versionConstraint: nil
        )
        let campaign = fixture.campaign(
            triggers: [trigger],
            displayPolicy: InAppDisplayPolicy(
                maxTotalImpressions: 1,
                maxImpressionsPerSession: nil,
                maxImpressionsPerDay: nil,
                cooldownMinutes: nil,
                redisplayAfterDismissal: false
            )
        )
        fixture.evaluator.replaceCampaigns([campaign])
        fixture.evaluator.onSignal(.appOpened)
        fixture.evaluator.onSignal(.screenViewed("checkout"))
        XCTAssertTrue(fixture.evaluator.candidates().isEmpty)

        fixture.clock.advance(10.1)
        let selected = try XCTUnwrap(fixture.evaluator.candidates().first)
        fixture.evaluator.recordImpression(selected)
        XCTAssertTrue(fixture.evaluator.candidates().isEmpty)

        fixture.evaluator.onSignal(.screenCleared)
        XCTAssertFalse(fixture.evaluator.remainsContextuallyEligible(selected))
    }

    func testAutomationDocumentBecomesOneShotContent() throws {
        let document = RemoteDocument(
            module: .inApp,
            key: "automation-message",
            revision: 12,
            payload: [
                "source": .string("AUTOMATION"),
                "experienceId": .string("automation-experience"),
                "messageId": .string("message-12"),
                "availableAt": .string("2026-08-02T12:00:00Z"),
                "expiresAt": .string("2026-08-03T12:00:00Z"),
                "content": .object([
                    "type": .string("SCENE"),
                    "payload": .object(["card": .object(["type": .string("text")])]),
                ]),
                "presentation": .object([
                    "mode": .string("EMBEDDED"),
                    "embedded": .object([
                        "placementKey": .string("home.hero"),
                        "emptyState": .string("COLLAPSE"),
                    ]),
                ]),
            ]
        )

        let campaign = try XCTUnwrap(InAppDocumentParser.parse(document))

        XCTAssertTrue(campaign.oneShot)
        XCTAssertEqual(campaign.messageId, "message-12")
        XCTAssertEqual(campaign.variants.first?.allocationPercentage, 100)
    }

    func testUnsupportedContentOrPresentationIsRejectedInsteadOfSilentlyChanged() {
        func document(contentType: String = "SCENE", overlayFormat: String = "MODAL") -> RemoteDocument {
            RemoteDocument(
                module: .inApp,
                key: "automation-message",
                revision: 12,
                payload: [
                    "source": .string("AUTOMATION"),
                    "experienceId": .string("automation-experience"),
                    "messageId": .string("message-12"),
                    "content": .object([
                        "type": .string(contentType),
                        "payload": .object(["card": .object([:])]),
                    ]),
                    "presentation": .object([
                        "mode": .string("OVERLAY"),
                        "overlay": .object(["format": .string(overlayFormat)]),
                    ]),
                ]
            )
        }

        XCTAssertNil(InAppDocumentParser.parse(document(contentType: "UNKNOWN")))
        XCTAssertNil(InAppDocumentParser.parse(document(overlayFormat: "TOAST")))
    }
}

private final class Fixture {
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let history: InAppHistory
    let evaluator: InAppEvaluator
    let experienceId: String
    private let directory: URL

    init(seed: String, experienceId: String) throws {
        self.experienceId = experienceId
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engage-inapp-evaluator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        history = InAppHistory(generation: { 1 }, directory: directory)
        evaluator = InAppEvaluator(
            history: history,
            installationSeed: { seed },
            appVersion: "2.4.0",
            locales: { [Locale(identifier: "und")] },
            now: { [clock] in clock.value }
        )
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func variant(id: String = "default", allocation: Int = 100) -> InAppContentVariant {
        InAppContentVariant(
            id: id,
            key: nil,
            locale: "und",
            allocationPercentage: allocation,
            type: .scene,
            payload: ["card": .object([:])],
            presentation: .embedded(EmbeddedPresentation(
                placementKey: "home.hero",
                emptyState: .collapse
            ))
        )
    }

    func campaign(
        triggers: [InAppTrigger] = [],
        displayPolicy: InAppDisplayPolicy = InAppDisplayPolicy(
            maxTotalImpressions: nil,
            maxImpressionsPerSession: nil,
            maxImpressionsPerDay: nil,
            cooldownMinutes: nil,
            redisplayAfterDismissal: true
        ),
        variants: [InAppContentVariant]? = nil
    ) -> InAppCampaign {
        InAppCampaign(
            key: experienceId,
            revision: 1,
            experienceId: experienceId,
            messageId: "\(experienceId):1",
            publishedAt: clock.value.addingTimeInterval(-100),
            availableAt: nil,
            expiresAt: nil,
            triggers: triggers,
            startAt: nil,
            endAt: nil,
            priority: 10,
            conflictPolicy: .queue,
            displayPolicy: displayPolicy,
            defaultLocale: "und",
            fallbackLocale: nil,
            variants: variants ?? [variant()],
            oneShot: false
        )
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var timestamp: Date
    init(_ timestamp: Date) { self.timestamp = timestamp }
    var value: Date { lock.lock(); defer { lock.unlock() }; return timestamp }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); timestamp = timestamp.addingTimeInterval(seconds); lock.unlock()
    }
}

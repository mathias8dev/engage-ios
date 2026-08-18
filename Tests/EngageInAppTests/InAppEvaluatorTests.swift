import XCTest
import EngageCore
@_spi(Modules) import EngageCore
@testable import EngageInApp

final class InAppEvaluatorTests: XCTestCase {
    func testWipeIsDurableBeforeReturning() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engage-inapp-wipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = InAppHistory(generation: { 1 }, directory: directory)
        history.recordImpression("campaign", at: Date(timeIntervalSince1970: 1_800_000_000))

        try history.clearAll()

        let reloaded = InAppHistory(generation: { 1 }, directory: directory)
        XCTAssertEqual(reloaded.history("campaign").total, 0)
    }

    func testWipePropagatesDeletionFailureWithoutClaimingMemoryWasCleared() throws {
        enum ExpectedFailure: Error { case disk }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engage-inapp-wipe-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = InAppHistory(
            generation: { 1 },
            directory: directory,
            removeItem: { _ in throw ExpectedFailure.disk }
        )
        history.recordImpression("campaign", at: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertThrowsError(try history.clearAll())

        XCTAssertEqual(history.history("campaign").total, 1)
    }

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

    func testTriggerEventPropertiesOverrideAuthoredPersonalizationDefaultsAtDisplayTime() throws {
        let fixture = try Fixture(seed: "seed", experienceId: "purchase-message")
        let trigger = InAppTrigger(
            id: "purchase",
            type: .event,
            delaySeconds: 0,
            screenName: nil,
            eventName: "purchase",
            minimumSessions: nil,
            versionConstraint: nil
        )
        let variant = fixture.variant(payload: [
            "text": .object(["$engageValue": .string("event.amount")]),
            "currency": .object(["$engageValue": .string("event.order.currency")]),
            "total": .object(["$engageValue": .string("event.order.total")]),
        ])
        fixture.evaluator.replaceCampaigns([
            fixture.campaign(
                triggers: [trigger],
                variants: [variant],
                personalization: InAppPersonalizationContext(fallbacks: [
                    "event": .object([
                        "amount": .string("fallback"),
                        "order": .object([
                            "currency": .string("EUR"),
                            "total": .string("fallback"),
                        ]),
                    ]),
                ])
            ),
        ])

        fixture.evaluator.onSignal(.event("purchase", [
            "amount": .string("42 €"),
            "order": .object(["total": .string("42")]),
        ]))

        let payload = fixture.evaluator.candidates().first?.publicContent.payload
        XCTAssertEqual(payload?["text"], .string("42 €"))
        XCTAssertEqual(payload?["currency"], .string("EUR"))
        XCTAssertEqual(payload?["total"], .string("42"))
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
                "personalization": .object([
                    "values": .object([
                        "profile": .object(["first_name": .string("Ada")]),
                    ]),
                    "fallbacks": .object([
                        "profile": .object(["first_name": .string("friend")]),
                    ]),
                ]),
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
        XCTAssertEqual(
            campaign.personalization.values["profile"],
            .object(["first_name": .string("Ada")])
        )
        XCTAssertEqual(
            campaign.personalization.fallbacks["profile"],
            .object(["first_name": .string("friend")])
        )
    }

    func testEventOrScreenPreservesEventEligibilityAcrossScreenChanges() throws {
        let fixture = try Fixture(seed: "seed", experienceId: "mixed")
        let event = InAppTrigger(id: "purchase", type: .event, delaySeconds: 0, screenName: nil, eventName: "purchase", minimumSessions: nil, versionConstraint: nil)
        let screen = InAppTrigger(id: "checkout", type: .screenView, delaySeconds: 0, screenName: "checkout", eventName: nil, minimumSessions: nil, versionConstraint: nil)
        fixture.evaluator.replaceCampaigns([fixture.campaign(triggers: [screen, event])])
        fixture.evaluator.onSignal(.screenViewed("home"))
        fixture.evaluator.onSignal(.event("purchase", ["amount": .string("42")]))

        XCTAssertEqual(fixture.evaluator.candidates().first?.matchedTrigger?.id, "purchase")
        fixture.evaluator.onSignal(.screenViewed("checkout"))
        fixture.evaluator.onSignal(.screenCleared)
        XCTAssertEqual(fixture.evaluator.candidates().first?.matchedTrigger?.id, "purchase")
    }

    func testRuntimeTypeMismatchUsesTypedFallback() throws {
        let fixture = try Fixture(seed: "seed", experienceId: "typed")
        let trigger = InAppTrigger(id: "purchase", type: .event, delaySeconds: 0, screenName: nil, eventName: "purchase", minimumSessions: nil, versionConstraint: nil)
        let variant = fixture.variant(payload: [
            "font_size": .object(["$engageValue": .string("event.amount")]),
        ])
        fixture.evaluator.replaceCampaigns([fixture.campaign(
            triggers: [trigger],
            variants: [variant],
            personalization: InAppPersonalizationContext(fallbacks: [
                "event": .object(["amount": .integer(7)]),
            ])
        )])
        fixture.evaluator.onSignal(.event("purchase", ["amount": .string("large")]))

        XCTAssertEqual(fixture.evaluator.candidates().first?.payload["font_size"], .integer(7))
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

    func variant(
        id: String = "default",
        allocation: Int = 100,
        payload: EngagePayload = ["card": .object([:])]
    ) -> InAppContentVariant {
        InAppContentVariant(
            id: id,
            key: nil,
            locale: "und",
            allocationPercentage: allocation,
            type: .scene,
            payload: payload,
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
        variants: [InAppContentVariant]? = nil,
        personalization: InAppPersonalizationContext = InAppPersonalizationContext()
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
            personalization: personalization,
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

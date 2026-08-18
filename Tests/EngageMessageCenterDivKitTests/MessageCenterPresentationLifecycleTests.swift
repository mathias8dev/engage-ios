import XCTest
@testable import EngageMessageCenterDivKit
@_spi(Rendering) import EngageMessageCenter

final class MessageCenterPresentationLifecycleTests: XCTestCase {
    private let entryId = InboxEntryId("entry-1")

    func testIdentityTransitionInvalidatesAnAlreadyRequestedDetail() {
        XCTAssertTrue(shouldInvalidateMessageCenterDetail(
            entryId: entryId,
            expectedLifecycleRevision: 4,
            state: state(revision: 5),
            knownByInbox: false,
            rendered: false
        ))
    }

    func testKnownEntryRemovalInvalidatesItsRenderedDetail() {
        XCTAssertTrue(shouldInvalidateMessageCenterDetail(
            entryId: entryId,
            expectedLifecycleRevision: 4,
            state: state(entryIds: []),
            knownByInbox: true,
            rendered: true
        ))
    }

    func testColdDirectDetailMayResolveBeforeTheEntryIsPaged() {
        XCTAssertFalse(shouldInvalidateMessageCenterDetail(
            entryId: entryId,
            expectedLifecycleRevision: 4,
            state: state(entryIds: []),
            knownByInbox: false,
            rendered: false
        ))
    }

    func testPendingDeletionInvalidatesAColdDirectDetail() {
        XCTAssertTrue(shouldInvalidateMessageCenterDetail(
            entryId: entryId,
            expectedLifecycleRevision: 4,
            state: state(entryIds: [], deletedEntryIds: [entryId]),
            knownByInbox: false,
            rendered: true
        ))
    }

    func testPrivacyDisableInvalidatesOnlyRenderedContent() {
        XCTAssertFalse(shouldInvalidateMessageCenterDetail(
            entryId: entryId,
            expectedLifecycleRevision: 4,
            state: state(enabled: false),
            knownByInbox: false,
            rendered: false
        ))
        XCTAssertTrue(shouldInvalidateMessageCenterDetail(
            entryId: entryId,
            expectedLifecycleRevision: 4,
            state: state(enabled: false),
            knownByInbox: false,
            rendered: true
        ))
    }

    func testContentMustBeAtLeastHalfVisibleBeforeReadIsReported() {
        XCTAssertFalse(isMessageCenterContentVisible(visibleArea: 0, totalArea: 0))
        XCTAssertFalse(isMessageCenterContentVisible(visibleArea: 49, totalArea: 100))
        XCTAssertTrue(isMessageCenterContentVisible(visibleArea: 50, totalArea: 100))
        XCTAssertTrue(isMessageCenterContentVisible(visibleArea: 100, totalArea: 100))
    }

    private func state(
        revision: Int64 = 4,
        enabled: Bool = true,
        entryIds: Set<InboxEntryId>? = nil,
        deletedEntryIds: Set<InboxEntryId> = []
    ) -> MessageCenterPresentationState {
        MessageCenterPresentationState(
            lifecycleRevision: revision,
            generation: 7,
            isEnabled: enabled,
            entryIds: entryIds ?? [entryId],
            deletedEntryIds: deletedEntryIds
        )
    }
}

import XCTest
import EngageCore
@_spi(Rendering) @testable import EngageMessageCenter

final class EngageMessageCenterTests: XCTestCase {
    func testStandaloneModuleExposesPublicActivation() {
        let activate: () -> MessageCenter = MessageCenterModule.activate
        let shared: () -> MessageCenter = { MessageCenterModule.shared }
        _ = activate
        _ = shared
    }

    func testInboxEntryIsAFlatHeadlessPayload() {
        let entry = InboxEntry(
            id: InboxEntryId("entry-1"),
            key: "order_ready",
            payload: ["orderId": .string("order-42")],
            sentAt: Date(timeIntervalSince1970: 1),
            expiresAt: nil,
            readAt: nil
        )
        XCTAssertEqual(entry.payload.string("orderId"), "order-42")
    }

    func testOptimisticMutationIsSharedAndDurable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InboxStore(directory: directory)
        XCTAssertTrue(store.activate(3))
        XCTAssertTrue(store.savePage(
            generation: 3,
            pageSize: 20,
            cursor: nil,
            entries: [makeEntry(id: "message-1")],
            nextCursor: nil,
            hasMore: false,
            unreadCount: 1
        ))
        XCTAssertTrue(store.enqueue(InboxMutation(
            operationId: "read-1",
            generation: 3,
            type: "MARK_READ",
            entryId: "message-1",
            occurredAt: "2026-08-02T12:00:00Z",
            wasUnread: true
        )))

        XCTAssertNotNil(store.entry("message-1")?.readAt)
        XCTAssertEqual(store.unreadCount, 0)

        let reloaded = InboxStore(directory: directory)
        XCTAssertNotNil(reloaded.entry("message-1")?.readAt)
        XCTAssertEqual(reloaded.unreadCount, 0)
        XCTAssertEqual(reloaded.pending(generation: 3).map(\.operationId), ["read-1"])
    }

    func testRejectedMutationRollsBackBeforeItLeavesTheDurableQueue() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InboxStore(directory: directory)
        XCTAssertTrue(store.activate(3))
        XCTAssertTrue(store.savePage(
            generation: 3,
            pageSize: 20,
            cursor: nil,
            entries: [makeEntry(id: "message-1")],
            nextCursor: nil,
            hasMore: false,
            unreadCount: 1
        ))
        XCTAssertTrue(store.enqueue(InboxMutation(
            operationId: "read-rejected",
            generation: 3,
            type: "MARK_READ",
            entryId: "message-1",
            occurredAt: "2026-08-06T12:00:00Z",
            wasUnread: true
        )))
        XCTAssertNotNil(store.entry("message-1")?.readAt)

        XCTAssertTrue(store.settle(accepted: [], rejected: ["read-rejected"]))

        XCTAssertNil(store.entry("message-1")?.readAt)
        XCTAssertEqual(store.unreadCount, 1)
        let reloaded = InboxStore(directory: directory)
        XCTAssertNil(reloaded.entry("message-1")?.readAt)
        XCTAssertTrue(reloaded.pending(generation: 3).isEmpty)
    }

    func testRejectedDeleteRestoresEntryWindowAndRendering() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InboxStore(directory: directory)
        XCTAssertTrue(store.activate(4))
        XCTAssertTrue(store.savePage(
            generation: 4,
            pageSize: 20,
            cursor: nil,
            entries: [makeEntry(id: "message-1")],
            nextCursor: nil,
            hasMore: false,
            unreadCount: 1
        ))
        XCTAssertTrue(store.saveRenderings([
            InboxRenderingSnapshot(
                entryId: InboxEntryId("message-1"),
                renderer: .divKit,
                revision: 2,
                surfaces: renderingSurfaces()
            ),
        ], generation: 4))
        XCTAssertTrue(store.enqueue(InboxMutation(
            operationId: "delete-rejected",
            generation: 4,
            type: "DELETE",
            entryId: "message-1",
            occurredAt: "2026-08-06T12:00:00Z",
            wasUnread: true
        )))
        XCTAssertNil(store.entry("message-1"))

        XCTAssertTrue(store.settle(accepted: [], rejected: ["delete-rejected"]))

        XCTAssertNotNil(store.entry("message-1"))
        XCTAssertEqual(store.cachedWindow(pageSize: 20).entryIds, ["message-1"])
        XCTAssertEqual(store.cachedRenderings([InboxEntryId("message-1")]).first?.revision, 2)
    }

    func testRejectedMutationDoesNotUndoALaterAcceptedMutation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InboxStore(directory: directory)
        XCTAssertTrue(store.activate(5))
        XCTAssertTrue(store.savePage(
            generation: 5,
            pageSize: 20,
            cursor: nil,
            entries: [makeEntry(id: "message-1")],
            nextCursor: nil,
            hasMore: false,
            unreadCount: 1
        ))
        XCTAssertTrue(store.enqueue(InboxMutation(
            operationId: "read-rejected",
            generation: 5,
            type: "MARK_READ",
            entryId: "message-1",
            occurredAt: "2026-08-06T12:00:00Z",
            wasUnread: true
        )))
        XCTAssertTrue(store.enqueue(InboxMutation(
            operationId: "delete-accepted",
            generation: 5,
            type: "DELETE",
            entryId: "message-1",
            occurredAt: "2026-08-06T12:00:01Z",
            wasUnread: false
        )))

        XCTAssertTrue(store.settle(
            accepted: ["delete-accepted"],
            rejected: ["read-rejected"]
        ))

        XCTAssertNil(store.entry("message-1"))
        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertTrue(store.pending(generation: 5).isEmpty)
    }

    func testCachedWindowAndRenderingSurviveRestartButGenerationDoesNotLeak() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InboxStore(directory: directory)
        XCTAssertTrue(store.activate(8))
        XCTAssertTrue(store.savePage(
            generation: 8,
            pageSize: 2,
            cursor: nil,
            entries: [makeEntry(id: "a"), makeEntry(id: "b")],
            nextCursor: "next",
            hasMore: true,
            unreadCount: 2
        ))
        XCTAssertTrue(store.saveRenderings([
            InboxRenderingSnapshot(
                entryId: InboxEntryId("a"),
                renderer: .divKit,
                revision: 11,
                surfaces: renderingSurfaces()
            ),
        ], generation: 8))

        let reloaded = InboxStore(directory: directory)
        XCTAssertEqual(reloaded.cachedWindow(pageSize: 2).entryIds, ["a", "b"])
        let restoredRendering = reloaded.cachedRenderings([InboxEntryId("a")]).first
        XCTAssertEqual(restoredRendering?.revision, 11)
        XCTAssertEqual(restoredRendering?.surfaces[.summary]?.string("card"), "summary")
        XCTAssertEqual(restoredRendering?.surfaces[.detail]?.string("card"), "detail")

        XCTAssertTrue(reloaded.activate(9))
        XCTAssertTrue(reloaded.entries().isEmpty)
        XCTAssertTrue(reloaded.cachedWindow(pageSize: 2).entryIds.isEmpty)
        XCTAssertTrue(reloaded.cachedRenderings([InboxEntryId("a")]).isEmpty)
    }

    func testDirectRenderingCanBeCachedWithoutPagingAndExpiresLocally() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InboxStore(directory: directory)
        XCTAssertTrue(store.activate(10))
        let directId = InboxEntryId("direct-entry")
        XCTAssertTrue(store.saveRenderings([
            InboxRenderingSnapshot(
                entryId: directId,
                renderer: .divKit,
                revision: 1,
                surfaces: renderingSurfaces(),
                expiresAt: Date(timeIntervalSinceNow: 3_600)
            ),
        ], generation: 10))
        XCTAssertEqual(store.cachedRenderings([directId]).map(\.entryId), [directId])

        let expiredId = InboxEntryId("expired-direct-entry")
        XCTAssertTrue(store.saveRenderings([
            InboxRenderingSnapshot(
                entryId: expiredId,
                renderer: .divKit,
                revision: 1,
                surfaces: renderingSurfaces(),
                expiresAt: Date(timeIntervalSince1970: 1)
            ),
        ], generation: 10))
        XCTAssertTrue(store.cachedRenderings([expiredId]).isEmpty)
    }

    func testUncachedPendingDeletionIsExposedToPresentationConsumers() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InboxStore(directory: directory)
        XCTAssertTrue(store.activate(7))

        XCTAssertTrue(store.enqueue(InboxMutation(
            operationId: "delete-direct",
            generation: 7,
            type: "DELETE",
            entryId: "direct-entry",
            occurredAt: "2026-08-18T12:00:00Z",
            wasUnread: nil
        )))

        XCTAssertEqual(store.pendingDeletedEntryIds, [InboxEntryId("direct-entry")])
    }

    func testStaleGenerationCannotPersistPageRenderingOrMutation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InboxStore(directory: directory)
        XCTAssertTrue(store.activate(10))

        XCTAssertFalse(store.savePage(
            generation: 9,
            pageSize: 20,
            cursor: nil,
            entries: [makeEntry(id: "stale-entry")],
            nextCursor: nil,
            hasMore: false,
            unreadCount: 1
        ))
        XCTAssertFalse(store.saveRenderings([
            InboxRenderingSnapshot(
                entryId: InboxEntryId("stale-entry"),
                renderer: .divKit,
                revision: 1,
                surfaces: renderingSurfaces()
            ),
        ], generation: 9))
        XCTAssertFalse(store.enqueue(InboxMutation(
            operationId: "stale-operation",
            generation: 9,
            type: "MARK_READ",
            entryId: "stale-entry",
            occurredAt: "2026-08-18T12:00:00Z",
            wasUnread: true
        )))

        XCTAssertTrue(store.entries().isEmpty)
        XCTAssertTrue(store.cachedRenderings([InboxEntryId("stale-entry")]).isEmpty)
        XCTAssertTrue(store.pending(generation: 9).isEmpty)
    }

    func testFailedPersistenceDoesNotExposeAnOptimisticMutation() {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engage-inbox-missing-\(UUID().uuidString)", isDirectory: true)
        let store = InboxStore(directory: missingDirectory)

        XCTAssertFalse(store.activate(4))
        XCTAssertEqual(store.generation, 0)
        XCTAssertTrue(store.entries().isEmpty)
        XCTAssertTrue(store.pending(generation: 4).isEmpty)
    }

    func testCachedWindowsAreIsolatedBySortOrder() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InboxStore(directory: directory)
        XCTAssertTrue(store.activate(4))
        XCTAssertTrue(store.savePage(
            generation: 4,
            pageSize: 20,
            cursor: nil,
            entries: [makeEntry(id: "newest")],
            nextCursor: nil,
            hasMore: false,
            unreadCount: 1,
            sortOrder: .newestFirst
        ))
        XCTAssertTrue(store.savePage(
            generation: 4,
            pageSize: 20,
            cursor: nil,
            entries: [makeEntry(id: "oldest")],
            nextCursor: nil,
            hasMore: false,
            unreadCount: 1,
            sortOrder: .oldestFirst
        ))

        XCTAssertEqual(store.cachedWindow(pageSize: 20, sortOrder: .newestFirst).entryIds, ["newest"])
        XCTAssertEqual(store.cachedWindow(pageSize: 20, sortOrder: .oldestFirst).entryIds, ["oldest"])
    }

    private func makeEntry(id: String, readAt: Date? = nil) -> InboxEntry {
        InboxEntry(
            id: InboxEntryId(id),
            key: "receipt",
            payload: ["title": .string(id)],
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil,
            readAt: readAt
        )
    }

    private func renderingSurfaces() -> [InboxRenderingSurface: EngagePayload] {
        [
            .summary: ["card": .string("summary")],
            .detail: ["card": .string("detail")],
        ]
    }

    private func temporaryDirectory() throws -> URL {
        let value = FileManager.default.temporaryDirectory
            .appendingPathComponent("engage-inbox-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
}

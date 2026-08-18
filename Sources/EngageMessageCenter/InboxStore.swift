import Foundation
import EngageCore
@_spi(Modules) import EngageCore

private struct StoredInbox: Codable {
    var generation: Int64 = 0
    var entries: [String: InboxEntry] = [:]
    var unreadCount = 0
    var mutations: [InboxMutation] = []
    var windows: [String: StoredInboxWindow] = [:]
    var renderings: [String: StoredRendering] = [:]
}

struct StoredInboxWindow: Codable, Sendable {
    var entryIds: [String]
    var nextCursor: String?
    var hasMore: Bool
}

struct StoredRendering: Codable, Sendable {
    let renderer: InboxRenderer
    let revision: Int64
    let surfaces: [InboxRenderingSurface: EngagePayload]
    let expiresAt: Date?
}

struct InboxMutation: Codable, Sendable {
    let operationId: String
    let generation: Int64
    let type: String
    let entryId: String?
    let occurredAt: String
    let wasUnread: Bool?
    let rollbackEntry: InboxEntry?
    let rollbackUnreadEntryIds: [String]?
    let rollbackUnreadCount: Int?
    let rollbackRendering: StoredRendering?
    let rollbackWindows: [String: StoredInboxWindow]?

    init(
        operationId: String,
        generation: Int64,
        type: String,
        entryId: String?,
        occurredAt: String,
        wasUnread: Bool?,
        rollbackEntry: InboxEntry? = nil,
        rollbackUnreadEntryIds: [String]? = nil,
        rollbackUnreadCount: Int? = nil,
        rollbackRendering: StoredRendering? = nil,
        rollbackWindows: [String: StoredInboxWindow]? = nil
    ) {
        self.operationId = operationId
        self.generation = generation
        self.type = type
        self.entryId = entryId
        self.occurredAt = occurredAt
        self.wasUnread = wasUnread
        self.rollbackEntry = rollbackEntry
        self.rollbackUnreadEntryIds = rollbackUnreadEntryIds
        self.rollbackUnreadCount = rollbackUnreadCount
        self.rollbackRendering = rollbackRendering
        self.rollbackWindows = rollbackWindows
    }
}

struct CachedInboxWindow: Sendable {
    let entryIds: [String]
    let nextCursor: String?
    let hasMore: Bool
}

final class InboxStore: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var stored: StoredInbox
    let revision = EngageState<Int64>(0)

    init(directory: URL = engageMessageCenterDirectory()) {
        url = directory.appendingPathComponent("inbox.json")
        stored = (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode(StoredInbox.self, from: $0)
        } ?? StoredInbox()
        purgeExpiredLocked(now: Date())
        EngageLogger.info(
            "MessageCenter.Store",
            "loaded generation=\(stored.generation) entries=\(stored.entries.count) unread=\(stored.unreadCount) " +
                "mutations=\(stored.mutations.count) renderings=\(stored.renderings.count)"
        )
    }

    var generation: Int64 { locked { stored.generation } }
    var unreadCount: Int { locked { stored.unreadCount } }
    var pendingDeletedEntryIds: Set<InboxEntryId> { locked {
        Set(stored.mutations.compactMap { mutation in
            guard mutation.generation == stored.generation,
                  mutation.type == "DELETE",
                  let entryId = mutation.entryId else { return nil }
            return InboxEntryId(entryId)
        })
    } }

    func entries(ids: [String]? = nil, now: Date = Date()) -> [InboxEntry] {
        let values: [InboxEntry] = locked {
            let values = ids.map { $0.compactMap { stored.entries[$0] } }
                ?? Array(stored.entries.values).sorted {
                    ($0.sentAt, $0.id.value) > ($1.sentAt, $1.id.value)
                }
            return values.filter { $0.expiresAt.map { $0 > now } ?? true }
        }
        EngageLogger.verbose("MessageCenter.Store", "entries read requested=\(ids?.count ?? -1) returned=\(values.count)")
        return values
    }

    @discardableResult
    func activate(_ generation: Int64) -> Bool {
        EngageLogger.debug("MessageCenter.Store", "generation activating generation=\(generation)")
        return mutate {
            if stored.generation != generation {
                stored = StoredInbox(generation: generation)
            } else {
                purgeExpiredLocked(now: Date())
            }
        }
    }

    @discardableResult
    func savePage(
        generation: Int64,
        pageSize: Int,
        cursor: String?,
        entries: [InboxEntry],
        nextCursor: String?,
        hasMore: Bool,
        unreadCount: Int,
        sortOrder: InboxSortOrder = .newestFirst
    ) -> Bool {
        EngageLogger.debug(
            "MessageCenter.Store",
            "page saving generation=\(generation) pageSize=\(pageSize) hasCursor=\(cursor != nil) " +
                "entries=\(entries.count) hasMore=\(hasMore) unread=\(unreadCount)"
        )
        return mutateIf {
            guard stored.generation == generation else { return false }
            entries.forEach { remote in
                if stored.mutations.contains(where: {
                    $0.type == "DELETE" && $0.entryId == remote.id.value
                }) {
                    stored.entries[remote.id.value] = nil
                } else {
                    stored.entries[remote.id.value] = merge(remote: remote, pending: stored.mutations)
                }
            }
            stored.unreadCount = projectedUnreadCount(server: unreadCount, pending: stored.mutations)

            let key = windowKey(pageSize: pageSize, sortOrder: sortOrder)
            let incoming = entries.map { $0.id.value }
            if cursor == nil {
                stored.windows[key] = StoredInboxWindow(
                    entryIds: incoming,
                    nextCursor: nextCursor,
                    hasMore: hasMore
                )
            } else {
                var window = stored.windows[key] ?? StoredInboxWindow(
                    entryIds: [], nextCursor: cursor, hasMore: true
                )
                for id in incoming where !window.entryIds.contains(id) { window.entryIds.append(id) }
                window.nextCursor = nextCursor
                window.hasMore = hasMore
                stored.windows[key] = window
            }
            purgeExpiredLocked(now: Date())
            return true
        }
    }

    func cachedWindow(pageSize: Int, sortOrder: InboxSortOrder = .newestFirst) -> CachedInboxWindow {
        mutate { purgeExpiredLocked(now: Date()) }
        let cached = locked {
            let window = stored.windows[windowKey(pageSize: pageSize, sortOrder: sortOrder)]
            return CachedInboxWindow(
                entryIds: window?.entryIds.filter { stored.entries[$0] != nil } ?? [],
                nextCursor: window?.nextCursor,
                hasMore: window?.hasMore ?? false
            )
        }
        EngageLogger.debug(
            "MessageCenter.Store",
            "cached window read pageSize=\(pageSize) entries=\(cached.entryIds.count) hasMore=\(cached.hasMore)"
        )
        return cached
    }

    private func windowKey(pageSize: Int, sortOrder: InboxSortOrder) -> String {
        "\(pageSize):\(sortOrder.rawValue)"
    }

    @discardableResult
    func enqueue(_ mutation: InboxMutation) -> Bool {
        EngageLogger.debug(
            "MessageCenter.Store",
            "mutation persisting operationId=\(mutation.operationId) generation=\(mutation.generation) " +
                "type=\(mutation.type) entryId=\(mutation.entryId ?? "none")"
        )
        return mutateIf {
            guard stored.generation == mutation.generation,
                  !stored.mutations.contains(where: { $0.operationId == mutation.operationId }) else { return false }
            let captured = InboxMutation(
                operationId: mutation.operationId,
                generation: mutation.generation,
                type: mutation.type,
                entryId: mutation.entryId,
                occurredAt: mutation.occurredAt,
                wasUnread: mutation.wasUnread,
                rollbackEntry: mutation.entryId.flatMap { stored.entries[$0] },
                rollbackUnreadEntryIds: mutation.type == "MARK_ALL_READ"
                    ? stored.entries.values.filter { $0.readAt == nil }.map { $0.id.value }
                    : nil,
                rollbackUnreadCount: stored.unreadCount,
                rollbackRendering: mutation.entryId.flatMap { stored.renderings[$0] },
                rollbackWindows: mutation.type == "DELETE" ? stored.windows : nil
            )
            stored.mutations.append(captured)
            applyOptimistic(captured)
            return true
        }
    }

    func pending(generation: Int64) -> [InboxMutation] {
        let values = locked { stored.mutations.filter { $0.generation == generation }.prefix(100).map { $0 } }
        EngageLogger.verbose("MessageCenter.Store", "pending mutations read generation=\(generation) count=\(values.count)")
        return values
    }

    @discardableResult
    func settle(ids: Set<String>) -> Bool {
        EngageLogger.debug("MessageCenter.Store", "mutations settling count=\(ids.count)")
        return mutate { stored.mutations.removeAll { ids.contains($0.operationId) } }
    }

    @discardableResult
    func settle(accepted: Set<String>, rejected: Set<String>) -> Bool {
        EngageLogger.debug(
            "MessageCenter.Store",
            "mutations settling accepted=\(accepted.count) rejected=\(rejected.count)"
        )
        return mutate {
            let completed = accepted.union(rejected)
            guard !rejected.isEmpty else {
                stored.mutations.removeAll { completed.contains($0.operationId) }
                return
            }
            let original = stored.mutations
            original.reversed().forEach {
                rollback($0, reportRejection: rejected.contains($0.operationId))
            }
            stored.mutations = original.filter { !completed.contains($0.operationId) }
            original
                .filter { !rejected.contains($0.operationId) }
                .forEach { applyOptimistic($0) }
        }
    }

    func contains(_ id: String) -> Bool { locked { stored.entries[id] != nil } }
    func entry(_ id: String) -> InboxEntry? { locked { stored.entries[id] } }

    func cachedRenderings(_ ids: [InboxEntryId]) -> [InboxRenderingSnapshot] {
        let now = Date()
        let hasExpiredRendering = locked {
            stored.renderings.values.contains { $0.expiresAt.map { $0 <= now } ?? false }
        }
        if hasExpiredRendering {
            mutate { purgeExpiredLocked(now: now) }
        }
        let values: [InboxRenderingSnapshot] = locked {
            ids.compactMap { id -> InboxRenderingSnapshot? in
                guard let value = stored.renderings[id.value] else { return nil }
                return InboxRenderingSnapshot(
                    entryId: id,
                    renderer: value.renderer,
                    revision: value.revision,
                    surfaces: value.surfaces,
                    expiresAt: value.expiresAt
                )
            }
        }
        EngageLogger.debug("MessageCenter.Store", "rendering cache read requested=\(ids.count) hits=\(values.count)")
        return values
    }

    @discardableResult
    func saveRenderings(_ values: [InboxRenderingSnapshot], generation: Int64) -> Bool {
        EngageLogger.debug("MessageCenter.Store", "renderings saving count=\(values.count)")
        return mutateIf {
            guard stored.generation == generation else { return false }
            for value in values {
                let current = stored.renderings[value.entryId.value]
                if current == nil || current!.revision <= value.revision {
                    stored.renderings[value.entryId.value] = StoredRendering(
                        renderer: value.renderer,
                        revision: value.revision,
                        surfaces: value.surfaces,
                        expiresAt: value.expiresAt
                    )
                }
            }
            return true
        }
    }

    func wipe() throws {
        EngageLogger.warning("MessageCenter.Store", "wipe started")
        guard mutate({ stored = StoredInbox() }) else { throw InboxStoreError.persistenceFailed }
        EngageLogger.warning("MessageCenter.Store", "wipe completed")
    }

    private func applyOptimistic(_ mutation: InboxMutation) {
        EngageLogger.verbose(
            "MessageCenter.Store",
            "optimistic mutation applying operationId=\(mutation.operationId) type=\(mutation.type) " +
                "entryId=\(mutation.entryId ?? "none")"
        )
        if mutation.type == "MARK_ALL_READ" {
            stored.entries = stored.entries.mapValues { replace($0, readAt: Date()) }
            stored.unreadCount = 0
            return
        }
        guard let id = mutation.entryId, let entry = stored.entries[id] else { return }
        switch mutation.type {
        case "MARK_READ":
            if entry.readAt == nil { stored.unreadCount = max(0, stored.unreadCount - 1) }
            stored.entries[id] = replace(entry, readAt: Date())
        case "MARK_UNREAD":
            if entry.readAt != nil { stored.unreadCount += 1 }
            stored.entries[id] = replace(entry, readAt: nil)
        case "DELETE":
            if entry.readAt == nil { stored.unreadCount = max(0, stored.unreadCount - 1) }
            stored.entries[id] = nil
            stored.renderings[id] = nil
            stored.windows = stored.windows.mapValues { window in
                var value = window
                value.entryIds.removeAll { $0 == id }
                return value
            }
        default:
            break
        }
    }

    private func rollback(_ mutation: InboxMutation, reportRejection: Bool) {
        if reportRejection {
            EngageLogger.warning(
                "MessageCenter.Store",
                "optimistic mutation rolling back operationId=\(mutation.operationId) type=\(mutation.type)"
            )
        }
        switch mutation.type {
        case "MARK_READ", "MARK_UNREAD":
            if let entry = mutation.rollbackEntry { stored.entries[entry.id.value] = entry }
        case "MARK_ALL_READ":
            for id in mutation.rollbackUnreadEntryIds ?? [] {
                if let entry = stored.entries[id] { stored.entries[id] = replace(entry, readAt: nil) }
            }
        case "DELETE":
            if let entry = mutation.rollbackEntry { stored.entries[entry.id.value] = entry }
            if let id = mutation.entryId { stored.renderings[id] = mutation.rollbackRendering }
            if let windows = mutation.rollbackWindows { stored.windows = windows }
        default:
            break
        }
        if let unreadCount = mutation.rollbackUnreadCount { stored.unreadCount = unreadCount }
    }

    private func merge(remote: InboxEntry, pending: [InboxMutation]) -> InboxEntry {
        var value = remote
        for mutation in pending where mutation.entryId == remote.id.value || mutation.type == "MARK_ALL_READ" {
            switch mutation.type {
            case "MARK_READ", "MARK_ALL_READ": value = replace(value, readAt: value.readAt ?? Date())
            case "MARK_UNREAD": value = replace(value, readAt: nil)
            case "DELETE": return value
            default: break
            }
        }
        return value
    }

    private func projectedUnreadCount(server: Int, pending: [InboxMutation]) -> Int {
        var value = max(0, server)
        for mutation in pending {
            switch mutation.type {
            case "MARK_ALL_READ": value = 0
            case "MARK_READ" where mutation.wasUnread == true,
                 "DELETE" where mutation.wasUnread == true:
                value = max(0, value - 1)
            case "MARK_UNREAD" where mutation.wasUnread == false: value += 1
            default: break
            }
        }
        return value
    }

    private func purgeExpiredLocked(now: Date) {
        let expired = Set(stored.entries.values.compactMap { entry in
            entry.expiresAt.map { $0 <= now ? entry.id.value : nil } ?? nil
        })
        if !expired.isEmpty {
            EngageLogger.info("MessageCenter.Store", "expired entries purging count=\(expired.count)")
            for id in expired {
                if stored.entries[id]?.readAt == nil { stored.unreadCount = max(0, stored.unreadCount - 1) }
                stored.entries[id] = nil
                stored.renderings[id] = nil
            }
        }
        let expiredRenderings = stored.renderings.compactMap { id, rendering in
            rendering.expiresAt.map { $0 <= now ? id : nil } ?? nil
        }
        if !expiredRenderings.isEmpty {
            EngageLogger.info(
                "MessageCenter.Store",
                "expired direct renderings purging count=\(expiredRenderings.count)"
            )
        }
        expiredRenderings.forEach { stored.renderings[$0] = nil }
        stored.windows = stored.windows.mapValues { window in
            var value = window
            value.entryIds.removeAll { expired.contains($0) }
            return value
        }
    }

    private func replace(_ value: InboxEntry, readAt: Date?) -> InboxEntry {
        InboxEntry(
            id: value.id,
            key: value.key,
            payload: value.payload,
            sentAt: value.sentAt,
            expiresAt: value.expiresAt,
            readAt: readAt
        )
    }

    @discardableResult
    private func mutate(_ operation: () -> Void) -> Bool {
        lock.lock()
        let previous = stored
        operation()
        do {
            try persist()
        } catch {
            stored = previous
            lock.unlock()
            EngageLogger.error("MessageCenter.Store", "mutation persistence failed", error: error)
            return false
        }
        let next = revision.value + 1
        lock.unlock()
        revision.set(next)
        EngageLogger.verbose(
            "MessageCenter.Store",
            "mutation persisted revision=\(next) generation=\(stored.generation) entries=\(stored.entries.count) " +
                "unread=\(stored.unreadCount) pending=\(stored.mutations.count)"
        )
        return true
    }

    @discardableResult
    private func mutateIf(_ operation: () -> Bool) -> Bool {
        lock.lock()
        let previous = stored
        guard operation() else {
            lock.unlock()
            return false
        }
        do {
            try persist()
        } catch {
            stored = previous
            lock.unlock()
            EngageLogger.error("MessageCenter.Store", "mutation persistence failed", error: error)
            return false
        }
        let next = revision.value + 1
        lock.unlock()
        revision.set(next)
        EngageLogger.verbose(
            "MessageCenter.Store",
            "mutation persisted revision=\(next) generation=\(stored.generation) entries=\(stored.entries.count) " +
                "unread=\(stored.unreadCount) pending=\(stored.mutations.count)"
        )
        return true
    }

    private func locked<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(stored)
        try data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        EngageLogger.verbose("MessageCenter.Store", "file persisted bytes=\(data.count)")
    }
}

enum InboxStoreError: Error { case persistenceFailed }

func engageMessageCenterDirectory() -> URL {
    let manager = FileManager.default
    let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? manager.temporaryDirectory
    let directory = base.appendingPathComponent("io.engage.sdk", isDirectory: true)
    try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

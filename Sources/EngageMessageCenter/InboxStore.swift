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

private struct StoredInboxWindow: Codable {
    var entryIds: [String]
    var nextCursor: String?
    var hasMore: Bool
}

private struct StoredRendering: Codable {
    let renderer: String
    let revision: Int64
    let document: EngagePayload
}

struct InboxMutation: Codable, Sendable {
    let operationId: String
    let generation: Int64
    let type: String
    let entryId: String?
    let occurredAt: String
    let wasUnread: Bool?
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
    }

    var generation: Int64 { locked { stored.generation } }
    var unreadCount: Int { locked { stored.unreadCount } }

    func entries(ids: [String]? = nil, now: Date = Date()) -> [InboxEntry] {
        return locked {
            let values = ids.map { $0.compactMap { stored.entries[$0] } }
                ?? Array(stored.entries.values).sorted {
                    ($0.sentAt, $0.id.value) > ($1.sentAt, $1.id.value)
                }
            return values.filter { $0.expiresAt.map { $0 > now } ?? true }
        }
    }

    @discardableResult
    func activate(_ generation: Int64) -> Bool {
        mutate {
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
        unreadCount: Int
    ) -> Bool {
        mutate {
            guard stored.generation == generation else { return }
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

            let key = String(pageSize)
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
        }
    }

    func cachedWindow(pageSize: Int) -> CachedInboxWindow {
        mutate { purgeExpiredLocked(now: Date()) }
        return locked {
            let window = stored.windows[String(pageSize)]
            return CachedInboxWindow(
                entryIds: window?.entryIds.filter { stored.entries[$0] != nil } ?? [],
                nextCursor: window?.nextCursor,
                hasMore: window?.hasMore ?? false
            )
        }
    }

    @discardableResult
    func enqueue(_ mutation: InboxMutation) -> Bool {
        mutate {
            guard stored.generation == mutation.generation,
                  !stored.mutations.contains(where: { $0.operationId == mutation.operationId }) else { return }
            stored.mutations.append(mutation)
            applyOptimistic(mutation)
        }
    }

    func pending(generation: Int64) -> [InboxMutation] {
        locked { stored.mutations.filter { $0.generation == generation }.prefix(100).map { $0 } }
    }

    @discardableResult
    func settle(ids: Set<String>) -> Bool {
        mutate { stored.mutations.removeAll { ids.contains($0.operationId) } }
    }

    func contains(_ id: String) -> Bool { locked { stored.entries[id] != nil } }
    func entry(_ id: String) -> InboxEntry? { locked { stored.entries[id] } }

    func cachedRenderings(_ ids: [InboxEntryId]) -> [InboxRenderingSnapshot] {
        locked {
            ids.compactMap { id in
                guard let value = stored.renderings[id.value] else { return nil }
                return InboxRenderingSnapshot(
                    entryId: id,
                    renderer: value.renderer,
                    revision: value.revision,
                    document: value.document
                )
            }
        }
    }

    @discardableResult
    func saveRenderings(_ values: [InboxRenderingSnapshot]) -> Bool {
        mutate {
            for value in values {
                guard stored.entries[value.entryId.value] != nil else { continue }
                let current = stored.renderings[value.entryId.value]
                if current == nil || current!.revision <= value.revision {
                    stored.renderings[value.entryId.value] = StoredRendering(
                        renderer: value.renderer,
                        revision: value.revision,
                        document: value.document
                    )
                }
            }
        }
    }

    func wipe() throws {
        guard mutate({ stored = StoredInbox() }) else { throw InboxStoreError.persistenceFailed }
    }

    private func applyOptimistic(_ mutation: InboxMutation) {
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
        guard !expired.isEmpty else { return }
        for id in expired {
            if stored.entries[id]?.readAt == nil { stored.unreadCount = max(0, stored.unreadCount - 1) }
            stored.entries[id] = nil
            stored.renderings[id] = nil
        }
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
            return false
        }
        let next = revision.value + 1
        lock.unlock()
        revision.set(next)
        return true
    }

    private func locked<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    private func persist() throws {
        try JSONEncoder().encode(stored).write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
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

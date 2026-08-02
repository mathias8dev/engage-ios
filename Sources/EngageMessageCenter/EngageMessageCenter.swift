import Foundation
import EngageCore
@_spi(Modules) import EngageCore

public final class MessageCenter: @unchecked Sendable {
    public let inbox: Inbox

    init(context: EngageModuleContext) {
        inbox = Inbox(context: context)
        context.register(
            EngageModuleRegistration(
                id: "engage-message-center",
                features: [.messageCenter],
                syncModules: [],
                wipe: { [weak inbox] in try inbox?.wipe() }
            )
        )
    }

    @_spi(Rendering) public func resolveRenderings(
        _ ids: [InboxEntryId]
    ) async throws -> [InboxRenderingSnapshot] {
        try await inbox.resolveRenderings(ids)
    }

    @_spi(Rendering) public func executeAction(
        _ name: String,
        arguments: EngagePayload
    ) async -> Bool {
        await inbox.context.executeAction(name, arguments: arguments)
    }
}

public final class Inbox: @unchecked Sendable {
    let context: EngageModuleContext
    private let store: InboxStore
    private let flushGate = AsyncGate()
    private let pageTasks = PageTaskRegistry()
    private let registryLock = NSLock()
    private var pagers: [UUID: WeakPager] = [:]
    private var activeGeneration: Int64
    private var expiryTask: Task<Void, Never>?
    private var mutationRetryTask: Task<Void, Never>?
    private var mutationRetryId: UUID?

    public let unreadCount: EngageState<Int>
    fileprivate let enabled = EngageState(false)
    fileprivate let globalError = EngageState<InboxError?>(nil)

    init(context: EngageModuleContext, store: InboxStore = InboxStore()) {
        self.context = context
        self.store = store
        if !context.installationActive.value { try? store.wipe() }
        activeGeneration = context.generation.value
        store.activate(activeGeneration)
        unreadCount = EngageState(0)

        let runtimeChanged: @Sendable () -> Void = { [weak self] in self?.updateRuntimeState() }
        Task { for await _ in context.generation.updates { runtimeChanged() } }
        Task { for await _ in context.installationId.updates { runtimeChanged() } }
        Task { for await _ in context.privacy.updates { runtimeChanged() } }
        Task { for await _ in context.enabledFeatures.updates { runtimeChanged() } }
        Task { [weak self] in
            guard let self else { return }
            for await _ in store.revision.updates {
                updateUnreadCount()
                scheduleExpiry()
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for await signal in context.signals.events {
                switch signal {
                case .appOpened, .networkAvailable:
                    catchUp()
                case .localDataWiped:
                    try? wipe()
                default:
                    break
                }
            }
        }
        updateRuntimeState()
    }

    public func pager(pageSize: Int = 20) -> InboxPager {
        precondition((1...100).contains(pageSize), "Inbox pageSize must be between 1 and 100")
        let pager = InboxPager(inbox: self, pageSize: pageSize)
        registryLock.lock()
        pagers[pager.id] = WeakPager(pager)
        registryLock.unlock()
        pager.initialize()
        return pager
    }

    public func markRead(_ id: InboxEntryId) async {
        guard let entry = store.entry(id.value) else { return }
        await mutate("MARK_READ", id: id, when: entry.readAt == nil, wasUnread: true)
    }

    public func markUnread(_ id: InboxEntryId) async {
        let entry = store.entry(id.value)
        await mutate("MARK_UNREAD", id: id, when: entry?.readAt != nil, wasUnread: false)
    }

    public func markAllRead() async {
        await mutate("MARK_ALL_READ", id: nil, when: store.unreadCount > 0, wasUnread: nil)
    }

    public func delete(_ id: InboxEntryId) async {
        let entry = store.entry(id.value)
        await mutate("DELETE", id: id, when: entry != nil, wasUnread: entry?.readAt == nil)
    }

    fileprivate func fetchPage(cursor: String?, pageSize: Int, generation: Int64) async throws -> RemotePage {
        let request = PageRequest(generation: generation, pageSize: pageSize, cursor: cursor)
        return try await pageTasks.value(for: request) { [weak self] in
            guard let self else { throw inboxError(.server, "Inbox was released", retryable: false) }
            guard enabled.value, context.generation.value == generation else {
                throw inboxError(.generationChanged, "Inbox generation changed", retryable: true)
            }
            let response = try await context.authorizedRequest(
                method: "GET",
                path: "sdk/inbox",
                query: ["pageSize": String(pageSize)].merging(
                    cursor.map { ["cursor": $0] } ?? [:],
                    uniquingKeysWith: { _, new in new }
                )
            )
            let page = try decodePage(response)
            guard context.generation.value == generation else {
                throw inboxError(.generationChanged, "Inbox generation changed", retryable: true)
            }
            guard store.savePage(
                generation: generation,
                pageSize: pageSize,
                cursor: cursor,
                entries: page.entries,
                nextCursor: page.nextCursor,
                hasMore: page.hasMore,
                unreadCount: page.unreadCount
            ) else { throw inboxError(.localPersistence, "Inbox page could not be persisted", retryable: true) }
            return page
        }
    }

    private func mutate(
        _ type: String,
        id: InboxEntryId?,
        when condition: Bool,
        wasUnread: Bool?
    ) async {
        guard condition, enabled.value else { return }
        globalError.set(nil)
        guard store.enqueue(
            InboxMutation(
                operationId: UUID().uuidString.lowercased(),
                generation: context.generation.value,
                type: type,
                entryId: id?.value,
                occurredAt: ISO8601DateFormatter().string(from: Date()),
                wasUnread: wasUnread
            )
        ) else {
            globalError.set(inboxError(
                .localPersistence,
                "Inbox mutation could not be persisted",
                retryable: true
            ))
            return
        }
        await flushMutations()
    }

    fileprivate func flushMutations() async {
        guard enabled.value else { return }
        await flushGate.run { [weak self] in await self?.performFlushMutations() }
    }

    private func performFlushMutations() async {
        while enabled.value {
            let generation = context.generation.value
            let operations = store.pending(generation: generation)
            guard !operations.isEmpty else { return }
            let batchId = UUID().uuidString.lowercased()
            let response: AuthorizedResponse
            do {
                response = try await context.authorizedRequest(
                    method: "POST",
                    path: "sdk/inbox/operations:batch",
                    body: [
                        "batchId": .string(batchId),
                        "generation": .integer(generation),
                        "operations": .array(operations.map { operation in
                            .object([
                                "operationId": .string(operation.operationId),
                                "type": .string(operation.type),
                                "entryId": operation.entryId.map(JSONValue.string) ?? .null,
                            ])
                        }),
                    ]
                )
            } catch {
                let failure = classify(error)
                globalError.set(failure)
                if failure.isRetryable { scheduleMutationRetry() }
                return
            }

            do {
                let results = try decodeMutationResults(response, batchId: batchId, expected: operations)
                guard store.settle(ids: Set(results.map(\.operationId))) else {
                    let failure = inboxError(
                        .localPersistence,
                        "Inbox mutation acknowledgement could not be persisted",
                        retryable: true
                    )
                    globalError.set(failure)
                    scheduleMutationRetry()
                    return
                }
                let rejected = results.filter { $0.status == "REJECTED" }
                if let first = rejected.first {
                    globalError.set(inboxError(
                        .server,
                        first.message ?? first.errorCode ?? "Inbox mutation was rejected",
                        retryable: false
                    ))
                    catchUp(refreshMutations: false)
                } else {
                    globalError.set(nil)
                }
            } catch {
                let failure = classify(error)
                globalError.set(failure)
                if failure.isRetryable { scheduleMutationRetry() }
                if response.statusCode == 409 { await context.refresh() }
                return
            }
        }
    }

    fileprivate func resolveRenderings(_ ids: [InboxEntryId]) async throws -> [InboxRenderingSnapshot] {
        let requested = Array(Set(ids)).prefix(100).filter { store.contains($0.value) }
        guard !requested.isEmpty else { return [] }

        let cached = store.cachedRenderings(Array(requested))
        let cachedIds = Set(cached.map(\.entryId))
        let missing = requested.filter { !cachedIds.contains($0) }
        guard !missing.isEmpty else { return orderedRenderings(cached, ids: requested) }
        guard enabled.value else { return orderedRenderings(cached, ids: requested) }

        let response = try await context.authorizedRequest(
            method: "POST",
            path: "sdk/inbox/renderings:resolve",
            body: ["entryIds": .array(missing.map { .string($0.value) })]
        )
        guard response.isSuccessful, let raw = response.body?.array("renderings") else {
            throw classifyResponse(response)
        }
        let values = try raw.map { value -> InboxRenderingSnapshot in
            guard let item = value.objectValue,
                  let id = item.string("entryId"),
                  let renderer = item.string("renderer"),
                  let revision = item.integer("revision"),
                  let document = item.object("document") else { throw invalidResponse() }
            return InboxRenderingSnapshot(
                entryId: InboxEntryId(id),
                renderer: renderer,
                revision: revision,
                document: document
            )
        }
        let returned = values.map(\.entryId)
        guard returned.count == Set(returned).count,
              Set(returned).isSubset(of: Set(missing)) else { throw invalidResponse() }
        guard store.saveRenderings(values) else {
            throw inboxError(.localPersistence, "Inbox renderings could not be persisted", retryable: true)
        }
        return orderedRenderings(cached + values, ids: requested)
    }

    fileprivate func unregister(_ pager: InboxPager) {
        registryLock.lock()
        pagers[pager.id] = nil
        registryLock.unlock()
    }

    fileprivate func cachedWindow(pageSize: Int) -> CachedInboxWindow { store.cachedWindow(pageSize: pageSize) }
    fileprivate func projectedEntries(ids: [String]) -> [InboxEntry] {
        guard enabled.value else { return [] }
        return store.entries(ids: ids)
    }

    fileprivate func updateRuntimeState() {
        let generation = context.generation.value
        let isEnabled = context.installationId.value != nil
            && context.privacy.value == .optedIn
            && context.enabledFeatures.value.contains(.messageCenter)
        let changedGeneration = generation != activeGeneration || store.generation != generation
        activeGeneration = generation
        if changedGeneration, !store.activate(generation) {
            globalError.set(inboxError(
                .localPersistence,
                "Inbox generation could not be persisted",
                retryable: true
            ))
        }
        let wasEnabled = enabled.value
        enabled.set(isEnabled)
        updateUnreadCount()
        if changedGeneration { livePagers().forEach { $0.generationChanged(generation) } }
        if isEnabled, !wasEnabled || changedGeneration { catchUp() }
        if !isEnabled { expiryTask?.cancel(); expiryTask = nil }
    }

    fileprivate func wipe() throws {
        enabled.set(false)
        registryLock.lock()
        let retry = mutationRetryTask
        mutationRetryTask = nil
        mutationRetryId = nil
        registryLock.unlock()
        retry?.cancel()
        try store.wipe()
        unreadCount.set(0)
        globalError.set(nil)
        livePagers().forEach { $0.generationChanged(context.generation.value) }
    }

    private func catchUp(refreshMutations: Bool = true) {
        guard enabled.value else { return }
        if refreshMutations { Task { [weak self] in await self?.flushMutations() } }
        Task { [weak self] in await self?.refreshUnreadCount() }
        livePagers().forEach { pager in Task { await pager.refresh() } }
    }

    private func refreshUnreadCount() async {
        do {
            _ = try await fetchPage(cursor: nil, pageSize: 20, generation: context.generation.value)
            if globalError.value?.isRetryable == true { globalError.set(nil) }
        } catch {
            let failure = classify(error)
            globalError.set(failure)
            if failure.code == .generationChanged { await context.refresh() }
        }
    }

    private func livePagers() -> [InboxPager] {
        registryLock.lock()
        defer { registryLock.unlock() }
        pagers = pagers.filter { $0.value.value != nil }
        return pagers.values.compactMap(\.value)
    }

    private func updateUnreadCount() {
        let value = enabled.value && store.generation == context.generation.value ? store.unreadCount : 0
        unreadCount.set(value)
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard enabled.value,
              let expiration = store.entries().compactMap(\.expiresAt).min() else { return }
        let delay = max(0.001, expiration.timeIntervalSinceNow + 0.001)
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self else { return }
            if !store.activate(context.generation.value) {
                globalError.set(inboxError(
                    .localPersistence,
                    "Expired Inbox entries could not be persisted",
                    retryable: true
                ))
            }
        }
    }

    private func scheduleMutationRetry() {
        registryLock.lock()
        guard mutationRetryTask == nil else { registryLock.unlock(); return }
        let id = UUID()
        mutationRetryId = id
        mutationRetryTask = Task { [weak self] in await self?.retryMutations(id: id) }
        registryLock.unlock()
    }

    private func retryMutations(id: UUID) async {
        var delay: UInt64 = 1_000_000_000
        while !Task.isCancelled, enabled.value {
            do { try await Task.sleep(nanoseconds: delay) } catch { break }
            guard !store.pending(generation: context.generation.value).isEmpty else { break }
            await flushMutations()
            if globalError.value?.isRetryable != true { break }
            delay = min(delay * 2, 900_000_000_000)
        }
        clearMutationRetry(id: id)
    }

    private func clearMutationRetry(id: UUID) {
        registryLock.lock()
        if mutationRetryId == id {
            mutationRetryTask = nil
            mutationRetryId = nil
        }
        registryLock.unlock()
    }
}

public final class InboxPager: @unchecked Sendable {
    fileprivate let id = UUID()
    private weak var inbox: Inbox?
    private let pageSize: Int
    private let lock = NSLock()
    private let commands = PagerCommandGate()
    private var window: PagerWindow
    private var closed = false
    private var observationTasks: [Task<Void, Never>] = []

    public let state = EngageState(InboxPagerState())

    fileprivate init(inbox: Inbox, pageSize: Int) {
        self.inbox = inbox
        self.pageSize = pageSize
        window = PagerWindow(generation: inbox.context.generation.value)
    }

    fileprivate func initialize() {
        guard let inbox else { return }
        let project: @Sendable () -> Void = { [weak self] in self?.project() }
        observationTasks = [
            Task { for await _ in inbox.storeRevision { project() } },
            Task { for await _ in inbox.enabled.updates { project() } },
            Task { for await _ in inbox.globalError.updates { project() } },
            Task { for await _ in inbox.context.generation.updates { project() } },
        ]
        restoreCachedWindow()
        if inbox.enabled.value { Task { [weak self] in await self?.refresh() } }
    }

    public func refresh() async {
        await commands.run(.refresh) { [weak self] in await self?.performRefresh() }
    }

    public func loadNextPage() async {
        await commands.run(.loadNext) { [weak self] in await self?.performLoadNextPage() }
    }

    public func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        observationTasks.forEach { $0.cancel() }
        observationTasks = []
        lock.unlock()
        Task { await commands.cancelAll() }
        inbox?.unregister(self)
    }

    fileprivate func generationChanged(_ generation: Int64) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        window = PagerWindow(generation: generation)
        lock.unlock()
        restoreCachedWindow()
        project()
        if inbox?.enabled.value == true { Task { [weak self] in await self?.refresh() } }
    }

    private func performRefresh() async {
        guard let inbox, isOpen, inbox.enabled.value else { return }
        let generation = inbox.context.generation.value
        let current = currentWindow
        let targetSize = max(pageSize, current.entryIds.count)
        setWindow(current.with(generation: generation, refreshing: true, loadingMore: false, error: nil))
        do {
            var ids: [String] = []
            var cursor: String?
            var visited = Set<String>()
            var hasMore = false
            repeat {
                let cursorKey = cursor ?? "\u{0}first"
                guard visited.insert(cursorKey).inserted else { throw invalidResponse("Inbox cursor loop detected") }
                let page = try await inbox.fetchPage(cursor: cursor, pageSize: pageSize, generation: generation)
                for entry in page.entries where !ids.contains(entry.id.value) { ids.append(entry.id.value) }
                cursor = page.nextCursor
                hasMore = page.hasMore
            } while hasMore && ids.count < targetSize
            guard inbox.context.generation.value == generation else {
                throw inboxError(.generationChanged, "Inbox generation changed", retryable: true)
            }
            setWindow(PagerWindow(
                generation: generation,
                entryIds: ids,
                nextCursor: cursor,
                hasMore: hasMore
            ))
            if inbox.globalError.value?.isRetryable == true { inbox.globalError.set(nil) }
        } catch {
            let previous = currentWindow
            setWindow(previous.with(refreshing: false, loadingMore: false, error: classify(error)))
            if classify(error).code == .generationChanged { await inbox.context.refresh() }
        }
    }

    private func performLoadNextPage() async {
        guard let inbox, isOpen, inbox.enabled.value else { return }
        let current = currentWindow
        guard current.hasMore, let cursor = current.nextCursor else { return }
        let generation = inbox.context.generation.value
        setWindow(current.with(refreshing: false, loadingMore: true, error: nil))
        do {
            let page = try await inbox.fetchPage(cursor: cursor, pageSize: pageSize, generation: generation)
            guard inbox.context.generation.value == generation else {
                throw inboxError(.generationChanged, "Inbox generation changed", retryable: true)
            }
            var ids = current.entryIds
            for entry in page.entries where !ids.contains(entry.id.value) { ids.append(entry.id.value) }
            setWindow(PagerWindow(
                generation: generation,
                entryIds: ids,
                nextCursor: page.nextCursor,
                hasMore: page.hasMore
            ))
        } catch {
            setWindow(current.with(refreshing: false, loadingMore: false, error: classify(error)))
        }
    }

    private func restoreCachedWindow() {
        guard let inbox, isOpen else { return }
        let cached = inbox.cachedWindow(pageSize: pageSize)
        setWindow(PagerWindow(
            generation: inbox.context.generation.value,
            entryIds: cached.entryIds,
            nextCursor: cached.nextCursor,
            hasMore: cached.hasMore
        ))
    }

    private func project() {
        guard let inbox else { return }
        let value = currentWindow
        let entries = inbox.projectedEntries(ids: value.entryIds)
        state.set(InboxPagerState(
            entries: entries,
            isRefreshing: value.isRefreshing,
            isLoadingMore: value.isLoadingMore,
            hasMore: inbox.enabled.value && value.hasMore,
            error: value.error ?? inbox.globalError.value
        ))
    }

    private var currentWindow: PagerWindow {
        lock.lock(); defer { lock.unlock() }
        return window
    }

    private var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed
    }

    private func setWindow(_ value: PagerWindow) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        window = value
        lock.unlock()
        project()
    }
}

private struct PagerWindow: Sendable {
    let generation: Int64
    let entryIds: [String]
    let nextCursor: String?
    let hasMore: Bool
    let isRefreshing: Bool
    let isLoadingMore: Bool
    let error: InboxError?

    init(
        generation: Int64,
        entryIds: [String] = [],
        nextCursor: String? = nil,
        hasMore: Bool = false,
        isRefreshing: Bool = false,
        isLoadingMore: Bool = false,
        error: InboxError? = nil
    ) {
        self.generation = generation
        self.entryIds = entryIds
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.isRefreshing = isRefreshing
        self.isLoadingMore = isLoadingMore
        self.error = error
    }

    func with(
        generation: Int64? = nil,
        refreshing: Bool? = nil,
        loadingMore: Bool? = nil,
        error: InboxError?
    ) -> PagerWindow {
        PagerWindow(
            generation: generation ?? self.generation,
            entryIds: entryIds,
            nextCursor: nextCursor,
            hasMore: hasMore,
            isRefreshing: refreshing ?? isRefreshing,
            isLoadingMore: loadingMore ?? isLoadingMore,
            error: error
        )
    }
}

private struct RemotePage: Sendable {
    let entries: [InboxEntry]
    let nextCursor: String?
    let hasMore: Bool
    let unreadCount: Int
}

private struct PageRequest: Hashable, Sendable {
    let generation: Int64
    let pageSize: Int
    let cursor: String?
}

private actor PageTaskRegistry {
    private struct InFlight {
        let id: UUID
        let task: Task<RemotePage, Error>
    }
    private var tasks: [PageRequest: InFlight] = [:]

    func value(
        for request: PageRequest,
        load: @escaping @Sendable () async throws -> RemotePage
    ) async throws -> RemotePage {
        let flight: InFlight
        if let existing = tasks[request] {
            flight = existing
        } else {
            flight = InFlight(id: UUID(), task: Task { try await load() })
            tasks[request] = flight
        }
        do {
            let value = try await flight.task.value
            if tasks[request]?.id == flight.id { tasks[request] = nil }
            return value
        } catch {
            if tasks[request]?.id == flight.id { tasks[request] = nil }
            throw error
        }
    }
}

private actor PagerCommandGate {
    enum Command: Hashable { case refresh, loadNext }
    private struct InFlight { let id: UUID; let task: Task<Void, Never> }
    private var tasks: [Command: InFlight] = [:]

    func run(_ command: Command, operation: @escaping @Sendable () async -> Void) async {
        let flight: InFlight
        if let existing = tasks[command] {
            flight = existing
        } else {
            flight = InFlight(id: UUID(), task: Task { await operation() })
            tasks[command] = flight
        }
        await flight.task.value
        if tasks[command]?.id == flight.id { tasks[command] = nil }
    }

    func cancelAll() {
        tasks.values.forEach { $0.task.cancel() }
        tasks = [:]
    }
}

private actor AsyncGate {
    private struct InFlight { let id: UUID; let task: Task<Void, Never> }
    private var inFlight: InFlight?

    func run(_ operation: @escaping @Sendable () async -> Void) async {
        let flight: InFlight
        if let inFlight {
            flight = inFlight
        } else {
            flight = InFlight(id: UUID(), task: Task { await operation() })
            inFlight = flight
        }
        await flight.task.value
        if inFlight?.id == flight.id { inFlight = nil }
    }
}

private struct MutationResult: Sendable {
    let operationId: String
    let status: String
    let errorCode: String?
    let message: String?
}

private final class WeakPager {
    weak var value: InboxPager?
    init(_ value: InboxPager) { self.value = value }
}

private extension Inbox {
    var storeRevision: AsyncStream<Int64> { store.revision.updates }
}

private func decodePage(_ response: AuthorizedResponse) throws -> RemotePage {
    guard response.isSuccessful else { throw classifyResponse(response) }
    guard let body = response.body,
          let rawEntries = body.array("entries"),
          let hasMore = body.bool("hasMore"),
          let unread = body.number("unreadCount") else { throw invalidResponse() }
    let entries = try rawEntries.map { raw -> InboxEntry in
        guard let item = raw.objectValue,
              let id = item.string("id"),
              let key = item.string("key"),
              let payload = item.object("payload"),
              let sentAt = item.string("sentAt").flatMap(parseDate) else { throw invalidResponse() }
        return InboxEntry(
            id: InboxEntryId(id),
            key: key,
            payload: payload,
            sentAt: sentAt,
            expiresAt: item.string("expiresAt").flatMap(parseDate),
            readAt: item.string("readAt").flatMap(parseDate)
        )
    }
    let nextCursor = body.string("nextCursor")
    guard !hasMore || nextCursor != nil else { throw invalidResponse() }
    return RemotePage(
        entries: entries,
        nextCursor: nextCursor,
        hasMore: hasMore,
        unreadCount: Int(unread)
    )
}

private func decodeMutationResults(
    _ response: AuthorizedResponse,
    batchId: String,
    expected: [InboxMutation]
) throws -> [MutationResult] {
    guard response.isSuccessful else { throw classifyResponse(response) }
    guard let body = response.body,
          body.string("batchId") == batchId,
          let raw = body.array("results")?.compactMap(\.objectValue) else { throw invalidResponse() }
    let results = try raw.map { value -> MutationResult in
        guard let id = value.string("operationId"),
              let status = value.string("status"),
              ["ACCEPTED", "DUPLICATE", "REJECTED"].contains(status) else { throw invalidResponse() }
        return MutationResult(
            operationId: id,
            status: status,
            errorCode: value.string("errorCode"),
            message: value.string("message")
        )
    }
    let returned = results.map(\.operationId)
    let expectedIds = Set(expected.map(\.operationId))
    guard returned.count == Set(returned).count, Set(returned) == expectedIds else { throw invalidResponse() }
    return results
}

private func parseDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

private func orderedRenderings(
    _ values: [InboxRenderingSnapshot],
    ids: some Collection<InboxEntryId>
) -> [InboxRenderingSnapshot] {
    let indexed = Dictionary(uniqueKeysWithValues: values.map { ($0.entryId, $0) })
    return ids.compactMap { indexed[$0] }
}

private func classifyResponse(_ response: AuthorizedResponse) -> InboxError {
    switch response.statusCode {
    case 401: return inboxError(.unauthorized, "Inbox authorization failed", retryable: false)
    case 409: return inboxError(.generationChanged, "Inbox generation changed", retryable: true)
    case 500...599: return inboxError(.server, "Inbox server error", retryable: true)
    default: return inboxError(.server, "Inbox request failed with HTTP \(response.statusCode)", retryable: false)
    }
}

private func classify(_ error: Error) -> InboxError {
    if let error = error as? InboxError { return error }
    if let error = error as? EngageHTTPError {
        switch error.statusCode {
        case 401: return inboxError(.unauthorized, error.message, retryable: false)
        case 409: return inboxError(.generationChanged, error.message, retryable: true)
        case 500...599: return inboxError(.server, error.message, retryable: true)
        default: return inboxError(.server, error.message, retryable: false)
        }
    }
    return inboxError(.network, String(describing: error), retryable: true)
}

private func inboxError(_ code: InboxErrorCode, _ message: String, retryable: Bool) -> InboxError {
    InboxError(code: code, message: message, isRetryable: retryable)
}

private func invalidResponse(_ message: String = "Invalid Engage Inbox response") -> InboxError {
    inboxError(.invalidResponse, message, retryable: false)
}

/// Public entry point when the standalone `EngageMessageCenter` Swift Package product is used.
///
/// `EngageSDK` activates this module automatically. With a modular installation, call
/// `EngageCore.start(config:)` first, then `MessageCenterModule.activate()`.
public enum MessageCenterModule {
    @discardableResult
    public static func activate() -> MessageCenter { MessageCenterHolder.shared }

    public static var shared: MessageCenter { activate() }
}
private enum MessageCenterHolder {
    static let shared = MessageCenter(context: EngageCore.moduleContext)
}

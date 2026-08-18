import Foundation
import EngageCore

public struct InboxEntryId: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: String
    public init(_ value: String) { precondition(!value.isEmpty); self.value = value }
    public var description: String { value }
}
public struct InboxEntry: Codable, Equatable, Sendable {
    public let id: InboxEntryId
    public let key: String
    public let payload: EngagePayload
    public let sentAt: Date
    public let expiresAt: Date?
    public let readAt: Date?
}
public enum InboxErrorCode: Sendable {
    case network, unauthorized, generationChanged, server, invalidResponse, localPersistence
}
public struct InboxError: Error, Sendable {
    public let code: InboxErrorCode
    public let message: String
    public let isRetryable: Bool
}
public struct InboxPagerState: Sendable {
    public let entries: [InboxEntry]
    public let isRefreshing: Bool
    public let isLoadingMore: Bool
    public let hasMore: Bool
    public let error: InboxError?
    public init(
        entries: [InboxEntry] = [], isRefreshing: Bool = false, isLoadingMore: Bool = false,
        hasMore: Bool = false, error: InboxError? = nil
    ) {
        self.entries = entries; self.isRefreshing = isRefreshing; self.isLoadingMore = isLoadingMore
        self.hasMore = hasMore; self.error = error
    }
}

@_spi(Rendering) public struct InboxRenderingSnapshot: Sendable {
    public let entryId: InboxEntryId
    public let renderer: InboxRenderer
    public let revision: Int64
    public let surfaces: [InboxRenderingSurface: EngagePayload]
    public let expiresAt: Date?

    public init(
        entryId: InboxEntryId,
        renderer: InboxRenderer,
        revision: Int64,
        surfaces: [InboxRenderingSurface: EngagePayload],
        expiresAt: Date? = nil
    ) {
        self.entryId = entryId
        self.renderer = renderer
        self.revision = revision
        self.surfaces = surfaces
        self.expiresAt = expiresAt
    }

    public func surface(_ surface: InboxRenderingSurface) -> EngagePayload? {
        surfaces[surface]
    }
}

@_spi(Rendering) public struct MessageCenterPresentationState: Sendable {
    public let lifecycleRevision: Int64
    public let generation: Int64
    public let isEnabled: Bool
    public let entryIds: Set<InboxEntryId>
    public let deletedEntryIds: Set<InboxEntryId>

    public init(
        lifecycleRevision: Int64,
        generation: Int64,
        isEnabled: Bool,
        entryIds: Set<InboxEntryId>,
        deletedEntryIds: Set<InboxEntryId> = []
    ) {
        self.lifecycleRevision = lifecycleRevision
        self.generation = generation
        self.isEnabled = isEnabled
        self.entryIds = entryIds
        self.deletedEntryIds = deletedEntryIds
    }
}

@_spi(Rendering) public enum InboxRenderer: String, Codable, Sendable {
    case divKit = "DIVKIT"
}

@_spi(Rendering) public enum InboxRenderingSurface: String, Codable, CaseIterable, Sendable {
    case summary = "SUMMARY"
    case detail = "DETAIL"
}

import Foundation
import EngageCore

struct PushStoredState: Codable, Equatable, Sendable {
    static let disabledMarker = "__disabled__"
    var subscription = "OPTED_IN"
    var registeredTokenHash: String?
    var token: String?
    var pendingSubscription = false
    var reportedPermission: String?
    var processedDeliveryIds: [String] = []

    init(
        subscription: String = "OPTED_IN",
        registeredTokenHash: String? = nil,
        token: String? = nil,
        pendingSubscription: Bool = false,
        reportedPermission: String? = nil,
        processedDeliveryIds: [String] = []
    ) {
        self.subscription = subscription
        self.registeredTokenHash = registeredTokenHash
        self.token = token
        self.pendingSubscription = pendingSubscription
        self.reportedPermission = reportedPermission
        self.processedDeliveryIds = processedDeliveryIds
    }

    private enum CodingKeys: String, CodingKey {
        case subscription, registeredTokenHash, token, pendingSubscription, reportedPermission, processedDeliveryIds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        subscription = try values.decodeIfPresent(String.self, forKey: .subscription) ?? "OPTED_IN"
        registeredTokenHash = try values.decodeIfPresent(String.self, forKey: .registeredTokenHash)
        token = try values.decodeIfPresent(String.self, forKey: .token)
        pendingSubscription = try values.decodeIfPresent(Bool.self, forKey: .pendingSubscription) ?? false
        reportedPermission = try values.decodeIfPresent(String.self, forKey: .reportedPermission)
        processedDeliveryIds = try values.decodeIfPresent([String].self, forKey: .processedDeliveryIds) ?? []
    }
}

final class PushPersistence: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let removeItem: @Sendable (URL) throws -> Void
    private var stored: PushStoredState

    init(
        directory: URL = pushStorageDirectory(),
        removeItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.removeItem = removeItem
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("push-state.json")
        stored = (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode(PushStoredState.self, from: $0)
        } ?? PushStoredState()
        EngageLogger.info(
            "Push.Storage",
            "loaded subscription=\(stored.subscription) hasToken=\(stored.token != nil) " +
                "pendingSubscription=\(stored.pendingSubscription) tokenRegistered=\(stored.registeredTokenHash != nil)"
        )
    }

    var value: PushStoredState {
        lock.lock(); defer { lock.unlock() }
        EngageLogger.verbose(
            "Push.Storage",
            "state read subscription=\(stored.subscription) hasToken=\(stored.token != nil) " +
                "pendingSubscription=\(stored.pendingSubscription)"
        )
        return stored
    }

    func edit(_ operation: (inout PushStoredState) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var candidate = stored
        operation(&candidate)
        EngageLogger.debug(
            "Push.Storage",
            "state persisting subscription=\(candidate.subscription) hasToken=\(candidate.token != nil) " +
                "pendingSubscription=\(candidate.pendingSubscription) tokenRegistered=\(candidate.registeredTokenHash != nil)"
        )
        let data = try JSONEncoder().encode(candidate)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        stored = candidate
        EngageLogger.debug("Push.Storage", "state persisted bytes=\(data.count)")
    }

    func claimDelivery(_ deliveryId: String, limit: Int = 100) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stored.processedDeliveryIds.contains(deliveryId) else { return false }
        var candidate = stored
        candidate.processedDeliveryIds.append(deliveryId)
        candidate.processedDeliveryIds = Array(candidate.processedDeliveryIds.suffix(max(1, limit)))
        let data = try JSONEncoder().encode(candidate)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        stored = candidate
        return true
    }

    func wipe() throws {
        EngageLogger.warning("Push.Storage", "state wipe started")
        lock.lock()
        defer { lock.unlock() }
        do { try removeItem(url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        stored = PushStoredState()
        EngageLogger.warning("Push.Storage", "state wiped")
    }
}

private func pushStorageDirectory() -> URL {
    let manager = FileManager.default
    let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? manager.temporaryDirectory
    return base.appendingPathComponent("io.engage.sdk", isDirectory: true)
}

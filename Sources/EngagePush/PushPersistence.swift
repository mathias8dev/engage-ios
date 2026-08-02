import Foundation

struct PushStoredState: Codable, Equatable, Sendable {
    static let disabledMarker = "__disabled__"
    var subscription = "OPTED_IN"
    var registeredTokenHash: String?
    var token: String?
    var pendingSubscription = false
    var reportedPermission: String?

    init(
        subscription: String = "OPTED_IN",
        registeredTokenHash: String? = nil,
        token: String? = nil,
        pendingSubscription: Bool = false,
        reportedPermission: String? = nil
    ) {
        self.subscription = subscription
        self.registeredTokenHash = registeredTokenHash
        self.token = token
        self.pendingSubscription = pendingSubscription
        self.reportedPermission = reportedPermission
    }

    private enum CodingKeys: String, CodingKey {
        case subscription, registeredTokenHash, token, pendingSubscription, reportedPermission
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        subscription = try values.decodeIfPresent(String.self, forKey: .subscription) ?? "OPTED_IN"
        registeredTokenHash = try values.decodeIfPresent(String.self, forKey: .registeredTokenHash)
        token = try values.decodeIfPresent(String.self, forKey: .token)
        pendingSubscription = try values.decodeIfPresent(Bool.self, forKey: .pendingSubscription) ?? false
        reportedPermission = try values.decodeIfPresent(String.self, forKey: .reportedPermission)
    }
}

final class PushPersistence: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var stored: PushStoredState

    init(directory: URL = pushStorageDirectory()) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("push-state.json")
        stored = (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode(PushStoredState.self, from: $0)
        } ?? PushStoredState()
    }

    var value: PushStoredState {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func edit(_ operation: (inout PushStoredState) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var candidate = stored
        operation(&candidate)
        let data = try JSONEncoder().encode(candidate)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        stored = candidate
    }

    func wipe() throws {
        lock.lock()
        defer { lock.unlock() }
        stored = PushStoredState()
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
    }
}

private func pushStorageDirectory() -> URL {
    let manager = FileManager.default
    let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? manager.temporaryDirectory
    return base.appendingPathComponent("io.engage.sdk", isDirectory: true)
}

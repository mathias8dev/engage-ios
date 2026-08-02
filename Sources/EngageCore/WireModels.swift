import Foundation

public enum PrivacyState: String, Codable, Sendable { case optedIn = "OPTED_IN", optedOut = "OPTED_OUT" }
public enum SdkFeature: String, Codable, CaseIterable, Sendable {
    case analytics = "ANALYTICS"
    case push = "PUSH"
    case inApp = "IN_APP"
    case messageCenter = "MESSAGE_CENTER"
    case preferences = "PREFERENCES"
    case featureFlags = "FEATURE_FLAGS"
}

@_spi(Modules) public enum SyncModule: String, Codable, Sendable {
    case push = "PUSH"
    case inApp = "IN_APP"
    case preferences = "PREFERENCES"
    case featureFlags = "FEATURE_FLAGS"
}

struct InstallationSession: Codable, Equatable, Sendable {
    let installationId: String
    let credential: String
    let revocationCredential: String
    let recoveryToken: String
    let generation: Int64
    let privacy: PrivacyState
    let pushSubscription: String
    let serverTime: String
}

struct BootstrapRequest: Codable, Sendable {
    var platform = "IOS"
    let locale: String
    let timezone: String
    let sdkVersion: String
    let appVersion: String
    let appBuild: String?
    let deviceModel: String?
    let osVersion: String?
    let recoveryToken: String?
}

struct InstallationStateResponse: Codable, Sendable {
    let installationId: String
    let generation: Int64
    let bindingState: String
    let privacy: PrivacyState
    let pushSubscription: String
    let bound: Bool
    let updatedAt: String
}

struct BindingCodeResponse: Codable, Sendable { let code: String; let expiresAt: String }

struct SdkOperation: Codable, Equatable, Sendable {
    let operationId: String
    let generation: Int64
    let type: String
    let occurredAt: String
    let payload: EngagePayload
}

struct OperationBatchRequest: Codable, Sendable { let batchId: String; let operations: [SdkOperation] }
struct OperationBatchResponse: Codable, Sendable {
    let batchId: String
    let results: [OperationResult]
    let serverTime: String
}
struct OperationResult: Codable, Sendable {
    let operationId: String
    let status: OperationStatus
    let errorCode: String?
    let message: String?
}
enum OperationStatus: String, Codable, Sendable { case accepted = "ACCEPTED", duplicate = "DUPLICATE", rejected = "REJECTED" }

struct SyncRequest: Codable, Sendable { let cursor: String?; let modules: Set<SyncModule> }
struct SyncResponse: Codable, Sendable {
    let cursor: String
    let generation: Int64
    let revision: Int64
    let fullSnapshot: Bool
    let documents: [RemoteDocument]
    let tombstones: [SyncTombstone]
    let serverTime: String
    let refreshAfterSeconds: Int64
}

@_spi(Modules) public struct RemoteDocument: Codable, Equatable, Sendable {
    public let module: SyncModule
    public let key: String
    public let revision: Int64
    public let payload: EngagePayload

    public init(module: SyncModule, key: String, revision: Int64, payload: EngagePayload) {
        self.module = module; self.key = key; self.revision = revision; self.payload = payload
    }
}
struct SyncTombstone: Codable, Sendable { let module: SyncModule; let key: String; let revision: Int64 }

struct SyncSnapshot: Codable, Equatable, Sendable {
    var cursor: String?
    var generation: Int64?
    var revision: Int64
    var documents: [RemoteDocument]
    var refreshAfterSeconds: Int64

    static let empty = SyncSnapshot(cursor: nil, generation: nil, revision: 0, documents: [], refreshAfterSeconds: 900)
}

struct RevocationEnvelope: Codable, Equatable, Sendable { let operationId: String; let credential: String }

@_spi(Modules) public enum EngageSignal: Sendable {
    case event(name: String, properties: EngagePayload)
    case screenViewed(String)
    case screenCleared
    case appOpened
    case appBackgrounded
    case networkAvailable
    case localDataWiped
}

@_spi(Modules) public struct AuthorizedResponse: Sendable {
    public let statusCode: Int
    public let body: EngagePayload?
    public var isSuccessful: Bool { (200..<300).contains(statusCode) }
}

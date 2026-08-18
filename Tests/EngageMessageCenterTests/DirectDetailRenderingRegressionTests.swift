import XCTest
@testable import EngageCore
@_spi(Modules) import EngageCore
@_spi(Rendering) @testable import EngageMessageCenter
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class DirectDetailRenderingRegressionTests: XCTestCase {
    override func tearDown() {
        DirectDetailURLProtocol.reset()
        super.tearDown()
    }

    func testDirectDetailResolvesAnEntryThatHasNotBeenLoadedByAPager() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engage-direct-detail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let persistence = CorePersistence(directory: directory, secureStorageBackend: .fileSystem)
        try await persistence.saveSession(InstallationSession(
            installationId: "installation-1",
            credential: "credential-1",
            revocationCredential: "revocation-1",
            recoveryToken: "recovery-1",
            generation: 7,
            privacy: .optedIn,
            pushSubscription: "OPTED_IN",
            serverTime: "2026-08-18T12:00:00Z"
        ))

        DirectDetailURLProtocol.respond(with: """
        {
          "renderings": [{
            "entryId": "entry-from-deep-link",
            "renderer": "DIVKIT",
            "revision": 1,
            "expiresAt": "2099-01-01T00:00:00Z",
            "surfaces": {"SUMMARY": {}, "DETAIL": {}}
          }]
        }
        """)
        let config = EngageConfig(
            appKey: "eng_app_tests",
            endpoint: URL(string: "https://edge.example/v1/")!
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [DirectDetailURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let runtime = CoreRuntime(config: config, directory: directory, urlSession: session)
        let context = EngageModuleContext(runtime: runtime, config: config)
        context.enabledFeatures.set([.messageCenter])
        let messageCenter = MessageCenter(context: context)

        let resolved = try await messageCenter.resolveRenderings([
            InboxEntryId("entry-from-deep-link"),
        ])

        XCTAssertEqual(resolved.map(\.entryId), [InboxEntryId("entry-from-deep-link")])
        XCTAssertEqual(resolved.first?.expiresAt, ISO8601DateFormatter().date(from: "2099-01-01T00:00:00Z"))
        XCTAssertEqual(DirectDetailURLProtocol.renderingRequestCount, 1)
    }

    func testExistingPagerRefreshesWhenMessageCenterBecomesEnabled() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engage-pager-reenable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let persistence = CorePersistence(directory: directory, secureStorageBackend: .fileSystem)
        try await persistence.saveSession(InstallationSession(
            installationId: "installation-1",
            credential: "credential-1",
            revocationCredential: "revocation-1",
            recoveryToken: "recovery-1",
            generation: 7,
            privacy: .optedIn,
            pushSubscription: "OPTED_IN",
            serverTime: "2026-08-18T12:00:00Z"
        ))

        let inboxResponse = """
        {
          "entries": [{
            "id": "entry-after-enable",
            "key": "order.shipped",
            "payload": {"orderId": "order-42"},
            "sentAt": "2026-08-18T12:00:00Z",
            "expiresAt": null,
            "readAt": null
          }],
          "nextCursor": null,
          "hasMore": false,
          "unreadCount": 1
        }
        """
        let config = EngageConfig(
            appKey: "eng_app_tests",
            endpoint: URL(string: "https://edge.example/v1/")!
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [DirectDetailURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let runtime = CoreRuntime(config: config, directory: directory, urlSession: session)
        let context = EngageModuleContext(runtime: runtime, config: config)
        let messageCenter = MessageCenter(context: context)

        // Registering the module makes the feature available. Explicitly disable it and
        // let the initial activation settle before measuring the disabled-pager contract.
        try await Task.sleep(nanoseconds: 100_000_000)
        context.enabledFeatures.set([])
        for _ in 0..<100 where messageCenter.presentationState.value.isEnabled {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(messageCenter.presentationState.value.isEnabled)
        DirectDetailURLProtocol.respondToInbox(with: inboxResponse)

        let pager = messageCenter.inbox.pager(pageSize: 20)
        defer { pager.close() }

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(DirectDetailURLProtocol.inboxRequestCount, 0)

        context.enabledFeatures.set([.messageCenter])

        for _ in 0..<100 where pager.state.value.entries.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(pager.state.value.entries.map(\.id), [InboxEntryId("entry-after-enable")])
        XCTAssertGreaterThan(DirectDetailURLProtocol.inboxRequestCount, 0)
    }
}

private final class DirectDetailURLProtocol: URLProtocol {
    private static let emptyInboxResponse = Data("""
    {"entries":[],"nextCursor":null,"hasMore":false,"unreadCount":0}
    """.utf8)
    private static let installationResponse = Data("""
    {
      "installationId":"installation-1",
      "generation":7,
      "bindingState":"ANONYMOUS",
      "privacy":"OPTED_IN",
      "pushSubscription":"OPTED_IN",
      "bound":false,
      "updatedAt":"2026-08-18T12:00:00Z"
    }
    """.utf8)
    private static let syncResponse = Data("""
    {
      "cursor":"cursor-1",
      "generation":7,
      "revision":1,
      "fullSnapshot":true,
      "documents":[],
      "tombstones":[],
      "serverTime":"2026-08-18T12:00:00Z",
      "refreshAfterSeconds":900
    }
    """.utf8)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseBody = Data()
    nonisolated(unsafe) private static var inboxResponseBody = emptyInboxResponse
    nonisolated(unsafe) private static var renderingRequests = 0
    nonisolated(unsafe) private static var inboxRequests = 0

    static var renderingRequestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return renderingRequests
    }

    static var inboxRequestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return inboxRequests
    }

    static func respond(with json: String) {
        lock.lock()
        responseBody = Data(json.utf8)
        renderingRequests = 0
        lock.unlock()
    }

    static func respondToInbox(with json: String) {
        lock.lock()
        inboxResponseBody = Data(json.utf8)
        inboxRequests = 0
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        responseBody = Data()
        inboxResponseBody = emptyInboxResponse
        renderingRequests = 0
        inboxRequests = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        if request.url?.path.hasSuffix("/sdk/inbox/renderings:resolve") == true {
            Self.renderingRequests += 1
        }
        let path = request.url?.path ?? ""
        let isInboxPage = path.hasSuffix("/sdk/inbox")
        if isInboxPage { Self.inboxRequests += 1 }
        let body: Data
        if isInboxPage {
            body = Self.inboxResponseBody
        } else if path.hasSuffix("/v1/sdk/installation") {
            body = Self.installationResponse
        } else if path.hasSuffix("/v1/sdk/sync") {
            body = Self.syncResponse
        } else {
            body = Self.responseBody
        }
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

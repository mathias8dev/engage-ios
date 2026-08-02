import XCTest
@testable import EngageCore
@_spi(Modules) import EngageCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MobileEdgeClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testBootstrapUsesThePublicAppKeyAndDecodesTheInstallationSession() async throws {
        let body = """
        {
          "installationId":"installation-1",
          "credential":"credential-1",
          "revocationCredential":"revoke-1",
          "recoveryToken":"recover-1",
          "generation":4,
          "privacy":"OPTED_IN",
          "pushSubscription":"OPTED_IN",
          "serverTime":"2026-08-02T12:00:00Z"
        }
        """.data(using: .utf8)!
        MockURLProtocol.respond(status: 200, body: body)
        let client = makeClient()

        let session = try await client.bootstrap(BootstrapRequest(
            locale: "fr-FR",
            timezone: "Europe/Paris",
            sdkVersion: "1.0.0",
            appVersion: "3.2.1",
            appBuild: "42",
            deviceModel: "iPhone",
            osVersion: "iOS",
            recoveryToken: nil
        ))

        XCTAssertEqual(session.installationId, "installation-1")
        XCTAssertEqual(session.generation, 4)
        let request = try XCTUnwrap(MockURLProtocol.lastRequest())
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/sdk/installations")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Engage-App-Key"), "eng_app_tests")
        let payload = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(json["platform"] as? String, "IOS")
        XCTAssertEqual(json["locale"] as? String, "fr-FR")
    }

    func testRevocationUsesItsLimitedCredentialAndStableOperationPath() async throws {
        MockURLProtocol.respond(status: 204, body: Data())
        let client = makeClient()

        try await client.revoke(RevocationEnvelope(
            operationId: "operation-42",
            credential: "limited-revocation-credential"
        ))

        let request = try XCTUnwrap(MockURLProtocol.lastRequest())
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/v1/sdk/privacy/revocations/operation-42")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer limited-revocation-credential"
        )
    }

    func testHeadlessAuthorizedRequestReturnsAConflictAsData() async throws {
        MockURLProtocol.respond(
            status: 409,
            body: "{\"code\":\"generation_changed\",\"message\":\"Refresh the installation\"}"
                .data(using: .utf8)!
        )
        let client = makeClient()

        let response = try await client.authorized(
            path: "sdk/inbox",
            method: "GET",
            query: ["pageSize": "20"],
            body: nil,
            credential: "credential"
        )

        XCTAssertEqual(response.statusCode, 409)
        XCTAssertEqual(response.body?.string("code"), "generation_changed")
        let request = try XCTUnwrap(MockURLProtocol.lastRequest())
        XCTAssertEqual(request.url?.query, "pageSize=20")
    }

    private func makeClient() -> MobileEdgeClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return MobileEdgeClient(
            endpoint: URL(string: "https://edge.example/v1/")!,
            appKey: "eng_app_tests",
            session: URLSession(configuration: configuration)
        )
    }
}

private final class MockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseStatus = 200
    nonisolated(unsafe) private static var responseBody = Data()
    nonisolated(unsafe) private static var capturedRequest: URLRequest?

    static func respond(status: Int, body: Data) {
        lock.lock()
        responseStatus = status
        responseBody = body
        capturedRequest = nil
        lock.unlock()
    }

    static func lastRequest() -> URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return capturedRequest
    }

    static func reset() {
        lock.lock()
        responseStatus = 200
        responseBody = Data()
        capturedRequest = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedRequest = request
        let status = Self.responseStatus
        let body = Self.responseBody
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

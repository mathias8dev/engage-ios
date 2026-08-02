import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct EngageHTTPError: Error, Sendable {
    public let statusCode: Int
    public let code: String?
    public let message: String
}

final class MobileEdgeClient: @unchecked Sendable {
    private let endpoint: URL
    private let appKey: String
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(endpoint: URL, appKey: String, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.appKey = appKey
        self.session = session
    }

    func bootstrap(_ body: BootstrapRequest) async throws -> InstallationSession {
        var request = request(path: "sdk/installations", method: "POST")
        request.setValue(appKey, forHTTPHeaderField: "X-Engage-App-Key")
        request.httpBody = try encoder.encode(body)
        return try await execute(request)
    }

    func bindingCode(credential: String) async throws -> BindingCodeResponse {
        try await execute(authorized(path: "sdk/installation/binding-code", method: "POST", credential: credential))
    }

    func installation(credential: String) async throws -> InstallationStateResponse {
        try await execute(authorized(path: "sdk/installation", method: "GET", credential: credential))
    }

    func operations(_ body: OperationBatchRequest, credential: String) async throws -> OperationBatchResponse {
        var request = authorized(path: "sdk/operations:batch", method: "POST", credential: credential)
        request.httpBody = try encoder.encode(body)
        return try await execute(request)
    }

    func sync(_ body: SyncRequest, credential: String) async throws -> SyncResponse {
        var request = authorized(path: "sdk/sync", method: "POST", credential: credential)
        request.httpBody = try encoder.encode(body)
        return try await execute(request)
    }

    func revoke(_ envelope: RevocationEnvelope) async throws {
        let request = authorized(
            path: "sdk/privacy/revocations/\(envelope.operationId)",
            method: "PUT",
            credential: envelope.credential
        )
        let (_, response) = try await session.data(for: request)
        try validate(response, data: Data())
    }

    func authorized(
        path: String,
        method: String,
        query: [String: String] = [:],
        body: EngagePayload?,
        credential: String
    ) async throws -> AuthorizedResponse {
        precondition(!path.hasPrefix("/") && !path.contains("://") && path.hasPrefix("sdk/"))
        var request = authorized(path: path, method: method, credential: credential, query: query)
        if let body { request.httpBody = try encoder.encode(body) }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = data.isEmpty ? nil : try? decoder.decode(EngagePayload.self, from: data)
        return AuthorizedResponse(statusCode: status, body: decoded)
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let problem = (try? decoder.decode(EngagePayload.self, from: data)) ?? [:]
            throw EngageHTTPError(
                statusCode: status,
                code: problem.string("code"),
                message: problem.string("message") ?? "Engage mobile edge returned HTTP \(status)"
            )
        }
    }

    private func authorized(
        path: String,
        method: String,
        credential: String,
        query: [String: String] = [:]
    ) -> URLRequest {
        var value = request(path: path, method: method, query: query)
        value.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        return value
    }

    private func request(path: String, method: String, query: [String: String] = [:]) -> URLRequest {
        let url = path.split(separator: "/").reduce(endpoint) { $0.appendingPathComponent(String($1)) }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map(URLQueryItem.init)
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if method != "GET" && request.httpBody == nil { request.httpBody = Data() }
        return request
    }
}

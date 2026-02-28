import Foundation

enum NetworkError: Error, LocalizedError {
  case notConfigured
  case unauthorized
  case invalidResponse
  case server(code: Int, message: String)

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      return "Supabase configuration is missing."
    case .unauthorized:
      return "You must sign in before making this request."
    case .invalidResponse:
      return "The server returned an invalid response."
    case let .server(code, message):
      return "Server error \(code): \(message)"
    }
  }
}

final class EdgeFunctionClient: @unchecked Sendable {
  private let configuration: AppConfiguration
  private let sessionProvider: @Sendable () async -> AuthSession?
  private let urlSession: URLSession

  init(
    configuration: AppConfiguration,
    sessionProvider: @escaping @Sendable () async -> AuthSession?,
    urlSession: URLSession = .shared
  ) {
    self.configuration = configuration
    self.sessionProvider = sessionProvider
    self.urlSession = urlSession
  }

  func invoke<Body: Encodable, Output: Decodable>(
    function: String,
    body: Body,
    requestIdentity: RequestIdentity,
    deviceID: String,
    platform: String = "iphone",
    appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
    osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
  ) async throws -> Output {
    guard let baseURL = configuration.edgeFunctionBaseURL ?? configuration.supabaseURL?.appending(path: "functions/v1") else {
      throw NetworkError.notConfigured
    }
    guard let authSession = await sessionProvider() else {
      throw NetworkError.unauthorized
    }

    var request = URLRequest(url: baseURL.appending(path: function))
    request.httpMethod = "POST"
    request.httpBody = try JSONCoding.encoder.encode(body)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(authSession.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue(requestIdentity.requestID.uuidString, forHTTPHeaderField: "x-request-id")
    request.setValue(requestIdentity.correlationID.uuidString, forHTTPHeaderField: "x-correlation-id")
    request.setValue(requestIdentity.idempotencyKey.uuidString, forHTTPHeaderField: "idempotency-key")
    request.setValue("1", forHTTPHeaderField: "x-contract-version")
    request.setValue(deviceID, forHTTPHeaderField: "x-device-id")
    request.setValue(platform, forHTTPHeaderField: "x-platform")
    request.setValue(appVersion, forHTTPHeaderField: "x-app-version")
    request.setValue(osVersion, forHTTPHeaderField: "x-os-version")

    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NetworkError.invalidResponse
    }
    guard (200 ..< 300).contains(httpResponse.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? "Unknown error"
      throw NetworkError.server(code: httpResponse.statusCode, message: message)
    }

    return try JSONCoding.decoder.decode(APIEnvelope<Output>.self, from: data).data
  }
}

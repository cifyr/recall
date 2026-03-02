import Foundation
import OSLog

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
  private let logger = Logger(subsystem: "com.caden.watchrecorder", category: "edge-functions")
  private let configuration: AppConfiguration
  private let sessionProvider: @Sendable (_ forceRefresh: Bool) async -> AuthSession?
  private let urlSession: URLSession

  init(
    configuration: AppConfiguration,
    sessionProvider: @escaping @Sendable (_ forceRefresh: Bool) async -> AuthSession?,
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
    return try await invokeManually(
      function: function,
      body: body,
      requestIdentity: requestIdentity,
      deviceID: deviceID,
      platform: platform,
      appVersion: appVersion,
      osVersion: osVersion
    )
  }

  private func invokeManually<Body: Encodable, Output: Decodable>(
    function: String,
    body: Body,
    requestIdentity: RequestIdentity,
    deviceID: String,
    platform: String,
    appVersion: String,
    osVersion: String
  ) async throws -> Output {
    guard let baseURL = configuration.edgeFunctionBaseURL ?? configuration.supabaseURL?.appending(path: "functions/v1") else {
      throw NetworkError.notConfigured
    }

    logger.info("[edge] Invoking \(function, privacy: .public)")

    // Always force-refresh to ensure the JWT is fresh and accepted by the gateway.
    var authSession = await sessionProvider(true)
    if authSession == nil {
      logger.info("[edge] Force-refresh returned nil, trying cached session for \(function, privacy: .public)")
      authSession = await sessionProvider(false)
    }
    guard let authSession else {
      logger.error("[edge] No auth session available for \(function, privacy: .public)")
      throw NetworkError.unauthorized
    }
    logger.info("[edge] Token ready for \(function, privacy: .public), user=\(authSession.userID.uuidString.prefix(8), privacy: .public)")

    var request = try makeRequest(
      baseURL: baseURL,
      function: function,
      body: body,
      requestIdentity: requestIdentity,
      deviceID: deviceID,
      platform: platform,
      appVersion: appVersion,
      osVersion: osVersion,
      accessToken: authSession.accessToken
    )

    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NetworkError.invalidResponse
    }

    if httpResponse.statusCode == 401 {
      let body = String(data: data, encoding: .utf8) ?? ""
      logger.error("[edge] \(function, privacy: .public) got 401: \(body, privacy: .public)")
      logger.info("[edge] Force-refreshing token and retrying \(function, privacy: .public)")
      if let refreshedSession = await sessionProvider(true) {
        request.setValue("Bearer \(refreshedSession.accessToken)", forHTTPHeaderField: "Authorization")
        let (retryData, retryResponse) = try await urlSession.data(for: request)
        guard let retryHTTPResponse = retryResponse as? HTTPURLResponse else {
          throw NetworkError.invalidResponse
        }
        guard (200 ..< 300).contains(retryHTTPResponse.statusCode) else {
          let retryMessage = String(data: retryData, encoding: .utf8) ?? "Unknown error"
          logger.error("[edge] \(function, privacy: .public) retry failed: \(retryHTTPResponse.statusCode, privacy: .public) \(retryMessage, privacy: .public)")
          throw NetworkError.server(code: retryHTTPResponse.statusCode, message: retryMessage)
        }
        logger.info("[edge] \(function, privacy: .public) retry succeeded")
        return try JSONCoding.decoder.decode(APIEnvelope<Output>.self, from: retryData).data
      } else {
        logger.error("[edge] Token refresh returned nil, cannot retry \(function, privacy: .public)")
        throw NetworkError.unauthorized
      }
    }

    guard (200 ..< 300).contains(httpResponse.statusCode) else {
      let message = String(data: data, encoding: .utf8) ?? "Unknown error"
      logger.error("[edge] \(function, privacy: .public) failed: \(httpResponse.statusCode, privacy: .public) \(message, privacy: .public)")
      throw NetworkError.server(code: httpResponse.statusCode, message: message)
    }

    logger.info("[edge] \(function, privacy: .public) succeeded")
    return try JSONCoding.decoder.decode(APIEnvelope<Output>.self, from: data).data
  }

  private func requestHeaders(
    requestIdentity: RequestIdentity,
    deviceID: String,
    platform: String,
    appVersion: String,
    osVersion: String
  ) -> [String: String] {
    [
      "x-request-id": requestIdentity.requestID.uuidString,
      "x-correlation-id": requestIdentity.correlationID.uuidString,
      "idempotency-key": requestIdentity.idempotencyKey.uuidString,
      "x-contract-version": "1",
      "x-device-id": deviceID,
      "x-platform": platform,
      "x-app-version": appVersion,
      "x-os-version": osVersion,
    ]
  }

  private func makeRequest<Body: Encodable>(
    baseURL: URL,
    function: String,
    body: Body,
    requestIdentity: RequestIdentity,
    deviceID: String,
    platform: String,
    appVersion: String,
    osVersion: String,
    accessToken: String
  ) throws -> URLRequest {
    var request = URLRequest(url: baseURL.appending(path: function))
    request.httpMethod = "POST"
    request.httpBody = try JSONCoding.encoder.encode(body)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(configuration.supabaseKey, forHTTPHeaderField: "apikey")
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("watch-recorder-ios/\(appVersion)", forHTTPHeaderField: "x-client-info")
    for (field, value) in requestHeaders(
      requestIdentity: requestIdentity,
      deviceID: deviceID,
      platform: platform,
      appVersion: appVersion,
      osVersion: osVersion
    ) {
      request.setValue(value, forHTTPHeaderField: field)
    }
    return request
  }
}

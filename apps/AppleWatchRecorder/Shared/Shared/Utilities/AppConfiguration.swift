import Foundation

struct AppConfiguration: Sendable {
  let supabaseURL: URL?
  let supabaseKey: String
  let edgeFunctionBaseURL: URL?
  let redirectURL: URL?

  static func current(bundle: Bundle = .main) -> AppConfiguration {
    let info = bundle.infoDictionary ?? [:]
    let urlString = info["SUPABASE_URL"] as? String
    let key = (info["SUPABASE_ANON_KEY"] as? String)
      ?? (info["SUPABASE_PUBLISHABLE_KEY"] as? String)
      ?? ""
    let edgeString = info["EDGE_FUNCTION_BASE_URL"] as? String
    let redirectString = info["AUTH_REDIRECT_URL"] as? String
    return AppConfiguration(
      supabaseURL: urlString.flatMap(URL.init(string:)),
      supabaseKey: key,
      edgeFunctionBaseURL: edgeString.flatMap(URL.init(string:)),
      redirectURL: redirectString.flatMap(URL.init(string:))
    )
  }

  var isConfigured: Bool {
    supabaseURL != nil && !supabaseKey.isEmpty
  }
}

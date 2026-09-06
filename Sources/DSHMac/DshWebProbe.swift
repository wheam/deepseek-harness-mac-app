import Foundation

/// A title alone does not prove that an existing server can boot. Older dsh
/// processes can keep a pre-batch graph in memory while serving newly installed
/// client modules from disk (even under a correctly refreshed revision hash).
enum DshWebProbe {
  enum BootCheck: Equatable {
    case compatible
    case incompatible
    case legacyLoader(URL)
  }

  private static let bootAssignment = try! NSRegularExpression(
    pattern: #"(?:globalThis|window)\s*(?:\[\s*["']__DSH_BOOT__["']\s*\]|\.__DSH_BOOT__)\s*=\s*([\s\S]*?)\s*;?\s*</script\s*>"#)

  static func bootCheck(html: String, baseURL: URL) -> BootCheck {
    let range = NSRange(html.startIndex..., in: html)
    guard let match = bootAssignment.firstMatch(in: html, range: range),
      let jsonRange = Range(match.range(at: 1), in: html) else {
      // Older, pre-module-system releases have no boot graph to check.
      return .compatible
    }
    guard let data = String(html[jsonRange]).data(using: .utf8),
      let graph = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      graph["rev"] is String,
      let entries = graph["entries"] as? [[String: Any]] else { return .incompatible }
    if let batches = graph["batches"] {
      return batches is [Any] ? .compatible : .incompatible
    }
    // Do not reject a healthy legacy server just because it predates batches.
    // Check the client it actually serves, not the locally installed CLI.
    guard let loader = entries.first(where: { $0["id"] as? String == "@deepseek-ai/dsh-client-modules" }),
      let path = loader["url"] as? String,
      let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
      url.scheme == baseURL.scheme, url.host == baseURL.host, url.port == baseURL.port,
      url.user == nil, url.password == nil, url.path.hasPrefix("/plugins/") else {
      return .incompatible
    }
    return .legacyLoader(url)
  }

  /// `session` is injectable for HTTP regression tests. Production requests
  /// neither use cached responses nor follow redirects away from loopback.
  static func probe(
    port: Int,
    session suppliedSession: URLSession? = nil,
    completion: @escaping (ProbeResult) -> Void
  ) {
    let session = suppliedSession ?? URLSession(
      configuration: .ephemeral, delegate: NoProbeRedirects(), delegateQueue: nil)
    let finish: (ProbeResult) -> Void = { result in
      if suppliedSession == nil { session.finishTasksAndInvalidate() }
      completion(result)
    }
    let url = URL(string: "http://127.0.0.1:\(port)/")!
    session.dataTask(with: request(url)) { data, response, error in
      if let error {
        // A timeout is not evidence that the port is free.
        finish((error as? URLError)?.code == .cannotConnectToHost ? .free : .otherService)
        return
      }
      guard let html = responseText(data, response), html.contains("DeepSeek Harness") else {
        finish(.otherService)
        return
      }
      switch bootCheck(html: html, baseURL: url) {
      case .compatible:
        finish(.dshReady(port: port))
      case .incompatible:
        finish(.incompatibleDsh)
      case .legacyLoader(let loaderURL):
        session.dataTask(with: request(loaderURL)) { data, response, _ in
          guard let source = responseText(data, response), !source.isEmpty else {
            finish(.incompatibleDsh)
            return
          }
          // This is the client-side wire validation introduced with batches.
          // Inspect text only: never execute a probed server's JavaScript.
          finish(source.contains("boot manifest batches must be an array")
            ? .incompatibleDsh : .dshReady(port: port))
        }.resume()
      }
    }.resume()
  }

  private static func request(_ url: URL) -> URLRequest {
    URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
  }

  private static func responseText(_ data: Data?, _ response: URLResponse?) -> String? {
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      let data else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

private final class NoProbeRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

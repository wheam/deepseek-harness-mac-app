import XCTest
@testable import DSHMac

final class DshWebProbeTests: XCTestCase {
  private let baseURL = URL(string: "http://127.0.0.1:3080/")!
  private let loaderPath = "/plugins/@deepseek-ai/dsh-client-modules/client.js?rev=abc"

  private func page(batches: String? = nil, loader: String? = nil) -> String {
    let batchField = batches.map { ",\"batches\":\($0)" } ?? ""
    return """
      <title>DeepSeek Harness</title><script>globalThis["__DSH_BOOT__"] =
      {"rev":"abc","entries":[{"id":"@deepseek-ai/dsh-client-modules","url":"\(loader ?? loaderPath)","rev":"abc"}]\(batchField)};</script>
      """
  }

  func testLegacyManifestChecksTheAdvertisedClientRevision() {
    XCTAssertEqual(DshWebProbe.bootCheck(html: page(), baseURL: baseURL),
      .legacyLoader(URL(string: loaderPath, relativeTo: baseURL)!.absoluteURL))
  }

  func testModernGraphAndPreModuleSystemPagesRemainSupported() {
    XCTAssertEqual(DshWebProbe.bootCheck(html: page(batches: "[]"), baseURL: baseURL), .compatible)
    XCTAssertEqual(DshWebProbe.bootCheck(html: "<title>DeepSeek Harness</title>", baseURL: baseURL), .compatible)
    let windowAssignment = page(batches: "[]")
      .replacingOccurrences(of: "globalThis[\"__DSH_BOOT__\"]", with: "window.__DSH_BOOT__")
    XCTAssertEqual(DshWebProbe.bootCheck(html: windowAssignment, baseURL: baseURL), .compatible)
  }

  func testMalformedManifestsAreNotAttached() {
    for batches in ["null", "{}", "\"array\""] {
      XCTAssertEqual(DshWebProbe.bootCheck(html: page(batches: batches), baseURL: baseURL), .incompatible)
    }
    let invalidJSON = "<script>globalThis['__DSH_BOOT__'] = notJSON;</script>"
    XCTAssertEqual(DshWebProbe.bootCheck(html: invalidJSON, baseURL: baseURL), .incompatible)
  }

  func testAdvertisedLoaderCannotSendTheProbeOutsideItsOrigin() {
    for path in ["https://example.com/plugins/client.js", "//example.com/plugins/client.js",
      "http://127.0.0.1:9999/plugins/client.js", "/api/settings", "http://user@127.0.0.1:3080/plugins/client.js"] {
      XCTAssertEqual(DshWebProbe.bootCheck(html: page(loader: path), baseURL: baseURL), .incompatible)
    }
  }

  func testOldServerServingNewClientIsRejectedEvenWithAValidTitleAndRevision() {
    assertProbe(html: page(), loader: "throw new Error('client-modules: boot manifest batches must be an array')",
      expected: .incompatibleDsh)
  }

  func testHealthyLegacyServerIsStillReused() {
    assertProbe(html: page(), loader: "window.__ModuleLoader__.load({ id: '@deepseek-ai/dsh-client-modules' });",
      expected: .dshReady(port: 3080))
  }

  func testModernServerDoesNotDownloadTheLegacyClient() {
    assertProbe(html: page(batches: "[]"), expected: .dshReady(port: 3080))
  }

  func testMissingOrFailedLegacyClientIsNotReused() {
    assertProbe(html: page(), loader: "", expected: .incompatibleDsh)
    assertProbe(html: page(), loader: "not found", loaderStatus: 404, expected: .incompatibleDsh)
    assertProbe(html: page(), loader: "revision changed", loaderStatus: 409, expected: .incompatibleDsh)
  }

  func testErrorPagesAndUnrelatedServicesAreNotMistakenForDsh() {
    assertProbe(html: page(), status: 404, expected: .otherService)
    assertProbe(html: page(), status: 500, expected: .otherService)
    assertProbe(html: "another service", expected: .otherService)
  }

  func testOnlyConnectionRefusalMeansThePortIsFree() {
    assertProbe(error: URLError(.cannotConnectToHost), expected: .free)
    assertProbe(error: URLError(.timedOut), expected: .otherService)
  }

  private func assertProbe(
    html: String = "", status: Int = 200, loader: String? = nil, loaderStatus: Int = 200,
    error: Error? = nil, expected: ProbeResult, file: StaticString = #filePath, line: UInt = #line
  ) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProbeURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    ProbeURLProtocol.respond = { request in
      XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData, file: file, line: line)
      XCTAssertEqual(request.timeoutInterval, 2, file: file, line: line)
      if let error { throw error }
      if request.url?.path == "/" { return (status, html) }
      XCTAssertEqual(request.url?.absoluteString, self.baseURL.absoluteString.dropLast() + self.loaderPath,
        file: file, line: line)
      XCTAssertNotNil(loader, "Unexpected legacy client fetch", file: file, line: line)
      return (loaderStatus, loader ?? "")
    }
    let done = expectation(description: "probe completed")
    DshWebProbe.probe(port: 3080, session: session) { result in
      XCTAssertEqual(result, expected, file: file, line: line)
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
  }
}

private final class ProbeURLProtocol: URLProtocol {
  static var respond: ((URLRequest) throws -> (Int, String))!
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, body) = try Self.respond(request)
      let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }
  override func stopLoading() {}
}

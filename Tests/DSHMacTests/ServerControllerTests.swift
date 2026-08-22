import XCTest
@testable import DSHMac

final class ServerControllerTests: XCTestCase {
  func testSpawnArgumentsDisableExternalBrowser() {
    XCTAssertEqual(ServerController.webArguments(port: nil), ["web", "--no-open"])
    XCTAssertEqual(
      ServerController.webArguments(port: 4123),
      ["web", "--no-open", "--port", "4123"])
  }
}

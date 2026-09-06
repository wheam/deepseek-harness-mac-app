import XCTest
@testable import DSHMac

final class ServerControllerTests: XCTestCase {
  func testReadinessPreservesTheBrowserAuthenticationToken() {
    let address = "http://127.0.0.1:4123/?token=test-token_123&mode=web"
    XCTAssertEqual(ServerController.readyURL(from: "dsh web: \(address)")?.absoluteString, address)
    XCTAssertEqual(ServerController.readyURL(from: "dsh web: http://127.0.0.1:3080")?.port, 3080)
    XCTAssertEqual(ServerController.readyURL(from: "dsh web: http://127.0.0.1:3080/")?.path, "/")
    XCTAssertNil(ServerController.readyURL(from: "dsh web: http://127.0.0.1.evil.test:3080/"))
    XCTAssertNil(ServerController.readyURL(from: "dsh web: http://127.0.0.1:0/"))
    XCTAssertNil(ServerController.readyURL(from: "dsh web: http://user@127.0.0.1:3080/"))
    XCTAssertNil(ServerController.readyURL(from: "dsh web: http://127.0.0.1:3080/unrelated"))
  }

  func testBrowserTokensAreRedactedFromLogsAndFailureTails() {
    XCTAssertEqual(AppLog.redactingTokens("dsh web: http://127.0.0.1:4123/?token=test-token&x=1"),
      "dsh web: http://127.0.0.1:4123/?token=<redacted>&x=1")
    XCTAssertEqual(AppLog.redactingTokens("loading /?x=1&token=secret\nnext line"),
      "loading /?x=1&token=<redacted>\nnext line")
    XCTAssertEqual(AppLog.redactingTokens("dsh web: http://127.0.0.1:3080/"),
      "dsh web: http://127.0.0.1:3080/")
  }

  func testSpawnArgumentsDisableExternalBrowser() {
    XCTAssertEqual(ServerController.webArguments(port: nil), ["web", "--no-open"])
    XCTAssertEqual(
      ServerController.webArguments(port: 4123),
      ["web", "--no-open", "--port", "4123"])
  }

  func testOccupiedDefaultPortFallsBackToAnOsAssignedPort() {
    XCTAssertEqual(
      ServerController.startupDecision(
        for: .otherService,
        targetPort: 3080,
        hasExplicitPort: false,
        forceSpawn: false),
      .spawn(port: 0))
  }

  func testExistingDshIsAttachedUnlessForceSpawnWasRequested() {
    XCTAssertEqual(
      ServerController.startupDecision(
        for: .dshReady(port: 3080),
        targetPort: 3080,
        hasExplicitPort: false,
        forceSpawn: false),
      .attach(port: 3080))
    XCTAssertEqual(
      ServerController.startupDecision(
        for: .dshReady(port: 3080),
        targetPort: 3080,
        hasExplicitPort: false,
        forceSpawn: true),
      .spawn(port: 0))
  }

  func testFreeExplicitPortIsPreserved() {
    XCTAssertEqual(
      ServerController.startupDecision(
        for: .free,
        targetPort: 4123,
        hasExplicitPort: true,
        forceSpawn: false),
      .spawn(port: 4123))
  }

  func testIncompatibleDshIsBypassedEvenOnAnExplicitPort() {
    for explicit in [false, true] {
      XCTAssertEqual(ServerController.startupDecision(
        for: .incompatibleDsh, targetPort: 3080, hasExplicitPort: explicit, forceSpawn: false),
        .spawn(port: 0))
    }
    XCTAssertEqual(ServerController.replacementPort(
      afterAttachedProbe: .incompatibleDsh, attachedPort: 3080), 0)
  }

  func testAttachedServerRecoveryReusesThePortOnlyWhenItIsFree() {
    XCTAssertNil(ServerController.replacementPort(
      afterAttachedProbe: .dshReady(port: 3080), attachedPort: 3080))
    XCTAssertEqual(ServerController.replacementPort(
      afterAttachedProbe: .free, attachedPort: 3080), 3080)
    XCTAssertEqual(ServerController.replacementPort(
      afterAttachedProbe: .otherService, attachedPort: 3080), 0)
  }
}

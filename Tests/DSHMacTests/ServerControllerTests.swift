import XCTest
@testable import DSHMac

final class ServerControllerTests: XCTestCase {
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

  func testAttachedServerRecoveryReusesThePortOnlyWhenItIsFree() {
    XCTAssertNil(ServerController.replacementPort(
      afterAttachedProbe: .dshReady(port: 3080), attachedPort: 3080))
    XCTAssertEqual(ServerController.replacementPort(
      afterAttachedProbe: .free, attachedPort: 3080), 3080)
    XCTAssertEqual(ServerController.replacementPort(
      afterAttachedProbe: .otherService, attachedPort: 3080), 0)
  }
}

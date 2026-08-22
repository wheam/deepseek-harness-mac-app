import Foundation
import XCTest
@testable import DSHMac

final class AppUpdaterTests: XCTestCase {
  func testDshInstallUsesResolvedNpmGlobalPrefixByDefault() {
    let arguments = AppUpdater.globalDshInstallArguments()

    XCTAssertTrue(arguments.contains("-g"))
    XCTAssertFalse(arguments.contains("--prefix"))
    XCTAssertTrue(arguments.contains("@deepseek-ai/dsh@latest"))
  }

  func testDshUpdateCanStayInSharedUserGlobalPrefix() {
    let arguments = AppUpdater.globalDshInstallArguments(prefix: "/Users/test/.local")

    XCTAssertTrue(arguments.contains("-g"))
    XCTAssertEqual(
      Array(arguments.dropFirst(2).prefix(2)), ["--prefix", "/Users/test/.local"])
    XCTAssertFalse(arguments.joined(separator: " ").contains("Application Support"))
  }

  func testGlobalPrefixIsDerivedFromResolvedDshPackage() {
    XCTAssertEqual(
      AppUpdater.globalNpmPrefix(
        forDshPath: "/Users/test/.local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js"),
      "/Users/test/.local")
    XCTAssertNil(AppUpdater.globalNpmPrefix(forDshPath: "/tmp/project/node_modules/.bin/dsh"))
  }

  func testReleaseDigestNormalizationRejectsMalformedValues() {
    let digest = String(repeating: "a", count: 64)
    XCTAssertEqual(ReleaseTrust.normalizedSHA256Digest("sha256:\(digest)"), digest)
    XCTAssertEqual(ReleaseTrust.normalizedSHA256Digest(digest.uppercased()), digest)
    XCTAssertNil(ReleaseTrust.normalizedSHA256Digest("sha256:not-a-digest"))
    XCTAssertNil(ReleaseTrust.normalizedSHA256Digest(nil))
  }

  func testReleaseSHA256Implementation() {
    XCTAssertEqual(
      ReleaseTrust.sha256Hex(Data("abc".utf8)),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  func testRelaunchWaitsForOldProcessAndKeepsBundlePathOutOfShellSource() {
    let hostilePath = "/Applications/DeepSeek Harness.app; touch /tmp/should-not-run"
    let arguments = AppUpdater.relaunchHelperArguments(currentPID: 123, bundlePath: hostilePath)

    XCTAssertEqual(arguments[0], "-c")
    XCTAssertTrue(arguments[1].contains("/bin/kill -0 \"$1\""))
    XCTAssertTrue(arguments[1].contains("/usr/bin/open -n \"$2\""))
    XCTAssertFalse(arguments[1].contains(hostilePath))
    XCTAssertEqual(Array(arguments.suffix(2)), ["123", hostilePath])
  }

  func testReleaseTrustAcceptsSignedBuildWhenProvided() throws {
    guard let appPath = ProcessInfo.processInfo.environment["DSH_SIGNED_APP_UNDER_TEST"] else {
      throw XCTSkip("set DSH_SIGNED_APP_UNDER_TEST for release-bundle verification")
    }
    XCTAssertNoThrow(
      try ReleaseTrust.verifyAppBundle(at: URL(fileURLWithPath: appPath)))
  }
}

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
}

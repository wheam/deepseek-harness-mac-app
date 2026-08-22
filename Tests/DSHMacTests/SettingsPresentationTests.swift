import XCTest
@testable import DSHMac

final class SettingsPresentationTests: XCTestCase {
  func testUsesStableSemanticDialogSelectors() {
    let source = SettingsPresentation.script.source

    XCTAssertTrue(source.contains(#"[role="dialog"][aria-modal="true"]"#))
    XCTAssertTrue(source.contains("aria-labelledby"))
    XCTAssertTrue(source.contains("data-dsh-mac-settings-dialog"))
    XCTAssertFalse(source.contains("VOzbGW_"), "Must not depend on dsh CSS-module hashes")
  }

  func testConstrainsHeightWithoutClippingLongSettingsPages() {
    let source = SettingsPresentation.script.source

    XCTAssertTrue(source.contains("height: auto !important"))
    XCTAssertTrue(source.contains("max-height: min(720px, calc(100vh - 64px))"))
    XCTAssertTrue(source.contains("overflow-y: auto"))
  }
}

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

  func testReportsSemanticDialogStateAndThemeMaskToNativeCode() {
    let source = SettingsPresentation.script.source

    XCTAssertEqual(SettingsPresentation.messageName, "dshSettingsPresentation")
    XCTAssertTrue(source.contains("messageHandlers.dshSettingsPresentation"))
    XCTAssertTrue(source.contains("--dsw-alias-bg-mask-1"))
    XCTAssertTrue(source.contains("handler.postMessage(payload)"))
  }

  func testDecodesSettingsPresentationStateAtNativeBoundary() throws {
    let open = try XCTUnwrap(SettingsPresentationState(body: [
      "open": true,
      "maskRGBA": [0, 0, 0, 61],
    ]))
    XCTAssertTrue(open.isOpen)
    XCTAssertEqual(open.mask, PageRGBAColor(jsonValue: [0, 0, 0, 61]))

    let closed = try XCTUnwrap(SettingsPresentationState(body: ["open": false]))
    XCTAssertFalse(closed.isOpen)
    XCTAssertNil(closed.mask)
  }

  func testRejectsMalformedSettingsPresentationState() {
    XCTAssertNil(SettingsPresentationState(body: ["open": "true"]))
    XCTAssertNil(SettingsPresentationState(body: [
      "open": true,
      "maskRGBA": [0, 0, 0, 300],
    ]))
  }

  func testTitlebarModalDimViewDoesNotInterceptDragging() {
    let strip = TitleStripView(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
    let dim = TitlebarModalDimView(frame: strip.bounds)
    strip.addSubview(dim)

    XCTAssertNil(dim.hitTest(NSPoint(x: 100, y: 14)))
    XCTAssertTrue(strip.hitTest(NSPoint(x: 100, y: 14)) === strip)
    XCTAssertTrue(strip.mouseDownCanMoveWindow)
  }
}

import AppKit
import XCTest
@testable import DSHMac

final class TitlebarThemeTests: XCTestCase {
  func testDecodesBrowserResolvedByteColors() throws {
    let theme = try XCTUnwrap(PageTitlebarTheme(json: try payload("""
      {
        "ok": true,
        "sidebarRGBA": [249, 250, 251, 255],
        "contentRGBA": [255, 255, 255, 255],
        "borderRGBA": [0, 0, 0, 10],
        "sidebarWidth": 280,
        "dark": false
      }
      """)))

    XCTAssertEqual(theme.sidebar, PageRGBAColor(jsonValue: [249, 250, 251, 255]))
    XCTAssertEqual(theme.content, PageRGBAColor(jsonValue: [255, 255, 255, 255]))
    XCTAssertEqual(theme.border, PageRGBAColor(jsonValue: [0, 0, 0, 10]))
    XCTAssertEqual(theme.sidebarWidth, 280)
    XCTAssertFalse(theme.dark)

    let border = try XCTUnwrap(theme.border?.nsColor.usingColorSpace(.deviceRGB))
    XCTAssertEqual(border.alphaComponent, 10.0 / 255.0, accuracy: 0.0001)
  }

  func testBorderColorIsOptional() throws {
    let theme = try XCTUnwrap(PageTitlebarTheme(json: try payload("""
      {
        "ok": true,
        "sidebarRGBA": [27, 27, 28, 255],
        "contentRGBA": [21, 21, 23, 255],
        "sidebarWidth": 64,
        "dark": true
      }
      """)))

    XCTAssertNil(theme.border)
    XCTAssertTrue(theme.dark)
  }

  func testRejectsCSSStringsAndInvalidGeometryAtNativeBoundary() throws {
    XCTAssertNil(PageTitlebarTheme(json: try payload("""
      {
        "ok": true,
        "sidebarRGBA": "#f9fafb",
        "contentRGBA": "rgb(255, 255, 255)",
        "sidebarWidth": 280
      }
      """)))
    XCTAssertNil(PageTitlebarTheme(json: try payload("""
      {
        "ok": true,
        "sidebarRGBA": [249, 250, 251, 255],
        "contentRGBA": [255, 255, 255, 255],
        "sidebarWidth": 0
      }
      """)))
  }

  func testRejectsOutOfRangeComponents() {
    XCTAssertNil(PageRGBAColor(jsonValue: [256, 0, 0, 255]))
    XCTAssertNil(PageRGBAColor(jsonValue: [-1, 0, 0, 255]))
    XCTAssertNil(PageRGBAColor(jsonValue: [0, 0, 0]))
  }

  func testTranslucentBlackOverlayDoesNotClaimThePageIsDark() throws {
    let theme = try XCTUnwrap(PageTitlebarTheme(json: try payload("""
      {
        "ok": true,
        "sidebarRGBA": [249, 250, 251, 255],
        "contentRGBA": [0, 0, 0, 61],
        "sidebarWidth": 280,
        "dark": true
      }
      """)))

    XCTAssertFalse(theme.dark)
  }

  func testTrafficLightStylingDoesNotOverrideTheWindowAppearance() throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    window.appearance = nil

    TitlebarTrafficLightStyler.apply(dark: true, to: window)

    XCTAssertNil(window.appearance)
    for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      let appearance = try XCTUnwrap(window.standardWindowButton(buttonType)?.appearance)
      XCTAssertEqual(appearance.name, .darkAqua)
    }

    TitlebarTrafficLightStyler.reset(in: window)
    for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      XCTAssertNil(window.standardWindowButton(buttonType)?.appearance)
    }
  }

  func testTransientFailuresRetainStateUntilThirdConsecutiveFailure() {
    var guardState = TitlebarThemeSampleGuard()

    XCTAssertFalse(guardState.recordFailure())
    XCTAssertFalse(guardState.recordFailure())
    XCTAssertEqual(guardState.consecutiveFailures, 2)

    guardState.recordSuccess()
    XCTAssertEqual(guardState.consecutiveFailures, 0)
    XCTAssertFalse(guardState.recordFailure())
    XCTAssertFalse(guardState.recordFailure())
    XCTAssertTrue(guardState.recordFailure())
  }

  private func payload(_ json: String) throws -> [String: Any] {
    let data = try XCTUnwrap(json.data(using: .utf8))
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}

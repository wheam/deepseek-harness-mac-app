import AppKit
import XCTest
@testable import DSHMac

final class NativeWebIntegrationTests: XCTestCase {
  func testFiltersOnlyBrowserChromeContextItems() {
    let reload = NSMenuItem(title: "Reload", action: nil, keyEquivalent: "")
    reload.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierReload")
    let copy = NSMenuItem(
      title: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: "")
    copy.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopy")

    XCTAssertTrue(NativeWebView.isBrowserChrome(reload))
    XCTAssertFalse(NativeWebView.isBrowserChrome(copy))
  }

  func testSeparatorCleanupRemovesEdgesAndDuplicates() {
    let menu = NSMenu()
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Copy", action: nil, keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(.separator())

    NativeWebView.removeOrphanedSeparators(from: menu)

    XCTAssertEqual(menu.items.count, 1)
    XCTAssertEqual(menu.items.first?.title, "Copy")
  }

  func testContextMenuRequestValidatesTokensTitlesAndBounds() throws {
    let request = try XCTUnwrap(WebContextMenuRequest(body: [
      "x": NSNumber(value: 120),
      "y": NSNumber(value: 240),
      "actions": [[
        "token": "dshctx_abc_0",
        "title": "归档",
        "destructive": true,
      ]],
    ]))

    XCTAssertEqual(request.x, 120)
    XCTAssertEqual(request.y, 240)
    XCTAssertEqual(request.actions, [
      WebContextMenuAction(token: "dshctx_abc_0", title: "归档", destructive: true),
    ])
    XCTAssertNil(WebContextMenuRequest(body: [
      "x": NSNumber(value: 1),
      "y": NSNumber(value: 2),
      "actions": [["token": "bad\" selector", "title": "Delete"]],
    ]))
  }

  func testSuggestedDownloadFilenameCannotEscapeTheChosenDirectory() {
    XCTAssertEqual(WebViewController.safeSuggestedFilename("../../private.zip"), "private.zip")
    XCTAssertEqual(WebViewController.safeSuggestedFilename("report:today.zip"), "report-today.zip")
    XCTAssertEqual(WebViewController.safeSuggestedFilename(".."), "DeepSeek-Harness-Download")
  }
}

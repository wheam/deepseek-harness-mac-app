import AppKit
import XCTest
@testable import DSHMac

final class MainMenuBuilderTests: XCTestCase {
  func testBuildsStandardMacMenuHierarchyAndKeyEquivalents() throws {
    let delegate = AppDelegate(options: LaunchOptions())
    let menus = MainMenuBuilder.build(appName: "DeepSeek Harness", target: delegate)

    XCTAssertEqual(
      menus.main.items.map(\.title),
      ["DeepSeek Harness", "文件", "编辑", "显示", "窗口", "帮助"])

    let settings = try item(tag: .settings, in: menus.main)
    XCTAssertEqual(settings.title, "设置…")
    XCTAssertEqual(settings.keyEquivalent, ",")
    XCTAssertEqual(settings.keyEquivalentModifierMask, [.command])

    let newSession = try item(tag: .newSession, in: menus.main)
    XCTAssertEqual(newSession.keyEquivalent, "n")
    XCTAssertEqual(newSession.keyEquivalentModifierMask, [.command])

    let find = try item(tag: .find, in: menus.main)
    XCTAssertEqual(find.keyEquivalent, "f")
    let previous = try item(tag: .findPrevious, in: menus.main)
    XCTAssertEqual(previous.keyEquivalentModifierMask, [.command, .shift])

    let sessionSearch = try item(tag: .focusSessionSearch, in: menus.main)
    XCTAssertEqual(sessionSearch.keyEquivalentModifierMask, [.command, .option])
    let fullscreen = try XCTUnwrap(findItem(titled: "进入全屏幕", in: menus.main))
    XCTAssertEqual(fullscreen.keyEquivalentModifierMask, [.command, .control])

    XCTAssertTrue(findItem(titled: "服务", in: menus.main)?.submenu === menus.services)
    XCTAssertTrue(menus.main.item(withTitle: "窗口")?.submenu === menus.windows)
    XCTAssertTrue(menus.main.item(withTitle: "帮助")?.submenu === menus.help)
  }

  func testEveryShellCommandHasTheAppDelegateAsItsTarget() throws {
    let delegate = AppDelegate(options: LaunchOptions())
    let menus = MainMenuBuilder.build(appName: "DeepSeek Harness", target: delegate)

    for tag in [
      MainMenuCommandTag.settings, .newSession, .openInBrowser, .printPage,
      .find, .findNext, .findPrevious, .focusSessionSearch, .toggleSidebar,
      .reload, .actualSize, .zoomIn, .zoomOut, .help,
    ] {
      XCTAssertTrue(try item(tag: tag, in: menus.main).target === delegate)
    }
  }

  private func item(tag: MainMenuCommandTag, in menu: NSMenu) throws -> NSMenuItem {
    try XCTUnwrap(allItems(in: menu).first(where: { $0.tag == tag.rawValue }))
  }

  private func findItem(titled title: String, in menu: NSMenu) -> NSMenuItem? {
    allItems(in: menu).first(where: { $0.title == title })
  }

  private func allItems(in menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { item in
      [item] + (item.submenu.map(allItems(in:)) ?? [])
    }
  }
}

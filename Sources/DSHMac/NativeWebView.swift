import AppKit
import WebKit

/// WKWebView's text/link contextual items are useful native macOS commands,
/// but its browser chrome (Reload, Back, Inspect, and friends) does not belong
/// in this single-purpose app shell.
final class NativeWebView: WKWebView {
  var backgroundMenuProvider: (() -> [NSMenuItem])?

  private static let browserItemIdentifiers: Set<String> = [
    "WKMenuItemIdentifierReload",
    "WKMenuItemIdentifierReloadFromOrigin",
    "WKMenuItemIdentifierStop",
    "WKMenuItemIdentifierBack",
    "WKMenuItemIdentifierForward",
    "WKMenuItemIdentifierGoBack",
    "WKMenuItemIdentifierGoForward",
    "WKMenuItemIdentifierOpenFrameInNewWindow",
    "WKMenuItemIdentifierInspectElement",
  ]

  private static let browserActionNames: Set<String> = [
    "reload:",
    "reloadFromOrigin:",
    "stopLoading:",
    "goBack:",
    "goForward:",
    "inspectElement:",
    "_inspectElement:",
  ]

  override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
    super.willOpenMenu(menu, with: event)
    for menuItem in menu.items where Self.isBrowserChrome(menuItem) {
      menu.removeItem(menuItem)
    }
    Self.removeOrphanedSeparators(from: menu)

    // An unselected background otherwise exposes only WebKit's Reload item.
    // Replace that browser menu with a few app-level actions; text editing,
    // links, Look Up, Translate, Share, Speech, and Services remain untouched.
    if !menu.items.contains(where: { !$0.isSeparatorItem }) {
      menu.removeAllItems()
      for menuItem in backgroundMenuProvider?() ?? [] { menu.addItem(menuItem) }
      Self.removeOrphanedSeparators(from: menu)
    }
  }

  static func isBrowserChrome(_ item: NSMenuItem) -> Bool {
    if let identifier = item.identifier?.rawValue,
      browserItemIdentifiers.contains(identifier) {
      return true
    }
    if let action = item.action,
      browserActionNames.contains(NSStringFromSelector(action)) {
      return true
    }
    return false
  }

  static func removeOrphanedSeparators(from menu: NSMenu) {
    while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
    while menu.items.last?.isSeparatorItem == true {
      menu.removeItem(at: menu.items.count - 1)
    }
    var index = menu.items.count - 1
    while index > 0 {
      if menu.items[index].isSeparatorItem && menu.items[index - 1].isSeparatorItem {
        menu.removeItem(at: index)
      }
      index -= 1
    }
  }
}

struct WebContextMenuAction: Equatable {
  let token: String
  let title: String
  let destructive: Bool
}

/// Strict native boundary for object-specific context-menu messages sent by
/// the injected page bridge.
struct WebContextMenuRequest: Equatable {
  let x: Double
  let y: Double
  let actions: [WebContextMenuAction]

  init?(body: Any) {
    guard let json = body as? [String: Any],
      let x = (json["x"] as? NSNumber)?.doubleValue,
      let y = (json["y"] as? NSNumber)?.doubleValue,
      x.isFinite, y.isFinite,
      let rows = json["actions"] as? [[String: Any]],
      !rows.isEmpty, rows.count <= 8 else { return nil }

    var decoded: [WebContextMenuAction] = []
    for row in rows {
      guard let token = row["token"] as? String,
        token.range(of: #"^[A-Za-z0-9_-]{1,80}$"#, options: .regularExpression) != nil,
        let title = row["title"] as? String else { return nil }
      let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !cleanTitle.isEmpty, cleanTitle.count <= 80 else { return nil }
      decoded.append(WebContextMenuAction(
        token: token,
        title: cleanTitle,
        destructive: row["destructive"] as? Bool ?? false))
    }
    self.x = x
    self.y = y
    self.actions = decoded
  }
}

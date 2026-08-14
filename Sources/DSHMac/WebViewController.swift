import AppKit
import WebKit

/// The top strip that replaces the transparent-titlebar background: it is
/// painted two-tone (sidebar color over the sidebar width, content color
/// over the rest) so the window top continues the page's column colors
/// seamlessly. Hits collapse to the strip itself only when the point is
/// actually inside it, so drags on the strip move the window while every
/// other click falls through to the page.
final class TitleStripView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    // Respect hidden state and bounds; only then claim the hit for dragging.
    guard super.hitTest(point) != nil else { return nil }
    return self
  }
  override var mouseDownCanMoveWindow: Bool { true }
}

/// Weak-indirection script-message handler: `WKUserContentController` retains
/// its handlers, so forwarding through a proxy avoids a retain cycle with the
/// owning view controller.
final class ThemeMessageProxy: NSObject, WKScriptMessageHandler {
  weak var owner: WebViewController?

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    owner?.handleThemeMessage(message)
  }
}

/// The native window content: a WKWebView below a two-tone titlebar strip,
/// plus a minimal loading overlay. The page inside is the stock dsh web UI —
/// this class never alters it. It samples the page's design tokens to keep
/// the strip an exact continuation of the page's column layout.
final class WebViewController: NSViewController, WKNavigationDelegate, WKUIDelegate {
  let webView: WKWebView

  /// Called when the user clicks the overlay's retry button.
  var onRetry: (() -> Void)?
  /// Called for links that should leave the shell (open in default browser).
  var onOpenExternal: ((URL) -> Void)?

  /// Height of the window's titlebar area, set by the app delegate after the
  /// window is measured; the strip fills this band.
  var titlebarHeight: CGFloat = 28 {
    didSet { view.needsLayout = true }
  }

  private let stripView = TitleStripView()
  private let leftStrip = NSView()
  private let rightStrip = NSView()
  private let stripBorder = NSView()
  private let overlay = NSView()
  private let spinner = NSProgressIndicator()
  private let statusLabel = NSTextField(labelWithString: "")
  private let retryButton = NSButton(title: "重试", target: nil, action: nil)
  private var targetURL: URL?
  private var hasLoadedOnce = false
  private var sidebarWidth: CGFloat = 0
  private var appliedState: (String, String, String, Bool, Double)?
  private let themeProxy: ThemeMessageProxy

  /// Screenshot aids (only active with explicit launch flags): scrub every
  /// text node to placeholder content and/or force the dark page theme.
  var scrubForScreenshot = false
  var shotDark = false

  /// Placeholder copy used by `--shot-scrub`: varied, natural-looking text so
  /// screenshots keep the real layout without carrying any real data.
  private static let screenshotScrubScript = """
  (() => {
    const long = [
      '这是一个用于展示界面外观的示例消息，全部文字均为占位内容。',
      'DeepSeek Harness 是插件化的智能体框架，本截图不包含任何真实数据。',
      '这里原本是一条真实消息；为了截图，它已被替换成这段示例文本。',
      '示例说明：所有会话内容、标题与配置信息都不会出现在截图中。',
    ];
    const mid = ['示例会话标题', '演示项目', '示例消息', '示例说明'];
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    let i = 0;
    for (const n of nodes) {
      const t = (n.nodeValue || '').trim();
      if (!t) continue;
      n.nodeValue = t.length > 30 ? long[i++ % long.length] : (t.length > 6 ? mid[i++ % mid.length] : '示例');
    }
    document.querySelectorAll('input, textarea').forEach((e) => { e.value = ''; });
    document.querySelectorAll('[contenteditable]').forEach((e) => { e.textContent = ''; });
    return nodes.length;
  })()
  """

  private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "[::1]", "harness.internal"]
  private static let themeMessageName = "dshTheme"

  /// Page-side reporter: samples the sidebar/content/border tokens, the dark
  /// theme attribute, and the live sidebar width, and posts them only when
  /// something actually changed (dedupe keeps native traffic at zero during
  /// normal use). The sidebar width is measured by hit-testing the top-left
  /// column and climbing to its outermost sidebar-colored ancestor, which
  /// survives CSS-module class renames across dsh builds. One computed-style
  /// snapshot serves all three token reads.
  private static let themeScript = WKUserScript(
    source: """
    (function () {
      const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dshTheme;
      if (!h) return;
      let lastPayload = '';
      const build = function () {
        const body = document.body;
        if (!body) return null;
        try {
          const style = getComputedStyle(body);
          const sidebar = style.getPropertyValue('--dsw-specific-sidebar-fill').trim();
          const content = style.getPropertyValue('--dsw-alias-bg-base').trim();
          const border = style.getPropertyValue('--dsw-alias-border-l1').trim();
          const dark = body.hasAttribute('data-ds-dark-theme');
          let width = 0;
          if (sidebar) {
            let el = document.elementFromPoint(10, 40);
            let best = null;
            while (el && el !== body) {
              let bg = '';
              try { bg = getComputedStyle(el).backgroundColor; } catch (e) {}
              if (bg === sidebar) best = el;
              el = el.parentElement;
            }
            if (best) width = best.getBoundingClientRect().width;
          }
          return JSON.stringify({ sidebar, content, border, dark, width });
        } catch (e) { return null; }
      };
      const post = function () {
        const p = build();
        if (!p || p === lastPayload) return;
        lastPayload = p;
        try { h.postMessage(p); } catch (e) {}
      };
      window.__dshThemeReport = build;
      let timer = null;
      const schedule = function () {
        if (timer) return;
        timer = setTimeout(function () { timer = null; post(); }, 300);
      };
      const mo = new MutationObserver(schedule);
      const observe = function () {
        if (document.body) mo.observe(document.body, { attributes: true, subtree: true });
      };
      if (document.body) { observe(); post(); }
      else document.addEventListener('DOMContentLoaded', function () { observe(); post(); });
      setTimeout(post, 500);
      setTimeout(post, 1500);
      window.addEventListener('resize', schedule);
      setInterval(post, 3000);
    })();
    """,
    injectionTime: .atDocumentEnd,
    forMainFrameOnly: true)

  init() {
    let proxy = ThemeMessageProxy()
    let configuration = WKWebViewConfiguration()
    // Default store: localStorage/session data persist across launches.
    configuration.websiteDataStore = .default()
    let userContent = WKUserContentController()
    userContent.add(proxy, name: Self.themeMessageName)
    userContent.addUserScript(Self.themeScript)
    configuration.userContentController = userContent
    let webView = WKWebView(frame: .zero, configuration: configuration)
    self.webView = webView
    self.themeProxy = proxy
    super.init(nibName: nil, bundle: nil)
    proxy.owner = self
    webView.navigationDelegate = self
    webView.uiDelegate = self
    if #available(macOS 13.3, *) { webView.isInspectable = true }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func loadView() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
    webView.autoresizingMask = []
    root.addSubview(webView)

    overlay.autoresizingMask = []
    overlay.wantsLayer = true
    overlay.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

    spinner.style = .spinning
    spinner.isIndeterminate = true
    spinner.controlSize = .large
    spinner.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.font = NSFont.systemFont(ofSize: 13)
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.alignment = .center
    retryButton.translatesAutoresizingMaskIntoConstraints = false
    retryButton.target = self
    retryButton.action = #selector(retryPressed)
    retryButton.isHidden = true

    let stack = NSStackView(views: [spinner, statusLabel, retryButton])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    overlay.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
      statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
    ])
    root.addSubview(overlay)

    // The strip sits above the webview in the titlebar band; its subviews
    // are plain colored layers repositioned by viewDidLayout.
    for piece in [leftStrip, rightStrip, stripBorder] {
      piece.wantsLayer = true
      piece.autoresizingMask = []
    }
    stripBorder.isHidden = true
    stripView.addSubview(leftStrip)
    stripView.addSubview(rightStrip)
    stripView.addSubview(stripBorder)
    stripView.wantsLayer = true
    root.addSubview(stripView)
    view = root
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    let bounds = view.bounds
    let stripHeight = min(titlebarHeight, bounds.height)
    stripView.frame = NSRect(x: 0, y: bounds.height - stripHeight, width: bounds.width, height: stripHeight)
    leftStrip.frame = NSRect(x: 0, y: 0, width: max(0, sidebarWidth - 1), height: stripHeight)
    stripBorder.frame = NSRect(x: max(0, sidebarWidth - 1), y: 0, width: 1, height: stripHeight)
    rightStrip.frame = NSRect(x: sidebarWidth, y: 0, width: max(0, bounds.width - sidebarWidth), height: stripHeight)
    webView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - stripHeight)
    overlay.frame = webView.frame
  }

  /// Show the loading overlay with a status line.
  func showStatus(_ text: String) {
    statusLabel.stringValue = text
    retryButton.isHidden = true
    spinner.startAnimation(nil)
    overlay.isHidden = false
  }

  /// Load the ready URL.
  func load(url: URL) {
    targetURL = url
    AppLog.shared.info("webview: loading \(url)")
    webView.load(URLRequest(url: url))
  }

  /// Reload the current page (Cmd+R).
  func reloadPage() {
    if webView.url != nil {
      webView.reload()
    } else if let targetURL {
      webView.load(URLRequest(url: targetURL))
    }
  }

  /// The URL to open in the default browser (Cmd+Shift+O).
  var browserURL: URL? { webView.url ?? targetURL }

  private func hideOverlay() {
    spinner.stopAnimation(nil)
    overlay.isHidden = true
  }

  @objc private func retryPressed() {
    retryButton.isHidden = true
    spinner.startAnimation(nil)
    if let targetURL {
      webView.load(URLRequest(url: targetURL))
    } else {
      onRetry?()
    }
  }

  // MARK: - Titlebar strip theme sync

  /// Entry point for the page-side reporter (called on the main thread).
  func handleThemeMessage(_ message: WKScriptMessage) {
    guard message.name == Self.themeMessageName else { return }
    handleThemePayload(message.body)
  }

  /// Re-sample the page tokens after a finished navigation (belt and
  /// suspenders on top of the injected reporter).
  private func samplePageTheme() {
    webView.evaluateJavaScript("window.__dshThemeReport ? window.__dshThemeReport() : null") { [weak self] result, _ in
      guard let payload = result as? String else { return }
      self?.handleThemePayload(payload)
    }
  }

  private func handleThemePayload(_ body: Any) {
    guard let payload = body as? String,
      let data = payload.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      AppLog.shared.info("webview: unparsable theme payload")
      return
    }
    let sidebar = json["sidebar"] as? String ?? ""
    let content = json["content"] as? String ?? ""
    let border = json["border"] as? String ?? ""
    let dark = json["dark"] as? Bool ?? false
    let width = json["width"] as? Double ?? 0
    applyPageTheme(sidebarColorString: sidebar, contentColorString: content,
      borderColorString: border, sidebarWidth: width, dark: dark)
  }

  /// Paint the strip two-tone: sidebar color over the sidebar width, content
  /// color over the rest, with the page's own 1px column border between them.
  /// The window appearance follows the page theme so the title text and
  /// traffic lights keep contrast in both light and dark pages.
  private func applyPageTheme(sidebarColorString: String, contentColorString: String, borderColorString: String, sidebarWidth: Double, dark: Bool) {
    guard let window = view.window else {
      AppLog.shared.info("webview: theme payload before window attach; skipped")
      return
    }
    guard let sidebarColor = Self.parseRgbColor(sidebarColorString),
      let contentColor = Self.parseRgbColor(contentColorString),
      sidebarWidth > 0 else {
      // Page tokens missing or renamed in this dsh build: fall back to the
      // uniform system window look instead of guessing colors.
      appliedState = nil
      leftStrip.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
      rightStrip.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
      stripBorder.isHidden = true
      self.sidebarWidth = 0
      window.backgroundColor = .windowBackgroundColor
      window.appearance = nil
      AppLog.shared.info("webview: page tokens unavailable; using system window strip")
      view.needsLayout = true
      return
    }
    // Dedupe: the reporter already suppresses unchanged payloads; this guard
    // keeps any residual repeats from re-touching the window.
    let state = (sidebarColorString, contentColorString, borderColorString, dark, sidebarWidth)
    if let appliedState, appliedState == state { return }
    appliedState = state
    let widthChanged = self.sidebarWidth != sidebarWidth
    self.sidebarWidth = sidebarWidth
    leftStrip.layer?.backgroundColor = sidebarColor.cgColor
    rightStrip.layer?.backgroundColor = contentColor.cgColor
    stripBorder.layer?.backgroundColor = (Self.parseRgbColor(borderColorString) ?? NSColor.separatorColor).cgColor
    stripBorder.isHidden = false
    window.backgroundColor = contentColor
    // Screenshot dark mode keeps the window appearance as-is: flipping the
    // appearance (or starting dark) leaves this WKWebView rendering a blank
    // surface, while the page's own attribute-driven dark theme renders fine.
    if !shotDark {
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
    AppLog.shared.info("webview: theme synced (dark=\(dark), sidebar=\(sidebarColorString), content=\(contentColorString), width=\(sidebarWidth))")
    if widthChanged { view.needsLayout = true }
  }

  /// Parse a CSS color string: `rgb(r, g, b)`, `rgb(r g b)`, or `rgba(...)`.
  static func parseRgbColor(_ string: String) -> NSColor? {
    let cleaned = string.trimmingCharacters(in: .whitespaces)
    guard (cleaned.hasPrefix("rgb(") || cleaned.hasPrefix("rgba(")) && cleaned.hasSuffix(")"),
      let open = cleaned.firstIndex(of: "(") else { return nil }
    let inner = cleaned[cleaned.index(after: open)..<cleaned.index(before: cleaned.endIndex)]
    let parts = inner.split { $0 == "," || $0.isWhitespace }.compactMap { Double($0) }
    guard parts.count >= 3, parts[0] <= 255, parts[1] <= 255, parts[2] <= 255 else { return nil }
    let alpha = parts.count >= 4 ? min(max(parts[3], 0), 1) : 1
    return NSColor(calibratedRed: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: alpha)
  }

  // MARK: - WKNavigationDelegate

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    hasLoadedOnce = true
    hideOverlay()
    samplePageTheme()
    guard scrubForScreenshot else { return }
    let scrub: () -> Void = { [weak self] in
      self?.webView.evaluateJavaScript(Self.screenshotScrubScript, completionHandler: nil)
    }
    // Two scrub passes with a pause: late-rendered lists get scrubbed too.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: scrub)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: scrub)
    guard shotDark else { return }
    // Switch the page theme only after the scrubbing settled: the page's
    // dark theme is keyed on this attribute, and the reporter then repaints
    // the strip with the dark tokens (window appearance stays untouched).
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
      self?.webView.evaluateJavaScript(
        "document.body.setAttribute('data-ds-dark-theme', '')", completionHandler: nil)
    }
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    AppLog.shared.error("webview: provisional load failed: \(error.localizedDescription)")
    guard !hasLoadedOnce else { return }
    statusLabel.stringValue = "页面加载失败：\(error.localizedDescription)"
    spinner.stopAnimation(nil)
    retryButton.isHidden = false
    overlay.isHidden = false
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
      decisionHandler(.cancel)
      return
    }
    switch scheme {
    case "http", "https":
      if let host = url.host, Self.loopbackHosts.contains(host) {
        decisionHandler(.allow)
      } else {
        // External links leave the shell instead of replacing the app page.
        onOpenExternal?(url)
        decisionHandler(.cancel)
      }
    case "about", "blob", "data":
      decisionHandler(.allow)
    default:
      onOpenExternal?(url)
      decisionHandler(.cancel)
    }
  }

  // MARK: - WKUIDelegate

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let url = navigationAction.request.url { onOpenExternal?(url) }
    return nil
  }
}

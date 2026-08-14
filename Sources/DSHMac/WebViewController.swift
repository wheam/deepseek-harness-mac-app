import AppKit
import WebKit

/// Weak-indirection script-message handler: `WKUserContentController` retains
/// its handlers, so forwarding through a proxy avoids a retain cycle with the
/// owning view controller.
final class ThemeMessageProxy: NSObject, WKScriptMessageHandler {
  weak var owner: WebViewController?

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    owner?.handleThemeMessage(message)
  }
}

/// The native window content: a WKWebView filling the window, with a minimal
/// native loading overlay. The page inside is the stock dsh web UI — this
/// class never alters it. It does sample the page's design tokens to keep the
/// transparent titlebar strip the same color as the page's sidebar.
final class WebViewController: NSViewController, WKNavigationDelegate, WKUIDelegate {
  let webView: WKWebView

  /// Called when the user clicks the overlay's retry button.
  var onRetry: (() -> Void)?
  /// Called for links that should leave the shell (open in default browser).
  var onOpenExternal: ((URL) -> Void)?

  private let overlay = NSView()
  private let spinner = NSProgressIndicator()
  private let statusLabel = NSTextField(labelWithString: "")
  private let retryButton = NSButton(title: "重试", target: nil, action: nil)
  private var targetURL: URL?
  private var hasLoadedOnce = false
  private let themeProxy: ThemeMessageProxy

  private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "[::1]", "harness.internal"]
  private static let themeMessageName = "dshTheme"

  /// Page-side reporter: samples the sidebar fill token and the dark-theme
  /// attribute, and posts both whenever the body attributes change.
  private static let themeScript = WKUserScript(
    source: """
    (function () {
      const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dshTheme;
      if (!h) return;
      const report = function () {
        const body = document.body;
        if (!body) return;
        let color = '';
        try { color = getComputedStyle(body).getPropertyValue('--dsw-specific-sidebar-fill').trim(); } catch (e) {}
        const dark = body.hasAttribute('data-ds-dark-theme');
        h.postMessage(JSON.stringify({ color: color, dark: dark }));
      };
      const safe = function () { try { report(); } catch (e) {} };
      if (document.body) { safe(); } else { document.addEventListener('DOMContentLoaded', safe); }
      setTimeout(safe, 300);
      setTimeout(safe, 1200);
      const observe = function () {
        if (!document.body) return;
        new MutationObserver(safe).observe(document.body, { attributes: true });
      };
      if (document.body) { observe(); } else { document.addEventListener('DOMContentLoaded', observe); }
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
    webView.frame = root.bounds
    webView.autoresizingMask = [.width, .height]
    root.addSubview(webView)

    overlay.frame = root.bounds
    overlay.autoresizingMask = [.width, .height]
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
    view = root
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

  // MARK: - Titlebar theme sync

  /// Entry point for the page-side reporter (called on the main thread).
  func handleThemeMessage(_ message: WKScriptMessage) {
    guard message.name == Self.themeMessageName else { return }
    handleThemePayload(message.body)
  }

  /// Re-sample the page tokens after a finished navigation (belt and
  /// suspenders on top of the injected reporter).
  private func samplePageTheme() {
    let js = """
    (() => {
      const body = document.body;
      if (!body) return null;
      let color = '';
      try { color = getComputedStyle(body).getPropertyValue('--dsw-specific-sidebar-fill').trim(); } catch (e) {}
      return JSON.stringify({ color: color, dark: body.hasAttribute('data-ds-dark-theme') });
    })()
    """
    webView.evaluateJavaScript(js) { [weak self] result, _ in
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
    let colorString = json["color"] as? String ?? ""
    let dark = json["dark"] as? Bool ?? false
    applyPageTheme(colorString: colorString, dark: dark)
  }

  /// Paint the transparent-titlebar strip with the page's sidebar color and
  /// match the window appearance to the page theme, so the title text and
  /// traffic lights keep contrast in both light and dark pages.
  private func applyPageTheme(colorString: String, dark: Bool) {
    guard let window = view.window else {
      AppLog.shared.info("webview: theme payload before window attach; skipped")
      return
    }
    if let color = Self.parseRgbColor(colorString) {
      window.backgroundColor = color
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      AppLog.shared.info("webview: theme synced (dark=\(dark), color=\(colorString))")
    } else {
      // The sidebar token is missing or renamed in this dsh build: fall back
      // to the system window look instead of guessing a color.
      window.backgroundColor = .windowBackgroundColor
      window.appearance = nil
      AppLog.shared.info("webview: sidebar token unavailable; using system window background")
    }
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

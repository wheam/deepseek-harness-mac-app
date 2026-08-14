import AppKit
import WebKit

/// The native window content: a WKWebView filling the window, with a minimal
/// native loading overlay. The page inside is the stock dsh web UI — this
/// class never alters it.
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

  private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "[::1]", "harness.internal"]

  init() {
    let configuration = WKWebViewConfiguration()
    // Default store: localStorage/session data persist across launches.
    configuration.websiteDataStore = .default()
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init(nibName: nil, bundle: nil)
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

  // MARK: - WKNavigationDelegate

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    hasLoadedOnce = true
    hideOverlay()
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

import AppKit
import WebKit

/// A browser-resolved sRGB color. The page sends byte components instead of
/// CSS text so minifiers and browsers are free to serialize the same color as
/// `#fff`, `rgb(...)`, `color(...)`, etc. without changing the native bridge
/// contract.
struct PageRGBAColor: Equatable {
  let red: Double
  let green: Double
  let blue: Double
  let alpha: Double

  init?(jsonValue: Any?) {
    guard let values = jsonValue as? [Any], values.count == 4 else { return nil }
    let components = values.compactMap { ($0 as? NSNumber)?.doubleValue }
    guard components.count == 4,
      components.allSatisfy({ $0.isFinite && (0 ... 255).contains($0) }) else { return nil }
    red = components[0]
    green = components[1]
    blue = components[2]
    alpha = components[3]
  }

  var nsColor: NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255,
      blue: blue / 255, alpha: alpha / 255)
  }

  /// A partially transparent surface is flattened over white as a defensive
  /// fallback. The page bridge normally sends an already composited opaque
  /// color, but transient black overlays must never be mistaken for a dark
  /// page and then fed back into WKWebView's `prefers-color-scheme`.
  var isVisuallyDark: Bool {
    let opacity = alpha / 255
    let flattenedRed = red * opacity + 255 * (1 - opacity)
    let flattenedGreen = green * opacity + 255 * (1 - opacity)
    let flattenedBlue = blue * opacity + 255 * (1 - opacity)
    let luminance = (
      0.2126 * flattenedRed + 0.7152 * flattenedGreen + 0.0722 * flattenedBlue
    ) / 255
    return luminance < 0.45
  }
}

/// Validated native half of the page-to-titlebar protocol.
struct PageTitlebarTheme: Equatable {
  let sidebar: PageRGBAColor
  let content: PageRGBAColor
  let border: PageRGBAColor?
  let sidebarWidth: Double
  let dark: Bool

  init?(json: [String: Any]) {
    guard json["ok"] as? Bool == true,
      let sidebar = PageRGBAColor(jsonValue: json["sidebarRGBA"]),
      let content = PageRGBAColor(jsonValue: json["contentRGBA"]),
      let width = (json["sidebarWidth"] as? NSNumber)?.doubleValue,
      width.isFinite, width > 0 else { return nil }
    self.sidebar = sidebar
    self.content = content
    border = PageRGBAColor(jsonValue: json["borderRGBA"])
    sidebarWidth = width
    // Derive this at the validated native boundary instead of trusting a page
    // boolean that may have been computed from an uncomposited overlay.
    dark = content.isVisuallyDark
  }
}

/// The page may be explicitly dark while macOS is light (or vice versa). Only
/// the traffic-light controls need page-aware contrast. Changing the entire
/// window appearance would also change WKWebView's `prefers-color-scheme` and
/// create a self-reinforcing theme loop when the page follows the system.
enum TitlebarTrafficLightStyler {
  private static let buttonTypes: [NSWindow.ButtonType] = [
    .closeButton, .miniaturizeButton, .zoomButton,
  ]

  static func apply(dark: Bool, to window: NSWindow) {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    for buttonType in buttonTypes {
      window.standardWindowButton(buttonType)?.appearance = appearance
    }
  }

  static func reset(in window: NSWindow) {
    for buttonType in buttonTypes {
      window.standardWindowButton(buttonType)?.appearance = nil
    }
  }
}

/// Prevents one or two transient samples during page/theme transitions from
/// replacing a good native strip. A third consecutive failure authorizes the
/// controller's system-style fallback.
struct TitlebarThemeSampleGuard {
  private(set) var consecutiveFailures = 0

  mutating func recordSuccess() {
    consecutiveFailures = 0
  }

  mutating func recordFailure() -> Bool {
    consecutiveFailures += 1
    return consecutiveFailures == 3
  }
}

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

final class ContextMenuMessageProxy: NSObject, WKScriptMessageHandler {
  weak var owner: WebViewController?

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    owner?.handleContextMenuMessage(message)
  }
}

final class FindSearchField: NSSearchField {
  var onCancel: (() -> Void)?

  override func cancelOperation(_ sender: Any?) {
    onCancel?()
  }
}

/// The native window content: a WKWebView below a two-tone titlebar strip,
/// plus a minimal loading overlay. The page inside is the stock dsh web UI —
/// this class never alters it. It samples the page's design tokens to keep
/// the strip an exact continuation of the page's column layout.
final class WebViewController: NSViewController, WKNavigationDelegate, WKUIDelegate,
  WKDownloadDelegate, NSSearchFieldDelegate {
  let webView: NativeWebView

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
  private let findBar = NSVisualEffectView()
  private let findField = FindSearchField()
  private let findStatus = NSTextField(labelWithString: "")
  private let findPreviousButton = NSButton(title: "‹", target: nil, action: nil)
  private let findNextButton = NSButton(title: "›", target: nil, action: nil)
  private let findCloseButton = NSButton(title: "×", target: nil, action: nil)
  private var targetURL: URL?
  private var hasLoadedOnce = false
  private var sidebarWidth: CGFloat = 0
  private var appliedState: PageTitlebarTheme?
  private var themeSampleGuard = TitlebarThemeSampleGuard()
  private let themeProxy: ThemeMessageProxy
  private let contextMenuProxy: ContextMenuMessageProxy

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
  private static let contextMenuMessageName = "dshContextMenu"

  /// Converts the existing session/workspace action buttons into a native
  /// contextual menu. Text selection, links, and editable controls stay with
  /// WebKit so macOS keeps its standard Look Up/Translate/Edit menus.
  private static let contextMenuScript = WKUserScript(
    source: """
    (function () {
      const h = window.webkit && window.webkit.messageHandlers
        && window.webkit.messageHandlers.dshContextMenu;
      if (!h) return;
      const actionPattern = /(重命名|分叉|归档|删除|新建会话|rename|fork|archive|delete|new session)/i;
      const destructivePattern = /(归档|删除|archive|delete)/i;
      const editable = function (element) {
        return !!(element && element.closest
          && element.closest('input,textarea,[contenteditable="true"],a[href]'));
      };
      let pointerSelectionTarget = null;
      let pointerHadSelectedText = false;
      document.addEventListener('pointerdown', function (event) {
        if (event.button !== 2 && !(event.button === 0 && event.ctrlKey)) return;
        const target = event.target instanceof Element ? event.target : null;
        const selection = window.getSelection && window.getSelection();
        const range = selection && selection.rangeCount ? selection.getRangeAt(0) : null;
        pointerSelectionTarget = target;
        pointerHadSelectedText = !!(target && selection && !selection.isCollapsed
          && selection.toString().trim() && range && range.intersectsNode
          && range.intersectsNode(target));
      }, true);
      document.addEventListener('contextmenu', function (event) {
        const target = event.target instanceof Element ? event.target : null;
        if (!target || editable(target)) return;
        const samePointerTarget = pointerSelectionTarget
          && (pointerSelectionTarget === target || pointerSelectionTarget.contains(target)
            || target.contains(pointerSelectionTarget));
        const preserveSelectedText = !!(samePointerTarget && pointerHadSelectedText);
        pointerSelectionTarget = null;
        pointerHadSelectedText = false;
        if (preserveSelectedText) return;

        const actionTarget = target.closest(
          'button[aria-label],[role="button"][aria-label]');
        const actionTargetLabel = actionTarget
          ? (actionTarget.getAttribute('aria-label') || '').trim() : '';
        if (actionTarget && (actionTarget.disabled || actionPattern.test(actionTargetLabel))) return;

        let container = target;
        let actionButtons = [];
        for (let depth = 0; container && depth < 7; depth += 1, container = container.parentElement) {
          const candidates = Array.from(container.querySelectorAll(
            'button[aria-label],[role="button"][aria-label]'))
            .filter(function (button) {
              if (button.disabled) return false;
              const label = (button.getAttribute('aria-label') || '').trim();
              return actionPattern.test(label);
            });
          if (candidates.length >= 2 && candidates.length <= 4) {
            actionButtons = candidates;
            break;
          }
        }
        if (!actionButtons.length) return;

        event.preventDefault();
        event.stopPropagation();
        const nonce = ('dshctx_' + Date.now().toString(36) + '_'
          + Math.random().toString(36).slice(2)).replace(/[^A-Za-z0-9_-]/g, '').slice(0, 60);
        const actions = actionButtons.map(function (button, index) {
          const token = nonce + '_' + index;
          button.setAttribute('data-dsh-native-menu-token', token);
          const title = (button.getAttribute('aria-label') || button.textContent || '').trim();
          return { token, title, destructive: destructivePattern.test(title) };
        });
        try { h.postMessage({ x: event.clientX, y: event.clientY, actions }); } catch (e) {}
        setTimeout(function () {
          actionButtons.forEach(function (button) {
            if ((button.getAttribute('data-dsh-native-menu-token') || '').startsWith(nonce)) {
              button.removeAttribute('data-dsh-native-menu-token');
            }
          });
        }, 60000);
      }, true);
    })();
    """,
    injectionTime: .atDocumentEnd,
    forMainFrameOnly: true)

  /// Page-side reporter: samples the actual rendered sidebar/content colors
  /// and live sidebar geometry without depending on CSS-module class names.
  /// CSS tokens remain fallbacks, but WebKit resolves every accepted CSS color
  /// through an sRGB canvas and sends byte components to native code. That
  /// keeps `#fff`, `rgb(...)`, variable indirection, and future serialization
  /// changes out of the bridge contract.
  private static let themeScript = WKUserScript(
    source: """
    (function () {
      const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dshTheme;
      if (!h) return;
      let lastPayload = '';
      let lastInvalidPost = 0;
      let probe = null;
      const canvas = document.createElement('canvas');
      canvas.width = 1;
      canvas.height = 1;
      const context = canvas.getContext('2d', { willReadFrequently: true });

      const ensureProbe = function (body) {
        if (probe && probe.isConnected) return probe;
        probe = document.createElement('span');
        probe.setAttribute('data-dsh-titlebar-probe', '');
        probe.style.cssText = 'position:fixed;left:-10000px;top:-10000px;width:0;height:0;pointer-events:none;opacity:0';
        body.appendChild(probe);
        return probe;
      };

      // Resolve arbitrary CSS color syntax (including var() and wide-gamut
      // color()) in WebKit, then rasterize it to stable sRGB byte components.
      const rgba = function (value, body) {
        if (!value || !context) return null;
        const colorProbe = ensureProbe(body);
        colorProbe.style.color = '';
        colorProbe.style.color = value;
        if (!colorProbe.style.color) return null;
        const resolved = getComputedStyle(colorProbe).color;
        context.clearRect(0, 0, 1, 1);
        context.fillStyle = '#000';
        context.fillStyle = resolved;
        context.fillRect(0, 0, 1, 1);
        return Array.from(context.getImageData(0, 0, 1, 1).data);
      };

      const sameColor = function (a, b) {
        return !!a && !!b && a.length === 4 && b.length === 4
          && a.every(function (part, index) { return part === b[index]; });
      };

      const compositeOver = function (foreground, background) {
        const foregroundAlpha = foreground[3] / 255;
        const backgroundAlpha = background[3] / 255;
        const alpha = foregroundAlpha + backgroundAlpha * (1 - foregroundAlpha);
        if (alpha <= 0) return [0, 0, 0, 0];
        const component = function (index) {
          return Math.round((foreground[index] * foregroundAlpha
            + background[index] * backgroundAlpha * (1 - foregroundAlpha)) / alpha);
        };
        return [component(0), component(1), component(2), Math.round(alpha * 255)];
      };

      // Compose every translucent DOM layer over the page design token. A
      // first-nontransparent lookup can see a temporary black overlay at 24%
      // opacity and falsely classify an otherwise white page as dark.
      const renderedBackground = function (start, body, fallback) {
        const layers = [];
        let el = start;
        while (el) {
          let color = null;
          try { color = rgba(getComputedStyle(el).backgroundColor, body); } catch (e) {}
          if (color && color[3] > 0) layers.push(color);
          if (el === document.documentElement) break;
          el = el.parentElement;
        }
        let result = fallback && fallback[3] > 0 ? fallback : [255, 255, 255, 255];
        for (let index = layers.length - 1; index >= 0; index -= 1) {
          result = compositeOver(layers[index], result);
        }
        return result;
      };

      const build = function () {
        const body = document.body;
        if (!body) return { ok: false, reason: 'body-not-ready' };
        if (document.querySelector('[data-dsh-mac-settings-dialog]')) {
          return { ok: false, reason: 'settings-modal-open' };
        }
        try {
          const style = getComputedStyle(body);
          const tokenSidebar = rgba(style.getPropertyValue('--dsw-specific-sidebar-fill').trim(), body);
          const tokenContent = rgba(style.getPropertyValue('--dsw-alias-bg-base').trim(), body);
          const tokenBorder = rgba(style.getPropertyValue('--dsw-alias-border-l1').trim(), body);
          const pointY = Math.min(Math.max(1, 40), Math.max(1, window.innerHeight - 1));
          const pointX = Math.min(10, Math.max(1, window.innerWidth - 1));
          const hit = document.elementFromPoint(pointX, pointY);
          let el = hit;
          let geometricCandidate = null;
          let colorCandidate = null;
          const minimumHeight = Math.max(40, window.innerHeight * 0.5);
          while (el && el !== body) {
            const rect = el.getBoundingClientRect();
            const plausibleColumn = rect.left <= 1 && rect.right > pointX
              && rect.width >= 24 && rect.width < window.innerWidth - 24
              && rect.top <= pointY && rect.bottom >= pointY
              && rect.height >= minimumHeight;
            if (plausibleColumn) {
              geometricCandidate = el;
              let elementColor = null;
              try { elementColor = rgba(getComputedStyle(el).backgroundColor, body); } catch (e) {}
              if (sameColor(elementColor, tokenSidebar)) colorCandidate = el;
            }
            el = el.parentElement;
          }
          const sidebarElement = colorCandidate || geometricCandidate;
          const sidebarWidth = sidebarElement ? sidebarElement.getBoundingClientRect().width : 0;
          let sidebarRGBA = null;
          let borderRGBA = null;
          if (sidebarElement) {
            const sidebarStyle = getComputedStyle(sidebarElement);
            sidebarRGBA = renderedBackground(sidebarElement, body, tokenSidebar);
            borderRGBA = rgba(sidebarStyle.borderRightColor, body);
          }
          if (!sidebarRGBA || sidebarRGBA[3] === 0) {
            sidebarRGBA = renderedBackground(hit, body, tokenSidebar);
          }
          if (!borderRGBA || borderRGBA[3] === 0) borderRGBA = tokenBorder;

          const contentX = Math.min(Math.max(sidebarWidth + 10, pointX), Math.max(pointX, window.innerWidth - 1));
          const contentHit = document.elementFromPoint(contentX, pointY);
          const contentRGBA = renderedBackground(contentHit, body, tokenContent);
          if (!sidebarRGBA) return { ok: false, reason: 'sidebar-color-unavailable' };
          if (!contentRGBA) return { ok: false, reason: 'content-color-unavailable' };
          if (!(sidebarWidth > 0)) return { ok: false, reason: 'sidebar-geometry-unavailable' };

          // This hint is also recomputed at the validated native boundary.
          const luminance = (0.2126 * contentRGBA[0] + 0.7152 * contentRGBA[1] + 0.0722 * contentRGBA[2]) / 255;
          return { ok: true, sidebarRGBA, contentRGBA, borderRGBA,
            sidebarWidth, dark: luminance < 0.45 };
        } catch (e) {
          return { ok: false, reason: 'sampling-exception' };
        }
      };
      const post = function () {
        const result = build();
        // Keep the last valid titlebar colors while the web modal dims the
        // page. Its mask does not cover the native title strip, so sampling it
        // would produce a mismatched half-dimmed titlebar.
        if (!result.ok && result.reason === 'settings-modal-open') return;
        const p = JSON.stringify(result);
        const now = Date.now();
        if (p === lastPayload && (result.ok || now - lastInvalidPost < 2500)) return;
        lastPayload = p;
        if (!result.ok) lastInvalidPost = now;
        try { h.postMessage(p); } catch (e) {}
      };
      window.__dshThemeReport = function () { return JSON.stringify(build()); };
      let timer = null;
      const schedule = function () {
        if (timer) return;
        timer = setTimeout(function () { timer = null; post(); }, 300);
      };
      const mo = new MutationObserver(function (records) {
        if (records.every(function (record) { return record.target === probe; })) return;
        schedule();
      });
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
    let contextProxy = ContextMenuMessageProxy()
    let configuration = WKWebViewConfiguration()
    // Default store: localStorage/session data persist across launches.
    configuration.websiteDataStore = .default()
    let userContent = WKUserContentController()
    userContent.add(proxy, name: Self.themeMessageName)
    userContent.add(contextProxy, name: Self.contextMenuMessageName)
    userContent.addUserScript(SettingsPresentation.script)
    userContent.addUserScript(Self.themeScript)
    userContent.addUserScript(Self.contextMenuScript)
    configuration.userContentController = userContent
    let webView = NativeWebView(frame: .zero, configuration: configuration)
    self.webView = webView
    self.themeProxy = proxy
    self.contextMenuProxy = contextProxy
    super.init(nibName: nil, bundle: nil)
    proxy.owner = self
    contextProxy.owner = self
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsMagnification = true
    webView.backgroundMenuProvider = { [weak self] in
      self?.makeBackgroundContextMenu() ?? []
    }
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

    findBar.material = .popover
    findBar.blendingMode = .withinWindow
    findBar.state = .active
    findBar.wantsLayer = true
    findBar.layer?.cornerRadius = 9
    findBar.layer?.borderWidth = 1
    findBar.layer?.borderColor = NSColor.separatorColor.cgColor
    findBar.isHidden = true

    findField.placeholderString = "在当前会话中查找"
    findField.delegate = self
    findField.target = self
    findField.action = #selector(findNextPressed)
    findField.sendsSearchStringImmediately = true
    findField.onCancel = { [weak self] in self?.hideFind() }
    findStatus.textColor = .secondaryLabelColor
    findStatus.alignment = .center
    findStatus.font = NSFont.systemFont(ofSize: 11)
    findStatus.setContentHuggingPriority(.required, for: .horizontal)

    for button in [findPreviousButton, findNextButton, findCloseButton] {
      button.bezelStyle = .inline
      button.controlSize = .small
    }
    findPreviousButton.toolTip = "查找上一个"
    findPreviousButton.target = self
    findPreviousButton.action = #selector(findPreviousPressed)
    findNextButton.toolTip = "查找下一个"
    findNextButton.target = self
    findNextButton.action = #selector(findNextPressed)
    findCloseButton.toolTip = "关闭查找"
    findCloseButton.target = self
    findCloseButton.action = #selector(findClosePressed)

    let findStack = NSStackView(views: [
      findField, findStatus, findPreviousButton, findNextButton, findCloseButton,
    ])
    findStack.orientation = .horizontal
    findStack.alignment = .centerY
    findStack.spacing = 4
    findStack.translatesAutoresizingMaskIntoConstraints = false
    findBar.addSubview(findStack)
    NSLayoutConstraint.activate([
      findStack.leadingAnchor.constraint(equalTo: findBar.leadingAnchor, constant: 8),
      findStack.trailingAnchor.constraint(equalTo: findBar.trailingAnchor, constant: -6),
      findStack.topAnchor.constraint(equalTo: findBar.topAnchor, constant: 5),
      findStack.bottomAnchor.constraint(equalTo: findBar.bottomAnchor, constant: -5),
      findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
      findStatus.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
      findPreviousButton.widthAnchor.constraint(equalToConstant: 24),
      findNextButton.widthAnchor.constraint(equalToConstant: 24),
      findCloseButton.widthAnchor.constraint(equalToConstant: 24),
    ])
    root.addSubview(findBar)

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
    let findWidth = min(CGFloat(390), max(CGFloat(280), bounds.width - 24))
    findBar.frame = NSRect(
      x: max(12, bounds.width - findWidth - 12),
      y: max(8, bounds.height - stripHeight - 46),
      width: findWidth,
      height: 36)
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

  var canRunWebCommands: Bool { hasLoadedOnce && webView.url != nil }
  var canFindAgain: Bool { canRunWebCommands && !findField.stringValue.isEmpty }
  var canZoomIn: Bool { canRunWebCommands && webView.pageZoom < 2.0 }
  var canZoomOut: Bool { canRunWebCommands && webView.pageZoom > 0.5 }

  // MARK: - Native menu commands

  func showSettings() {
    runPageCommand("settings", script: """
      (() => {
        const slotButton = document.querySelector(
          '[data-slot="sidebar.settings"] button[aria-haspopup="dialog"]');
        const candidates = Array.from(document.querySelectorAll(
          'button[aria-haspopup="dialog"]'));
        const labelled = candidates.find((button) =>
          /设置|settings/i.test(
            `${button.getAttribute('aria-label') || ''} ${button.textContent || ''}`));
        const button = slotButton || labelled || (candidates.length === 1 ? candidates[0] : null);
        if (!button) return false;
        button.click();
        button.focus();
        return true;
      })()
      """)
  }

  func newSession() {
    runPageCommand("new-session", script: """
      (() => {
        const classButton = document.querySelector('button[class*="_newSession"]');
        const labelled = Array.from(document.querySelectorAll('button[aria-label]'))
          .find((button) => /^(新建会话|new session)$/i.test(
            (button.getAttribute('aria-label') || '').trim()));
        const button = classButton || labelled;
        if (!button) return false;
        button.click();
        button.focus();
        return true;
      })()
      """)
  }

  func toggleSidebar() {
    runPageCommand("toggle-sidebar", script: """
      (() => {
        const button = Array.from(document.querySelectorAll('button[aria-label]'))
          .find((candidate) => /侧边栏|sidebar/i.test(
            candidate.getAttribute('aria-label') || ''));
        if (!button) return false;
        button.click();
        return true;
      })()
      """)
  }

  func focusSessionSearch() {
    runPageCommand("focus-session-search", script: """
      (() => {
        const field = document.querySelector(
          'input[type="search"],input[role="searchbox"],[role="searchbox"]');
        if (!field || typeof field.focus !== 'function') return false;
        field.focus();
        if (typeof field.select === 'function') field.select();
        return true;
      })()
      """)
  }

  func printPage() {
    guard canRunWebCommands else { return }
    webView.printOperation(with: NSPrintInfo.shared).run()
  }

  func showFind() {
    guard canRunWebCommands else { return }
    findBar.isHidden = false
    view.needsLayout = true
    view.window?.makeFirstResponder(findField)
    findField.selectText(nil)
  }

  func findNext() {
    performFind(backwards: false)
  }

  func findPrevious() {
    performFind(backwards: true)
  }

  func hideFind() {
    findBar.isHidden = true
    findStatus.stringValue = ""
    view.window?.makeFirstResponder(webView)
  }

  func zoomIn() {
    setPageZoom(webView.pageZoom + 0.1)
  }

  func zoomOut() {
    setPageZoom(webView.pageZoom - 0.1)
  }

  func actualSize() {
    webView.magnification = 1
    setPageZoom(1)
  }

  func controlTextDidChange(_ obj: Notification) {
    guard obj.object as? NSSearchField === findField else { return }
    performFind(backwards: false)
  }

  private func performFind(backwards: Bool) {
    let query = findField.stringValue
    guard canRunWebCommands, !query.isEmpty else {
      findStatus.stringValue = ""
      return
    }
    let configuration = WKFindConfiguration()
    configuration.backwards = backwards
    configuration.caseSensitive = false
    configuration.wraps = true
    webView.find(query, configuration: configuration) { [weak self] result in
      self?.findStatus.stringValue = result.matchFound ? "" : "未找到"
    }
  }

  private func setPageZoom(_ requested: CGFloat) {
    guard canRunWebCommands else { return }
    let clamped = min(CGFloat(2), max(CGFloat(0.5), requested))
    // Keep stable tenths instead of accumulating floating-point drift.
    webView.magnification = 1
    webView.pageZoom = (clamped * 10).rounded() / 10
    AppLog.shared.info("webview: page zoom \(webView.pageZoom)")
    samplePageTheme()
  }

  private func runPageCommand(_ name: String, script: String) {
    guard canRunWebCommands else {
      AppLog.shared.info("webview: native command \(name) ignored before page readiness")
      return
    }
    webView.evaluateJavaScript(script) { result, error in
      let handled = result as? Bool ?? false
      if let error {
        AppLog.shared.error("webview: native command \(name) failed: \(error.localizedDescription)")
      } else if !handled {
        AppLog.shared.error("webview: native command \(name) unavailable in current page")
      }
    }
  }

  private func makeBackgroundContextMenu() -> [NSMenuItem] {
    let newSession = NSMenuItem(
      title: "新建会话", action: #selector(backgroundNewSession(_:)), keyEquivalent: "")
    newSession.target = self
    let reload = NSMenuItem(
      title: "重新加载", action: #selector(backgroundReload(_:)), keyEquivalent: "")
    reload.target = self
    let browser = NSMenuItem(
      title: "在浏览器中打开", action: #selector(backgroundOpenInBrowser(_:)), keyEquivalent: "")
    browser.target = self
    return [newSession, .separator(), reload, browser]
  }

  @objc private func findNextPressed(_ sender: Any?) { findNext() }
  @objc private func findPreviousPressed(_ sender: Any?) { findPrevious() }
  @objc private func findClosePressed(_ sender: Any?) { hideFind() }
  @objc private func backgroundNewSession(_ sender: Any?) { newSession() }
  @objc private func backgroundReload(_ sender: Any?) { reloadPage() }
  @objc private func backgroundOpenInBrowser(_ sender: Any?) {
    if let browserURL { onOpenExternal?(browserURL) }
  }

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

  // MARK: - Page object contextual menus

  func handleContextMenuMessage(_ message: WKScriptMessage) {
    guard message.name == Self.contextMenuMessageName,
      let request = WebContextMenuRequest(body: message.body) else {
      AppLog.shared.info("webview: rejected malformed context-menu message")
      return
    }
    let menu = NSMenu(title: "")
    var addedNonDestructive = false
    var separatedDestructive = false
    for action in request.actions {
      if action.destructive && addedNonDestructive && !separatedDestructive {
        menu.addItem(.separator())
        separatedDestructive = true
      }
      let item = NSMenuItem(
        title: action.title,
        action: #selector(performWebContextMenuAction(_:)),
        keyEquivalent: "")
      item.target = self
      item.representedObject = action.token
      if action.destructive {
        item.attributedTitle = NSAttributedString(
          string: action.title,
          attributes: [.foregroundColor: NSColor.systemRed])
      } else {
        addedNonDestructive = true
      }
      menu.addItem(item)
    }
    let point = NSPoint(
      x: min(max(CGFloat(request.x), 0), webView.bounds.width),
      y: min(max(webView.bounds.height - CGFloat(request.y), 0), webView.bounds.height))
    menu.popUp(positioning: nil, at: point, in: webView)
  }

  @objc private func performWebContextMenuAction(_ sender: NSMenuItem) {
    guard let token = sender.representedObject as? String,
      token.range(of: #"^[A-Za-z0-9_-]{1,80}$"#, options: .regularExpression) != nil else {
      return
    }
    let script = """
      (() => {
        const button = document.querySelector('[data-dsh-native-menu-token="\(token)"]');
        if (!button) return false;
        button.removeAttribute('data-dsh-native-menu-token');
        button.click();
        return true;
      })()
      """
    runPageCommand("context-menu-action", script: script)
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
    guard let theme = PageTitlebarTheme(json: json) else {
      handleInvalidThemeSample(reason: json["reason"] as? String ?? "invalid-payload")
      return
    }
    themeSampleGuard.recordSuccess()
    applyPageTheme(theme)
  }

  /// Paint the strip two-tone: sidebar color over the sidebar width, content
  /// color over the rest, with the page's own 1px column border between them.
  /// Only the traffic lights follow the page theme. The window itself keeps
  /// the real macOS appearance so WKWebView's system-theme media query cannot
  /// be changed by its own sampled page colors.
  private func applyPageTheme(_ theme: PageTitlebarTheme) {
    guard let window = view.window else {
      AppLog.shared.info("webview: theme payload before window attach; skipped")
      return
    }
    // Dedupe: the reporter already suppresses unchanged payloads; this guard
    // keeps any residual repeats from re-touching the window.
    if appliedState == theme { return }
    appliedState = theme
    let widthChanged = self.sidebarWidth != CGFloat(theme.sidebarWidth)
    self.sidebarWidth = CGFloat(theme.sidebarWidth)
    leftStrip.layer?.backgroundColor = theme.sidebar.nsColor.cgColor
    rightStrip.layer?.backgroundColor = theme.content.nsColor.cgColor
    stripBorder.layer?.backgroundColor = (theme.border?.nsColor ?? NSColor.separatorColor).cgColor
    stripBorder.isHidden = false
    window.backgroundColor = theme.content.nsColor
    TitlebarTrafficLightStyler.apply(dark: theme.dark, to: window)
    AppLog.shared.info("webview: theme synced (dark=\(theme.dark), sidebarRGBA=\(theme.sidebar), contentRGBA=\(theme.content), width=\(theme.sidebarWidth))")
    if widthChanged { view.needsLayout = true }
  }

  /// A transient DOM/CSS gap should not flash a previously good titlebar back
  /// to system white. Repeated failures still fail safe if the page genuinely
  /// changes structure in a future build.
  private func handleInvalidThemeSample(reason: String) {
    let shouldFallBack = themeSampleGuard.recordFailure()
    if themeSampleGuard.consecutiveFailures == 1 {
      AppLog.shared.info("webview: titlebar sample unavailable (\(reason)); retaining last valid strip")
    }
    guard shouldFallBack else { return }
    guard let window = view.window else { return }
    appliedState = nil
    leftStrip.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    rightStrip.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    stripBorder.isHidden = true
    sidebarWidth = 0
    window.backgroundColor = .windowBackgroundColor
    TitlebarTrafficLightStyler.reset(in: window)
    AppLog.shared.info("webview: titlebar sampling failed repeatedly; using system window strip")
    view.needsLayout = true
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
    if navigationAction.shouldPerformDownload {
      decisionHandler(.download)
      return
    }
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

  func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    let disposition = (navigationResponse.response as? HTTPURLResponse)?
      .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
    if disposition.contains("attachment") || !navigationResponse.canShowMIMEType {
      decisionHandler(.download)
    } else {
      decisionHandler(.allow)
    }
  }

  func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
    download.delegate = self
  }

  func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
    download.delegate = self
  }

  // MARK: - WKUIDelegate

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let url = navigationAction.request.url { onOpenExternal?(url) }
    return nil
  }

  func webView(
    _ webView: WKWebView,
    runOpenPanelWith parameters: WKOpenPanelParameters,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping ([URL]?) -> Void
  ) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection
    panel.canChooseDirectories = parameters.allowsDirectories
    panel.canChooseFiles = !parameters.allowsDirectories
    panel.canCreateDirectories = true
    panel.resolvesAliases = true
    let finish: (NSApplication.ModalResponse) -> Void = { response in
      completionHandler(response == .OK ? panel.urls : nil)
    }
    if let window = view.window {
      panel.beginSheetModal(for: window, completionHandler: finish)
    } else {
      panel.begin(completionHandler: finish)
    }
  }

  // MARK: - WKDownloadDelegate

  func download(
    _ download: WKDownload,
    decideDestinationUsing response: URLResponse,
    suggestedFilename: String,
    completionHandler: @escaping (URL?) -> Void
  ) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = Self.safeSuggestedFilename(suggestedFilename)
    panel.canCreateDirectories = true
    let finish: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let url = panel.url else {
        completionHandler(nil)
        return
      }
      // NSSavePanel has already presented the standard replacement warning.
      // WKDownload requires a destination path that does not yet exist.
      if FileManager.default.fileExists(atPath: url.path) {
        do {
          try FileManager.default.removeItem(at: url)
        } catch {
          AppLog.shared.error("download: cannot replace destination: \(error.localizedDescription)")
          completionHandler(nil)
          return
        }
      }
      completionHandler(url)
    }
    if let window = view.window {
      panel.beginSheetModal(for: window, completionHandler: finish)
    } else {
      panel.begin(completionHandler: finish)
    }
  }

  func downloadDidFinish(_ download: WKDownload) {
    AppLog.shared.info("download: finished")
  }

  func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
    AppLog.shared.error("download: failed: \(error.localizedDescription)")
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "下载失败"
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "好")
    if let window = view.window {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }

  static func safeSuggestedFilename(_ value: String) -> String {
    let name = (value as NSString).lastPathComponent
      .replacingOccurrences(of: ":", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty || name == "." || name == ".." ? "DeepSeek-Harness-Download" : name
  }
}

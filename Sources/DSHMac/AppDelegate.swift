import AppKit

/// Application lifecycle: native window + menu bar, single-instance handling,
/// and the bridge to the managed `dsh web` server process.
///
/// macOS conventions: closing the window (Cmd+W) keeps the app and its
/// server alive in the Dock; Cmd+Q quits the app and gracefully stops the
/// server this app spawned (an attached pre-existing server is never touched).
final class AppDelegate: NSObject, NSApplicationDelegate, ServerControllerDelegate {
  private let options: LaunchOptions
  private let logPath: String
  private let server: ServerController
  private var window: NSWindow?
  private var webVC: WebViewController?
  private var distributedObserver: NSObjectProtocol?
  private var terminateHandled = false

  init(options: LaunchOptions) {
    self.options = options
    self.logPath = options.logPath ?? Self.defaultLogPath()
    self.server = ServerController(options: options)
    super.init()
    server.delegate = self
  }

  private static func defaultLogPath() -> String {
    (NSHomeDirectory() as NSString)
      .appendingPathComponent("Library/Logs/DeepSeekHarness/deepseek-harness.log")
  }

  // MARK: - NSApplicationDelegate

  func applicationDidFinishLaunching(_ notification: Notification) {
    AppLog.shared.open(path: logPath)
    AppLog.shared.info("app: launching; pid \(ProcessInfo.processInfo.processIdentifier)")
    AppLog.shared.info("app: \(options.description)")
    if handleSingleInstance() {
      exit(0)
    }
    distributedObserver = DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name("DSHHarnessShowWindow"), object: nil, queue: .main
    ) { [weak self] _ in
      AppLog.shared.info("app: received show-window request from another instance")
      self?.showMainWindow()
    }
    NSApp.setActivationPolicy(.regular)
    buildMenu()
    buildWindow()
    showMainWindow()
    server.start()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showMainWindow()
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Cmd+W keeps the app (and the server) alive in the Dock.
    false
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminateHandled else { return .terminateNow }
    terminateHandled = true
    AppLog.shared.info("app: quitting; stopping managed server")
    server.stop()
    AppLog.shared.info("app: quit complete")
    return .terminateNow
  }

  // MARK: - ServerControllerDelegate

  func serverController(_ controller: ServerController, didUpdateStatus status: String) {
    webVC?.showStatus(status)
  }

  func serverController(_ controller: ServerController, didBecomeReady url: URL) {
    AppLog.shared.info("app: server ready: \(url)")
    // WKWebView must only be touched on the main thread; this is the single
    // funnel for page loads, so hop defensively if a future path strays.
    if Thread.isMainThread {
      webVC?.load(url: url)
    } else {
      DispatchQueue.main.async { [weak self] in self?.webVC?.load(url: url) }
    }
  }

  func serverController(_ controller: ServerController, didFail message: String, canInstallDsh: Bool) {
    presentFailure(message, canInstallDsh: canInstallDsh)
  }

  // MARK: - Window

  private func buildWindow() {
    let controller = WebViewController()
    controller.onRetry = { [weak self] in self?.server.start() }
    controller.onOpenExternal = { url in NSWorkspace.shared.open(url) }
    webVC = controller

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = "DeepSeek Harness"
    // Full-size content view + transparent titlebar: the webview's own
    // two-tone strip paints the titlebar band, so the page's column colors
    // continue to the top edge with no separator line. The titlebar height
    // is measured before the style change, clamped to a sane band, and
    // handed to the strip layout.
    let measuredTitlebarHeight = window.frame.height - window.contentLayoutRect.height
    let titlebarHeight = min(max(measuredTitlebarHeight, 20), 40)
    AppLog.shared.info("app: titlebar height \(measuredTitlebarHeight) -> clamped \(titlebarHeight)")
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.titleVisibility = .visible
    window.contentViewController = controller
    controller.titlebarHeight = titlebarHeight
    window.minSize = NSSize(width: 960, height: 640)
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.setFrameAutosaveName("DSHMainWindow")
    if !window.setFrameUsingName("DSHMainWindow") {
      window.center()
    }
    self.window = window
    controller.showStatus("正在准备 DeepSeek Harness…")
  }

  private func showMainWindow() {
    window?.makeKeyAndOrderFront(nil)
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  // MARK: - Single instance

  /// Post a show-window request to an already-running instance and report
  /// whether this process should exit.
  private func handleSingleInstance() -> Bool {
    // A bare-binary run (no bundle) has no identity to compare; without this
    // guard, `bundleIdentifier == nil` would match every unrelated daemon.
    guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
      return false
    }
    let others = NSWorkspace.shared.runningApplications.filter {
      $0.bundleIdentifier == bundleID
        && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }
    guard !others.isEmpty else { return false }
    AppLog.shared.info("app: another instance is running; asking it to show its window")
    DistributedNotificationCenter.default().postNotificationName(
      NSNotification.Name("DSHHarnessShowWindow"), object: nil, userInfo: nil,
      deliverImmediately: true)
    return true
  }

  // MARK: - Failure and install flows

  private func presentFailure(_ message: String, canInstallDsh: Bool) {
    AppLog.shared.error("app: presenting failure dialog: \(message)")
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "无法启动 DeepSeek Harness"
    alert.informativeText = message
    alert.addButton(withTitle: "重试")
    if canInstallDsh { alert.addButton(withTitle: "安装 dsh") }
    alert.addButton(withTitle: "查看日志")
    alert.addButton(withTitle: "退出")
    let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard let self else { return }
      switch response {
      case .alertFirstButtonReturn:
        self.server.start()
      case .alertSecondButtonReturn:
        if canInstallDsh { self.installDsh() } else { self.openLog() }
      case .alertThirdButtonReturn:
        self.openLog()
      default:
        NSApp.terminate(nil)
      }
    }
    if let parent = window ?? NSApp.keyWindow {
      alert.beginSheetModal(for: parent, completionHandler: completion)
    } else {
      completion(alert.runModal())
    }
  }

  /// Run `npm install -g @deepseek-ai/dsh` behind a cancellable progress sheet.
  private func installDsh() {
    guard let npm = resolveNpm() else {
      presentFailure("未找到 npm 命令。请手动运行：npm i -g @deepseek-ai/dsh", canInstallDsh: false)
      return
    }
    AppLog.shared.info("install: running \(npm) install -g @deepseek-ai/dsh")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: npm)
    process.arguments = ["install", "-g", "@deepseek-ai/dsh"]
    var environment = ProcessInfo.processInfo.environment
    let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + inheritedPath
    process.environment = environment

    let alert = NSAlert()
    alert.messageText = "正在安装 DeepSeek Harness CLI…"
    alert.informativeText = "运行 npm install -g @deepseek-ai/dsh，约需一两分钟。"
    let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    progress.style = .spinning
    progress.isIndeterminate = true
    progress.startAnimation(nil)
    alert.accessoryView = progress
    alert.addButton(withTitle: "取消")

    var output = Data()
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      DispatchQueue.main.async {
        output.append(data)
        let text = String(data: data, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { AppLog.shared.info("npm: \(text)") }
      }
    }
    var finished = false
    process.terminationHandler = { [weak self] done in
      DispatchQueue.main.async {
        guard let self else { return }
        finished = true
        pipe.fileHandleForReading.readabilityHandler = nil
        if let parent = self.window ?? NSApp.keyWindow {
          parent.endSheet(alert.window)
        }
        if done.terminationStatus == 0 {
          AppLog.shared.info("install: npm install succeeded")
          self.server.start()
        } else {
          let tail = String(data: output, encoding: .utf8) ?? ""
          self.presentFailure(
            "安装失败（退出码 \(done.terminationStatus)）。\n\n\(tail.suffix(800))",
            canInstallDsh: false)
        }
      }
    }
    do {
      try process.run()
    } catch {
      presentFailure("无法启动 npm：\(error.localizedDescription)", canInstallDsh: false)
      return
    }
    if let parent = window ?? NSApp.keyWindow {
      alert.beginSheetModal(for: parent) { _ in
        if !finished { process.terminate() } // user cancelled
      }
    } else {
      alert.runModal()
      if !finished { process.terminate() }
    }
  }

  private func resolveNpm() -> String? {
    ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]
      .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
  }

  private func openLog() {
    NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
  }

  // MARK: - Menu bar

  private func buildMenu() {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appItem.submenu = appMenu
    let appName = "DeepSeek Harness"
    appMenu.addItem(withTitle: "关于 \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "隐藏 \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "退出 \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    let editItem = NSMenuItem()
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: "编辑")
    editItem.submenu = editMenu
    editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "剪切", action: Selector(("cut:")), keyEquivalent: "x")
    editMenu.addItem(withTitle: "拷贝", action: Selector(("copy:")), keyEquivalent: "c")
    editMenu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
    editMenu.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")

    let viewItem = NSMenuItem()
    mainMenu.addItem(viewItem)
    let viewMenu = NSMenu(title: "显示")
    viewItem.submenu = viewMenu
    let reloadItem = viewMenu.addItem(withTitle: "重新加载", action: #selector(reloadPageAction(_:)), keyEquivalent: "r")
    reloadItem.target = self
    let openItem = viewMenu.addItem(withTitle: "在浏览器中打开", action: #selector(openInBrowserAction(_:)), keyEquivalent: "O")
    openItem.keyEquivalentModifierMask = [.command, .shift]
    openItem.target = self

    let windowItem = NSMenuItem()
    mainMenu.addItem(windowItem)
    let windowMenu = NSMenu(title: "窗口")
    windowItem.submenu = windowMenu
    windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowMenu.addItem(.separator())
    windowMenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

    NSApp.mainMenu = mainMenu
  }

  @objc private func reloadPageAction(_ sender: Any?) {
    webVC?.reloadPage()
  }

  @objc private func openInBrowserAction(_ sender: Any?) {
    if let url = webVC?.browserURL {
      NSWorkspace.shared.open(url)
    }
  }
}

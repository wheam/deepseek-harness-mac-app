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
  private var updater: AppUpdater?
  private var window: NSWindow?
  private var webVC: WebViewController?
  private var distributedObserver: NSObjectProtocol?
  private var terminateHandled = false
  private var shellUpdateScheduled = false
  private var installerPollGeneration = 0

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
    // Resolve an existing global CLI or install it automatically, then update
    // it when enabled before starting the server. The shell self-update check
    // runs in the background once everything is up.
    let updater = AppUpdater(server: server, noAutoUpdate: options.noAutoUpdate)
    self.updater = updater
    prepareDshAndStartServer()
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
    if canInstallDsh {
      // A CLI that disappeared between preparation and spawn is treated like
      // first launch: repair it automatically instead of asking permission.
      prepareDshAndStartServer()
    } else {
      presentFailure(message, retryPreparesDsh: false, offersFullInstaller: false)
    }
  }

  // MARK: - Window

  private func buildWindow() {
    let controller = WebViewController()
    controller.onRetry = { [weak self] in self?.server.start() }
    controller.onOpenExternal = { url in NSWorkspace.shared.open(url) }
    controller.scrubForScreenshot = options.shotScrub
    controller.shotDark = options.shotDark
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
    // The page already brands itself; hide the titlebar text so it does not
    // duplicate the wordmark (the title still shows in Mission Control and
    // the Dock menu).
    window.titleVisibility = .hidden
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

  // MARK: - CLI preparation and failures

  private func prepareDshAndStartServer() {
    guard let updater else { return }
    updater.prepareDshCli(
      onStatus: { [weak self] status in self?.webVC?.showStatus(status) }
    ) { [weak self] result in
      guard let self else { return }
      switch result {
      case .ready:
        self.server.start()
        self.scheduleShellUpdateOnce()
      case .failed(let message, let offersFullInstaller):
        self.presentFailure(
          message,
          retryPreparesDsh: true,
          offersFullInstaller: offersFullInstaller)
      }
    }
  }

  private func scheduleShellUpdateOnce() {
    guard !shellUpdateScheduled else { return }
    shellUpdateScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
      self?.updater?.checkShellUpdate()
    }
  }

  private func presentFailure(
    _ message: String,
    retryPreparesDsh: Bool,
    offersFullInstaller: Bool
  ) {
    AppLog.shared.error("app: presenting failure dialog: \(message)")
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "无法启动 DeepSeek Harness"
    alert.informativeText = message
    alert.addButton(withTitle: "重试")
    if offersFullInstaller { alert.addButton(withTitle: "运行完整安装程序") }
    alert.addButton(withTitle: "查看日志")
    alert.addButton(withTitle: "退出")
    let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard let self else { return }
      switch response {
      case .alertFirstButtonReturn:
        if retryPreparesDsh {
          self.prepareDshAndStartServer()
        } else {
          self.server.start()
        }
      case .alertSecondButtonReturn:
        if offersFullInstaller {
          self.runFullInstallerInTerminal()
        } else {
          self.openLog()
        }
      case .alertThirdButtonReturn:
        if offersFullInstaller {
          self.openLog()
        } else {
          NSApp.terminate(nil)
        }
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

  /// Open the supported curl bootstrap in Terminal. Node installation may
  /// require an administrator password, which a GUI background process cannot
  /// request silently; Terminal keeps that interaction explicit and visible.
  private func runFullInstallerInTerminal() {
    let command = "/usr/bin/curl -fsSL https://github.com/wheam/deepseek-harness-mac-app/releases/download/latest/install.sh | /bin/sh -s -- --no-open"
    let escaped = command
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let script =
      "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    process.terminationHandler = { [weak self] finished in
      if finished.terminationStatus == 0 {
        AppLog.shared.info("install: opened full installer in Terminal")
        DispatchQueue.main.async { self?.beginWaitingForFullInstaller() }
      } else {
        AppLog.shared.error("install: failed to open full installer in Terminal (code \(finished.terminationStatus))")
      }
    }
    do {
      try process.run()
    } catch {
      AppLog.shared.error("install: cannot launch Terminal installer: \(error.localizedDescription)")
      presentFailure(
        "无法打开终端安装程序：\(error.localizedDescription)",
        retryPreparesDsh: true,
        offersFullInstaller: false)
    }
  }

  private func beginWaitingForFullInstaller() {
    installerPollGeneration += 1
    let generation = installerPollGeneration
    webVC?.showStatus("等待终端完成 Node.js 和 dsh 安装…")
    pollForInstalledDsh(generation: generation, attempt: 0)
  }

  private func pollForInstalledDsh(generation: Int, attempt: Int) {
    guard generation == installerPollGeneration else { return }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
      guard let self else { return }
      let installed = self.server.resolveDshBinary() != nil
      DispatchQueue.main.async {
        guard generation == self.installerPollGeneration else { return }
        if installed {
          AppLog.shared.info("install: full installer completed; dsh is now available")
          self.prepareDshAndStartServer()
        } else if attempt < 119 {
          self.pollForInstalledDsh(generation: generation, attempt: attempt + 1)
        } else {
          self.presentFailure(
            "等待完整安装程序超时。请检查终端中的错误信息后重试。",
            retryPreparesDsh: true,
            offersFullInstaller: true)
        }
      }
    }
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

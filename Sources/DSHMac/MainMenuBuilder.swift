import AppKit

/// Stable tags used by AppDelegate's menu validation and by regression tests.
enum MainMenuCommandTag: Int {
  case settings = 1001
  case newSession
  case openInBrowser
  case printPage
  case find
  case findNext
  case findPrevious
  case focusSessionSearch
  case toggleSidebar
  case reload
  case actualSize
  case zoomIn
  case zoomOut
  case help
}

struct MainMenuSet {
  let main: NSMenu
  let services: NSMenu
  let windows: NSMenu
  let help: NSMenu
}

/// Constructs the standard macOS menu hierarchy in one testable place.
enum MainMenuBuilder {
  static func build(appName: String, target: AppDelegate) -> MainMenuSet {
    let main = NSMenu(title: "Main")

    // Application
    let appMenu = NSMenu(title: appName)
    appMenu.addItem(item(
      "关于 \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
    appMenu.addItem(.separator())
    appMenu.addItem(item(
      "设置…", action: #selector(AppDelegate.showSettingsAction(_:)), key: ",",
      target: target, tag: .settings))
    appMenu.addItem(.separator())
    let services = NSMenu(title: "服务")
    let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
    servicesItem.submenu = services
    appMenu.addItem(servicesItem)
    appMenu.addItem(.separator())
    appMenu.addItem(item(
      "隐藏 \(appName)", action: #selector(NSApplication.hide(_:)), key: "h"))
    appMenu.addItem(item(
      "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h",
      modifiers: [.command, .option]))
    appMenu.addItem(item("全部显示", action: #selector(NSApplication.unhideAllApplications(_:))))
    appMenu.addItem(.separator())
    appMenu.addItem(item(
      "退出 \(appName)", action: #selector(NSApplication.terminate(_:)), key: "q"))
    main.addItem(topLevel(appName, submenu: appMenu))

    // File / session lifecycle
    let fileMenu = NSMenu(title: "文件")
    fileMenu.addItem(item(
      "新建会话", action: #selector(AppDelegate.newSessionAction(_:)), key: "n",
      target: target, tag: .newSession))
    fileMenu.addItem(.separator())
    fileMenu.addItem(item(
      "在浏览器中打开", action: #selector(AppDelegate.openInBrowserAction(_:)), key: "O",
      modifiers: [.command, .shift], target: target, tag: .openInBrowser))
    fileMenu.addItem(item(
      "打印…", action: #selector(AppDelegate.printPageAction(_:)), key: "p",
      target: target, tag: .printPage))
    fileMenu.addItem(.separator())
    fileMenu.addItem(item(
      "关闭窗口", action: #selector(NSWindow.performClose(_:)), key: "w"))
    main.addItem(topLevel("文件", submenu: fileMenu))

    // Edit
    let editMenu = NSMenu(title: "编辑")
    editMenu.addItem(item("撤销", action: NSSelectorFromString("undo:"), key: "z"))
    editMenu.addItem(item(
      "重做", action: NSSelectorFromString("redo:"), key: "Z", modifiers: [.command, .shift]))
    editMenu.addItem(.separator())
    editMenu.addItem(item("剪切", action: NSSelectorFromString("cut:"), key: "x"))
    editMenu.addItem(item("拷贝", action: NSSelectorFromString("copy:"), key: "c"))
    editMenu.addItem(item("粘贴", action: NSSelectorFromString("paste:"), key: "v"))
    editMenu.addItem(item(
      "粘贴并匹配样式", action: NSSelectorFromString("pasteAsPlainText:"), key: "V",
      modifiers: [.command, .option, .shift]))
    editMenu.addItem(item("全选", action: NSSelectorFromString("selectAll:"), key: "a"))
    editMenu.addItem(.separator())

    let findMenu = NSMenu(title: "查找")
    findMenu.addItem(item(
      "查找…", action: #selector(AppDelegate.showFindAction(_:)), key: "f",
      target: target, tag: .find))
    findMenu.addItem(item(
      "查找下一个", action: #selector(AppDelegate.findNextAction(_:)), key: "g",
      target: target, tag: .findNext))
    findMenu.addItem(item(
      "查找上一个", action: #selector(AppDelegate.findPreviousAction(_:)), key: "G",
      modifiers: [.command, .shift], target: target, tag: .findPrevious))
    findMenu.addItem(.separator())
    findMenu.addItem(item(
      "聚焦会话搜索", action: #selector(AppDelegate.focusSessionSearchAction(_:)), key: "f",
      modifiers: [.command, .option], target: target, tag: .focusSessionSearch))
    let findItem = NSMenuItem(title: "查找", action: nil, keyEquivalent: "")
    findItem.submenu = findMenu
    editMenu.addItem(findItem)

    let spellingMenu = NSMenu(title: "拼写与语法")
    spellingMenu.addItem(item(
      "显示拼写与语法", action: NSSelectorFromString("showGuessPanel:"), key: ":",
      modifiers: [.command]))
    spellingMenu.addItem(item(
      "立即检查文稿", action: NSSelectorFromString("checkSpelling:"), key: ";"))
    spellingMenu.addItem(.separator())
    spellingMenu.addItem(item(
      "键入时检查拼写", action: NSSelectorFromString("toggleContinuousSpellChecking:")))
    spellingMenu.addItem(item(
      "检查拼写时检查语法", action: NSSelectorFromString("toggleGrammarChecking:")))
    spellingMenu.addItem(item(
      "自动纠正拼写", action: NSSelectorFromString("toggleAutomaticSpellingCorrection:")))
    let spellingItem = NSMenuItem(title: "拼写与语法", action: nil, keyEquivalent: "")
    spellingItem.submenu = spellingMenu
    editMenu.addItem(spellingItem)

    let substitutionsMenu = NSMenu(title: "替换")
    substitutionsMenu.addItem(item(
      "智能引号", action: NSSelectorFromString("toggleSmartQuotes:")))
    substitutionsMenu.addItem(item(
      "智能破折号", action: NSSelectorFromString("toggleSmartDashes:")))
    substitutionsMenu.addItem(item(
      "文本替换", action: NSSelectorFromString("toggleAutomaticTextReplacement:")))
    let substitutionsItem = NSMenuItem(title: "替换", action: nil, keyEquivalent: "")
    substitutionsItem.submenu = substitutionsMenu
    editMenu.addItem(substitutionsItem)

    let speechMenu = NSMenu(title: "语音")
    speechMenu.addItem(item("开始朗读", action: NSSelectorFromString("startSpeaking:")))
    speechMenu.addItem(item("停止朗读", action: NSSelectorFromString("stopSpeaking:")))
    let speechItem = NSMenuItem(title: "语音", action: nil, keyEquivalent: "")
    speechItem.submenu = speechMenu
    editMenu.addItem(speechItem)
    main.addItem(topLevel("编辑", submenu: editMenu))

    // View
    let viewMenu = NSMenu(title: "显示")
    viewMenu.addItem(item(
      "显示或隐藏侧边栏", action: #selector(AppDelegate.toggleSidebarAction(_:)), key: "s",
      modifiers: [.command, .option], target: target, tag: .toggleSidebar))
    viewMenu.addItem(.separator())
    viewMenu.addItem(item(
      "重新加载", action: #selector(AppDelegate.reloadPageAction(_:)), key: "r",
      target: target, tag: .reload))
    viewMenu.addItem(.separator())
    viewMenu.addItem(item(
      "实际大小", action: #selector(AppDelegate.actualSizeAction(_:)), key: "0",
      target: target, tag: .actualSize))
    viewMenu.addItem(item(
      "放大", action: #selector(AppDelegate.zoomInAction(_:)), key: "+",
      target: target, tag: .zoomIn))
    viewMenu.addItem(item(
      "缩小", action: #selector(AppDelegate.zoomOutAction(_:)), key: "-",
      target: target, tag: .zoomOut))
    viewMenu.addItem(.separator())
    viewMenu.addItem(item(
      "进入全屏幕", action: #selector(NSWindow.toggleFullScreen(_:)), key: "f",
      modifiers: [.command, .control]))
    main.addItem(topLevel("显示", submenu: viewMenu))

    // Window
    let windowMenu = NSMenu(title: "窗口")
    windowMenu.addItem(item(
      "最小化", action: #selector(NSWindow.performMiniaturize(_:)), key: "m"))
    windowMenu.addItem(item("缩放", action: #selector(NSWindow.performZoom(_:))))
    windowMenu.addItem(.separator())
    windowMenu.addItem(item(
      "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:))))
    main.addItem(topLevel("窗口", submenu: windowMenu))

    // Help
    let helpMenu = NSMenu(title: "帮助")
    helpMenu.addItem(item(
      "DeepSeek Harness 帮助", action: #selector(AppDelegate.showHelpAction(_:)), key: "?",
      modifiers: [.command, .shift], target: target, tag: .help))
    main.addItem(topLevel("帮助", submenu: helpMenu))

    return MainMenuSet(main: main, services: services, windows: windowMenu, help: helpMenu)
  }

  private static func topLevel(_ title: String, submenu: NSMenu) -> NSMenuItem {
    let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    menuItem.submenu = submenu
    return menuItem
  }

  private static func item(
    _ title: String,
    action: Selector?,
    key: String = "",
    modifiers: NSEvent.ModifierFlags = [.command],
    target: AnyObject? = nil,
    tag: MainMenuCommandTag? = nil
  ) -> NSMenuItem {
    let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
    if !key.isEmpty { menuItem.keyEquivalentModifierMask = modifiers }
    menuItem.target = target
    if let tag { menuItem.tag = tag.rawValue }
    return menuItem
  }
}

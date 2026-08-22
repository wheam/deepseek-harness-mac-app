import AppKit

enum DshPreparationResult {
  case ready
  case failed(String, offersFullInstaller: Bool)
}

/// Startup auto-updates.
///
/// Two independent update checks, both opt-out via `--no-auto-update`:
/// - dsh CLI: ensure a missing global CLI is installed even when updates are
///   disabled. For global npm installs, compare with the registry and update
///   before the server starts.
/// - the shell itself: compare the GitHub rolling "latest" release's publish
///   time with this build's stamp (or the last applied update) and, when
///   newer, download, unzip, de-quarantine, and swap the bundle in place,
///   then offer a restart.
final class AppUpdater {
  /// GitHub repo the shell releases come from.
  private static let repo = "wheam/deepseek-harness-mac-app"
  /// Info.plist key stamped by build.sh at build time (ISO 8601 UTC).
  private static let buildDateKey = "DSHBuildDate"
  /// UserDefaults key remembering the newest release already applied.
  private static let appliedDateKey = "DSHLastAppliedShellUpdate"
  /// Build one npm global-install command for both first install and updates.
  /// `prefix` pins an update to the existing CLI's global prefix (including
  /// the shared user-global `~/.local` prefix used by install.sh).
  static func globalDshInstallArguments(prefix: String? = nil) -> [String] {
    var arguments = ["install", "-g"]
    if let prefix { arguments += ["--prefix", prefix] }
    arguments += ["@deepseek-ai/dsh@latest", "--no-audit", "--no-fund"]
    return arguments
  }

  private let server: ServerController
  private let enabled: Bool

  init(server: ServerController, noAutoUpdate: Bool) {
    self.server = server
    self.enabled = !noAutoUpdate
  }

  // MARK: - dsh CLI

  /// Ensure dsh exists without asking the user, then optionally update it.
  /// A missing CLI is installed into the resolved npm's global prefix so the
  /// app and the user's terminal share one executable. All npm/network work
  /// stays off the main queue.
  func prepareDshCli(
    onStatus: @escaping (String) -> Void,
    completion: @escaping (DshPreparationResult) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      guard let existingPath = self.server.resolveDshBinary() else {
        AppLog.shared.info("updater: no dsh binary resolved; installing global CLI")
        DispatchQueue.main.async {
          onStatus("首次使用，正在自动安装 DeepSeek Harness CLI…")
        }
        guard let npm = Self.resolveNpm(near: nil) else {
          AppLog.shared.error("updater: cannot auto-install dsh because npm was not found")
          self.finish(.failed(
            "未找到 Node.js/npm。请运行完整安装程序，它会先安装 Node.js，再安装全局 dsh。",
            offersFullInstaller: true), completion)
          return
        }
        let result = Self.runNpmInstall(using: npm, prefix: nil)
        guard result.exit == 0 else {
          let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
          let suffix = detail.isEmpty ? "请确认已安装 Node.js（含 npm）并检查网络连接。" : String(detail.suffix(1000))
          self.finish(.failed(
            "自动安装 dsh 失败（退出码 \(result.exit)）。\n\n\(suffix)",
            offersFullInstaller: true), completion)
          return
        }
        guard let installedPath = self.server.resolveDshBinary() else {
          self.finish(.failed(
            "dsh 安装命令已完成，但 App 未找到安装结果。请查看日志。",
            offersFullInstaller: true), completion)
          return
        }
        AppLog.shared.info("updater: global dsh installed: \(installedPath)")
        self.finish(.ready, completion)
        return
      }

      guard self.enabled else {
        AppLog.shared.info("updater: disabled; skipping CLI update check")
        self.finish(.ready, completion)
        return
      }

      guard let existingPrefix = Self.globalNpmPrefix(forDshPath: existingPath) else {
        AppLog.shared.info("updater: dsh is not a global npm install; skipping CLI update")
        self.finish(.ready, completion)
        return
      }

      guard let npm = Self.resolveNpm(near: existingPath) else {
        AppLog.shared.info("updater: npm not resolved; keeping installed dsh")
        self.finish(.ready, completion)
        return
      }
      let latest = Self.npmLatestVersion(using: npm)
      let installed = Self.installedVersion(forDshPath: existingPath)
      guard let latest, let installed, latest != installed else {
        AppLog.shared.info("updater: dsh CLI \(installed ?? "?") is current (latest \(latest ?? "?"))")
        self.finish(.ready, completion)
        return
      }

      AppLog.shared.info("updater: dsh CLI \(installed) -> \(latest); installing")
      DispatchQueue.main.async {
        onStatus("正在更新 DeepSeek Harness CLI（\(installed) → \(latest)）…")
      }
      let update = Self.runNpmInstall(using: npm, prefix: existingPrefix)
      if update.exit == 0 {
        AppLog.shared.info("updater: dsh CLI updated to \(latest)")
      } else {
        // An update failure must not prevent an already-installed CLI from
        // starting; the complete npm output remains in the app log.
        AppLog.shared.error("updater: dsh CLI update failed; continuing with the installed version")
      }
      self.finish(.ready, completion)
    }
  }

  private func finish(
    _ result: DshPreparationResult,
    _ completion: @escaping (DshPreparationResult) -> Void
  ) {
    DispatchQueue.main.async { completion(result) }
  }

  /// The registry's latest `@deepseek-ai/dsh` version, or nil.
  private static func npmLatestVersion(using npm: String) -> String? {
    let result = runProcess(executable: npm, arguments: ["view", "@deepseek-ai/dsh", "version"],
      timeout: 20, description: "npm view")
    guard result.exit == 0 else { return nil }
    let version = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return version.isEmpty ? nil : version
  }

  /// Read the package manifest by walking up from the resolved dsh symlink.
  /// This works for Homebrew, nvm/fnm/asdf, and custom global prefixes.
  private static func installedVersion(forDshPath path: String) -> String? {
    var directory = ((path as NSString).resolvingSymlinksInPath as NSString)
      .deletingLastPathComponent
    for _ in 0..<6 {
      let manifest = (directory as NSString).appendingPathComponent("package.json")
      if let data = try? Data(contentsOf: URL(fileURLWithPath: manifest)),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        json["name"] as? String == "@deepseek-ai/dsh",
        let version = json["version"] as? String {
        return version
      }
      let parent = (directory as NSString).deletingLastPathComponent
      if parent == directory { break }
      directory = parent
    }
    return nil
  }

  private static func runNpmInstall(
    using npm: String,
    prefix: String?
  ) -> (exit: Int32, output: String) {
    runProcess(
      executable: npm,
      arguments: globalDshInstallArguments(prefix: prefix),
      timeout: 300,
      description: "npm install -g @deepseek-ai/dsh")
  }

  private static func resolveNpm(near dshPath: String?) -> String? {
    let directories = dshPath.map { [($0 as NSString).deletingLastPathComponent] } ?? []
    return ExecutableResolver.resolve("npm", additionalDirectories: directories)
  }

  static func globalNpmPrefix(forDshPath path: String) -> String? {
    let realPath = (path as NSString).resolvingSymlinksInPath
    guard let marker = realPath.range(of: "/lib/node_modules/") else { return nil }
    return String(realPath[..<marker.lowerBound])
  }

  // MARK: - Shell self-update

  /// Check the rolling GitHub release and, when it is newer than this build,
  /// download and apply it, then offer a restart.
  func checkShellUpdate() {
    guard enabled else {
      AppLog.shared.info("updater: disabled; skipping shell update check")
      return
    }
    // Only a real .app bundle can self-replace; a bare-binary run has no
    // bundle path to swap.
    guard Bundle.main.bundlePath.hasSuffix(".app"), Bundle.main.bundleIdentifier != nil else {
      AppLog.shared.info("updater: not running from an app bundle; skipping shell update")
      return
    }
    DispatchQueue.global().async {
      guard let release = Self.fetchLatestRelease() else { return }
      let baseline = max(Self.buildDate() ?? .distantPast, Self.lastAppliedDate())
      guard release.publishedAt > baseline else {
        AppLog.shared.info("updater: shell is current (release \(release.publishedAt))")
        return
      }
      AppLog.shared.info("updater: newer shell build available; downloading \(release.assetURL)")
      self.applyShellUpdate(release)
    }
  }

  private func applyShellUpdate(_ release: ShellRelease) {
    // Unique per-run temp root: a previous failed attempt may have left
    // files behind, and removeItem throws when the path does not exist.
    let tempRoot = NSTemporaryDirectory() + "dsh-shell-update-\(ProcessInfo.processInfo.processIdentifier)"
    let zipPath = tempRoot + "/update.zip"
    let unzipDir = tempRoot + "/app"
    do {
      let fm = FileManager.default
      if fm.fileExists(atPath: tempRoot) {
        try fm.removeItem(atPath: tempRoot)
      }
      try fm.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
      defer { try? fm.removeItem(atPath: tempRoot) }
      guard let data = Self.downloadReleaseAsset(from: release.assetURL) else {
        AppLog.shared.error("updater: shell download failed")
        return
      }
      let actualDigest = ReleaseTrust.sha256Hex(data)
      guard actualDigest == release.assetSHA256 else {
        AppLog.shared.error(
          "updater: shell SHA256 mismatch (expected \(release.assetSHA256), got \(actualDigest))")
        return
      }
      try data.write(to: URL(fileURLWithPath: zipPath))
      let unzip = Process()
      unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
      unzip.arguments = ["-x", "-k", zipPath, unzipDir]
      try unzip.run()
      unzip.waitUntilExit()
      guard unzip.terminationStatus == 0 else {
        AppLog.shared.error("updater: shell unzip failed")
        return
      }
      let newBundle = unzipDir + "/DeepSeek Harness.app"
      do {
        try ReleaseTrust.verifyAppBundle(at: URL(fileURLWithPath: newBundle))
      } catch {
        AppLog.shared.error("updater: rejected shell update: \(error.localizedDescription)")
        return
      }
      // Downloaded bundles carry the quarantine attribute; strip it before
      // swapping, or the next launch would be blocked by Gatekeeper.
      let unquarantine = Process()
      unquarantine.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
      unquarantine.arguments = ["-dr", "com.apple.quarantine", newBundle]
      do {
        try unquarantine.run()
        unquarantine.waitUntilExit()
      } catch {
        AppLog.shared.info("updater: xattr cleanup skipped: \(error.localizedDescription)")
      }
      try swapBundles(newBundle: newBundle)
      UserDefaults.standard.set(release.publishedAt.timeIntervalSince1970, forKey: Self.appliedDateKey)
      AppLog.shared.info("updater: shell updated to build published \(release.publishedAt)")
      DispatchQueue.main.async {
        self.offerRestart()
      }
    } catch {
      AppLog.shared.error("updater: shell update failed: \(error.localizedDescription)")
    }
  }

  /// Replace the running bundle: rename it aside, move the new one in, and
  /// remove the backup. The running process keeps executing from memory.
  private func swapBundles(newBundle: String) throws {
    let bundlePath = Bundle.main.bundlePath
    let parent = (bundlePath as NSString).deletingLastPathComponent
    let backup = parent + "/.DeepSeek Harness.old.app"
    let fm = FileManager.default
    guard fm.isWritableFile(atPath: bundlePath) else {
      throw NSError(domain: "updater", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "bundle is not writable: \(bundlePath)"])
    }
    try? fm.removeItem(atPath: backup)
    try fm.moveItem(atPath: bundlePath, toPath: backup)
    do {
      try fm.moveItem(atPath: newBundle, toPath: bundlePath)
      try? fm.removeItem(atPath: backup)
    } catch {
      // Restore the previous bundle rather than leaving the app missing.
      try? fm.moveItem(atPath: backup, toPath: bundlePath)
      throw error
    }
  }

  private func offerRestart() {
    let alert = NSAlert()
    alert.messageText = "DeepSeek Harness 已更新"
    alert.informativeText = "新版本已就绪，重启后生效。"
    alert.addButton(withTitle: "立即重启")
    alert.addButton(withTitle: "稍后")
    let parent = NSApp.keyWindow
    if let parent {
      alert.beginSheetModal(for: parent) { response in
        if response == .alertFirstButtonReturn {
          Self.relaunch()
        }
      }
    } else if alert.runModal() == .alertFirstButtonReturn {
      Self.relaunch()
    }
  }

  private static func relaunch() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = relaunchHelperArguments(
      currentPID: ProcessInfo.processInfo.processIdentifier,
      bundlePath: Bundle.main.bundlePath)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      NSApp.terminate(nil)
    } catch {
      AppLog.shared.error("updater: failed to launch relaunch helper: \(error.localizedDescription)")
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "无法自动重新启动"
      alert.informativeText = "新版本已经安装，但重新启动助手未能运行。请手动退出并重新打开 DeepSeek Harness。"
      alert.addButton(withTitle: "知道了")
      alert.runModal()
    }
  }

  /// The helper must wait until the old process has completed its delegate
  /// shutdown; launching first would trigger the single-instance guard and
  /// leave no process running after the old copy exits.
  static func relaunchHelperArguments(currentPID: Int32, bundlePath: String) -> [String] {
    [
      "-c",
      "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open -n \"$2\"",
      "dsh-relaunch",
      String(currentPID),
      bundlePath,
    ]
  }

  private static func buildDate() -> Date? {
    guard let value = Bundle.main.object(forInfoDictionaryKey: buildDateKey) as? String else { return nil }
    return Self.parseIso8601(value)
  }

  private static func lastAppliedDate() -> Date {
    Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: appliedDateKey))
  }

  private static func parseIso8601(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: string)
      ?? formatter.date(from: string + "Z") // plain UTC stamps without a zone
  }

  /// The rolling "latest" release: effective asset time, URL, and GitHub's
  /// server-computed SHA256 digest.
  private struct ShellRelease {
    let publishedAt: Date
    let assetURL: URL
    let assetSHA256: String
  }

  private static func fetchLatestRelease() -> ShellRelease? {
    let url = URL(string: "https://api.github.com/repos/\(repo)/releases/tags/latest")!
    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    let semaphore = DispatchSemaphore(value: 0)
    var result: ShellRelease?
    URLSession.shared.dataTask(with: request) { data, response, _ in
      defer { semaphore.signal() }
      guard let http = response as? HTTPURLResponse, http.statusCode == 200,
        let data,
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let published = json["published_at"] as? String,
        let publishedAt = parseIso8601(published),
        let assets = json["assets"] as? [[String: Any]] else { return }
      for asset in assets {
        guard asset["name"] as? String == "DeepSeek-Harness.zip",
          let rawURL = asset["browser_download_url"] as? String,
          let assetURL = URL(string: rawURL),
          assetURL.host == "github.com",
          assetURL.path.hasPrefix("/\(repo)/releases/download/"),
          let digest = ReleaseTrust.normalizedSHA256Digest(asset["digest"] as? String) else {
          continue
        }
        let assetUpdatedAt = (asset["updated_at"] as? String).flatMap(parseIso8601)
          ?? publishedAt
        result = ShellRelease(
          publishedAt: max(publishedAt, assetUpdatedAt),
          assetURL: assetURL,
          assetSHA256: digest)
        break
      }
    }.resume()
    _ = semaphore.wait(timeout: .now() + 25)
    return result
  }

  private static func downloadReleaseAsset(from url: URL) -> Data? {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 120
    let session = URLSession(configuration: configuration)
    let semaphore = DispatchSemaphore(value: 0)
    var result: Data?
    session.dataTask(with: url) { data, response, _ in
      defer { semaphore.signal() }
      guard let http = response as? HTTPURLResponse,
        http.statusCode == 200,
        let data,
        data.count <= 100 * 1024 * 1024 else { return }
      result = data
    }.resume()
    _ = semaphore.wait(timeout: .now() + 125)
    session.invalidateAndCancel()
    return result
  }

  /// Run a process synchronously with a watchdog.
  /// @returns exit status and combined output.
  private static func runProcess(executable: String, arguments: [String], timeout: TimeInterval, description: String) -> (exit: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    // npm is commonly a shim whose shebang needs a sibling `node`. Put both
    // resolved locations ahead of Finder/launchd's minimal PATH.
    let executableDirectory = (executable as NSString).deletingLastPathComponent
    let nodePath = ExecutableResolver.resolve("node", additionalDirectories: [executableDirectory])
    process.environment = ExecutableResolver.processEnvironment(
      executablePaths: [executable, nodePath].compactMap { $0 })
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    var output = Data()
    let outputQueue = DispatchQueue(label: "io.github.wheam.deepseek-harness.npm-output")
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      outputQueue.sync { output.append(data) }
    }
    let watchdog = DispatchWorkItem {
      if process.isRunning {
        AppLog.shared.error("updater: \(description) timed out; killing")
        process.terminate()
      }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    do {
      try process.run()
    } catch {
      AppLog.shared.error("updater: \(description) failed to run: \(error.localizedDescription)")
      watchdog.cancel()
      return (exit: -1, output: "")
    }
    process.waitUntilExit()
    watchdog.cancel()
    pipe.fileHandleForReading.readabilityHandler = nil
    let captured = outputQueue.sync { output }
    let text = String(data: captured, encoding: .utf8) ?? ""
    if !text.isEmpty {
      AppLog.shared.info("updater: \(description): \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))")
    }
    return (exit: process.terminationStatus, output: text)
  }
}

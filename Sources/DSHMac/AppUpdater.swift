import AppKit

/// Startup auto-updates.
///
/// Two independent checks, both opt-out via `--no-auto-update`:
/// - dsh CLI: when the resolved `dsh` is a global npm install, compare it
///   with the registry's latest and run `npm install -g` before the server
///   starts, so the spawned server already runs the new version.
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

  private let server: ServerController
  private let enabled: Bool

  init(server: ServerController, noAutoUpdate: Bool) {
    self.server = server
    self.enabled = !noAutoUpdate
  }

  // MARK: - dsh CLI

  /// Check and install a newer global `dsh` CLI, then continue. Runs the
  /// install on a background queue; `onStatus` reports overlay text.
  /// @param completion - called on the main thread when the check (and any
  /// install) settles; the server may then start.
  func updateDshCliIfNeeded(onStatus: @escaping (String) -> Void, completion: @escaping () -> Void) {
    guard enabled else {
      AppLog.shared.info("updater: disabled; skipping CLI update check")
      completion()
      return
    }
    guard let dshPath = server.resolveDshBinary() else {
      AppLog.shared.info("updater: no dsh binary resolved; skipping CLI update")
      completion()
      return
    }
    // The resolver may return the npm bin symlink; the global-install check
    // keys on the real node_modules path.
    let realPath = (dshPath as NSString).resolvingSymlinksInPath
    guard Self.isGlobalInstall(realPath) else {
      AppLog.shared.info("updater: dsh is not a global npm install; skipping CLI update")
      completion()
      return
    }
    DispatchQueue.global().async {
      let latest = Self.npmLatestVersion()
      let installed = Self.installedGlobalVersion()
      DispatchQueue.main.async {
        guard let latest, let installed, latest != installed else {
          AppLog.shared.info("updater: dsh CLI \(installed ?? "?") is current (latest \(latest ?? "?"))")
          completion()
          return
        }
        AppLog.shared.info("updater: dsh CLI \(installed) -> \(latest); installing")
        onStatus("正在更新 DeepSeek Harness CLI（\(installed) → \(latest)）…")
        Self.runNpmInstall { success in
          if success {
            AppLog.shared.info("updater: dsh CLI updated to \(latest)")
          } else {
            AppLog.shared.error("updater: dsh CLI update failed; continuing with the installed version")
          }
          completion()
        }
      }
    }
  }

  /// The registry's latest `@deepseek-ai/dsh` version, or nil.
  private static func npmLatestVersion() -> String? {
    guard let npm = resolveNpm() else { return nil }
    let result = runProcess(executable: npm, arguments: ["view", "@deepseek-ai/dsh", "version"],
      timeout: 20, description: "npm view")
    guard result.exit == 0 else { return nil }
    let version = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return version.isEmpty ? nil : version
  }

  /// The globally installed version from npm's global prefix, or nil.
  private static func installedGlobalVersion() -> String? {
    for prefix in ["/opt/homebrew/lib/node_modules", "/usr/local/lib/node_modules"] {
      let manifest = prefix + "/@deepseek-ai/dsh/package.json"
      if let data = try? Data(contentsOf: URL(fileURLWithPath: manifest)),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let version = json["version"] as? String {
        return version
      }
    }
    return nil
  }

  private static func runNpmInstall(completion: @escaping (Bool) -> Void) {
    guard let npm = resolveNpm() else {
      completion(false)
      return
    }
    let result = runProcess(executable: npm, arguments: ["install", "-g", "@deepseek-ai/dsh"],
      timeout: 300, description: "npm install -g @deepseek-ai/dsh")
    completion(result.exit == 0)
  }

  private static func resolveNpm() -> String? {
    ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]
      .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
  }

  private static func isGlobalInstall(_ path: String) -> Bool {
    path.contains("/lib/node_modules/")
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
      guard let data = try? Data(contentsOf: release.assetURL) else {
        AppLog.shared.error("updater: shell download failed")
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
      guard FileManager.default.fileExists(atPath: newBundle + "/Contents/MacOS/DeepSeekHarness") else {
        AppLog.shared.error("updater: unzipped bundle is incomplete")
        return
      }
      // Downloaded bundles carry the quarantine attribute; strip it before
      // swapping, or the next launch would be blocked by Gatekeeper.
      let unquarantine = Process()
      unquarantine.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
      unquarantine.arguments = ["-dr", "com.apple.quarantine", newBundle]
      try? unquarantine.run()
      unquarantine.waitUntilExit()
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
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-n", Bundle.main.bundlePath]
    try? process.run()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      NSApp.terminate(nil)
    }
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

  /// The rolling "latest" release: publish time and the zip asset URL.
  private struct ShellRelease {
    let publishedAt: Date
    let assetURL: URL
  }

  private static func fetchLatestRelease() -> ShellRelease? {
    let url = URL(string: "https://api.github.com/repos/\(repo)/releases/tags/latest")!
    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    let semaphore = DispatchSemaphore(value: 0)
    var result: ShellRelease?
    URLSession.shared.dataTask(with: request) { data, _, _ in
      defer { semaphore.signal() }
      guard let data,
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let published = json["published_at"] as? String,
        let publishedAt = parseIso8601(published),
        let assets = json["assets"] as? [[String: Any]] else { return }
      for asset in assets {
        guard asset["name"] as? String == "DeepSeek-Harness.zip",
          let rawURL = asset["browser_download_url"] as? String,
          let assetURL = URL(string: rawURL) else { continue }
        result = ShellRelease(publishedAt: publishedAt, assetURL: assetURL)
        break
      }
    }.resume()
    _ = semaphore.wait(timeout: .now() + 25)
    return result
  }

  /// Run a process synchronously with a watchdog.
  /// @returns exit status and combined output.
  private static func runProcess(executable: String, arguments: [String], timeout: TimeInterval, description: String) -> (exit: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    var output = Data()
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      output.append(data)
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
    let text = String(data: output, encoding: .utf8) ?? ""
    if !text.isEmpty {
      AppLog.shared.info("updater: \(description): \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))")
    }
    return (exit: process.terminationStatus, output: text)
  }
}

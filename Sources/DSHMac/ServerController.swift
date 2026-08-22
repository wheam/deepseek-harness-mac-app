import Darwin
import Foundation

/// What a loopback probe found on the target port.
enum ProbeResult: Equatable {
  /// A live dsh web instance (identified by its served page marker).
  case dshReady(port: Int)
  /// Something else is listening.
  case otherService
  /// Nothing is listening.
  case free
}

/// A pure startup decision keeps port-conflict behavior deterministic and
/// covered by tests instead of burying it in URLSession callbacks.
enum ServerStartupDecision: Equatable {
  case attach(port: Int)
  case spawn(port: Int?)
}

/// Events the server controller reports to the UI layer (main thread).
protocol ServerControllerDelegate: AnyObject {
  /// Status text for the loading overlay.
  func serverController(_ controller: ServerController, didUpdateStatus status: String)
  /// The web server is bound; load this URL.
  func serverController(_ controller: ServerController, didBecomeReady url: URL)
  /// Startup failed or the server kept crashing; `message` is user-facing.
  func serverController(_ controller: ServerController, didFail message: String, canInstallDsh: Bool)
}

/// Owns the `dsh web` child process: binary resolution, attach-or-spawn
/// startup, readiness detection, crash restart, and graceful teardown.
final class ServerController {
  /// Ready line dsh prints after the Loader settles and the server binds:
  /// `dsh web: http://127.0.0.1:<port>`.
  static let readyPattern = try! NSRegularExpression(
    pattern: #"dsh web: http://127\.0\.0\.1:(\d+)"#)

  let options: LaunchOptions
  weak var delegate: ServerControllerDelegate?

  /// The URL of the current web server (spawned or attached), when known.
  private(set) var serverURL: URL?
  /// The child process this app spawned; nil when attached to an existing server.
  private(set) var spawnedProcess: Process?

  private var stopping = false
  private var restartAttempts = 0
  private var restartWindowStart = Date.distantPast
  private var readyTimeoutWork: DispatchWorkItem?
  private var stdoutBuffer = Data()
  private var stderrBuffer = Data()
  private let ioQueue = DispatchQueue(label: "io.github.wheam.deepseek-harness.server-io")
  private var logTail: [String] = []
  private var cachedDshPath: String?
  private var attachmentMonitorGeneration = 0

  /// Arguments used to start the CLI-owned web server. Kept separate so the
  /// no-external-browser contract is covered by a regression test.
  static func webArguments(port requestedPort: Int?) -> [String] {
    var args = ["web", "--no-open"]
    if let requestedPort { args += ["--port", String(requestedPort)] }
    return args
  }

  static func startupDecision(
    for result: ProbeResult,
    targetPort: Int,
    hasExplicitPort: Bool,
    forceSpawn: Bool
  ) -> ServerStartupDecision {
    switch result {
    case .dshReady(let port):
      return forceSpawn ? .spawn(port: 0) : .attach(port: port)
    case .free:
      return .spawn(port: hasExplicitPort ? targetPort : nil)
    case .otherService:
      // Never fail merely because the conventional port belongs to another
      // app. Asking dsh for an OS-assigned port preserves both services.
      return .spawn(port: 0)
    }
  }

  static func replacementPort(afterAttachedProbe result: ProbeResult, attachedPort: Int) -> Int? {
    switch result {
    case .dshReady:
      return nil
    case .free:
      return attachedPort
    case .otherService:
      return 0
    }
  }

  init(options: LaunchOptions) {
    self.options = options
  }

  // MARK: - Startup

  /// Begin the startup sequence: probe the target port, attach to a live dsh
  /// web, or spawn a new one.
  func start() {
    stopping = false
    attachmentMonitorGeneration += 1
    let targetPort = options.port ?? 3080
    let forced = options.port != nil
    AppLog.shared.info("server: start; target port \(targetPort), forceSpawn=\(options.forceSpawn)")
    delegate?.serverController(self, didUpdateStatus: options.forceSpawn
      ? "正在启动本地服务…"
      : "正在检查本地服务…")
    probe(port: targetPort) { [weak self] result in
      guard let self else { return }
      let decision = Self.startupDecision(
        for: result,
        targetPort: targetPort,
        hasExplicitPort: forced,
        forceSpawn: self.options.forceSpawn)
      switch decision {
      case .attach(let port):
        self.attach(port: port)
      case .spawn(let port):
        if result == .otherService || (self.options.forceSpawn && port == 0) {
          AppLog.shared.info(
            "server: port \(targetPort) is already in use; spawning on an OS-assigned port")
        }
        self.spawn(port: port)
      }
    }
  }

  /// Reuse an already-running dsh web instance; the app never terminates a
  /// server it did not spawn.
  private func attach(port: Int) {
    let url = URL(string: "http://127.0.0.1:\(port)/")!
    AppLog.shared.info("server: attaching to existing dsh web at \(url)")
    serverURL = url
    delegate?.serverController(self, didUpdateStatus: "已连接到本地服务…")
    delegate?.serverController(self, didBecomeReady: url)
    let generation = attachmentMonitorGeneration
    scheduleAttachedServerHealthCheck(port: port, generation: generation)
  }

  /// Spawn `dsh web` and wait for its readiness line.
  /// @param port - explicit `--port` value; nil keeps dsh's default (3080),
  /// 0 asks the OS to pick a free port.
  private func spawn(port requestedPort: Int?) {
    attachmentMonitorGeneration += 1
    guard let dshPath = resolveDshBinary() else {
      AppLog.shared.error("server: no dsh binary found")
      delegate?.serverController(self, didFail:
        "未找到 dsh 命令。需要先安装 DeepSeek Harness CLI（npm i -g @deepseek-ai/dsh）。",
        canInstallDsh: true)
      return
    }

    // The native shell owns presentation. Newer dsh releases open the
    // default browser unless explicitly told not to, which would leave the
    // user with both WKWebView and browser windows on every app launch.
    let args = Self.webArguments(port: requestedPort)

    let process = Process()
    if options.direct {
      process.executableURL = URL(fileURLWithPath: dshPath)
      process.arguments = args
    } else {
      // Launch through the login shell so the child inherits the user's
      // shell environment (credentials from ~/.zshrc and friends), matching
      // what `dsh web` sees when started from a terminal.
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      let shellQuote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
      let command = ([dshPath] + args).map(shellQuote).joined(separator: " ")
      process.arguments = ["-lic", "exec \(command)"]
    }
    process.currentDirectoryURL = URL(fileURLWithPath: options.cwd ?? NSHomeDirectory())

    let dshDirectory = (dshPath as NSString).deletingLastPathComponent
    let nodePath = ExecutableResolver.resolve("node", additionalDirectories: [dshDirectory])
    process.environment = ExecutableResolver.processEnvironment(
      executablePaths: [dshPath, nodePath].compactMap { $0 })

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      self?.ioQueue.async { self?.consume(data, errorStream: false) }
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      self?.ioQueue.async { self?.consume(data, errorStream: true) }
    }
    process.terminationHandler = { [weak self] finished in
      DispatchQueue.main.async { self?.handleExit(code: finished.terminationStatus) }
    }

    do {
      try process.run()
    } catch {
      AppLog.shared.error("server: failed to run dsh: \(error.localizedDescription)")
      delegate?.serverController(self, didFail: "无法启动 dsh：\(error.localizedDescription)",
        canInstallDsh: false)
      return
    }
    spawnedProcess = process
    logTail.removeAll()
    AppLog.shared.info("server: spawned dsh web (pid \(process.processIdentifier)) args=\(args) cwd=\(process.currentDirectoryURL?.path ?? "")")
    delegate?.serverController(self, didUpdateStatus: "正在启动 DeepSeek Harness…")
    scheduleReadyTimeout()
  }

  // MARK: - Output parsing

  private func consume(_ chunk: Data, errorStream: Bool) {
    var buffer = errorStream ? stderrBuffer : stdoutBuffer
    buffer.append(chunk)
    while let newline = buffer.firstIndex(of: 0x0A) {
      let lineData = buffer[buffer.startIndex..<newline]
      buffer.removeSubrange(buffer.startIndex...newline)
      processLine(String(data: lineData, encoding: .utf8) ?? "")
    }
    if errorStream { stderrBuffer = buffer } else { stdoutBuffer = buffer }
  }

  private func processLine(_ rawLine: String) {
    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { return }
    AppLog.shared.info("dsh: \(line)")
    logTail.append(line)
    if logTail.count > 200 { logTail.removeFirst(logTail.count - 200) }
    guard serverURL == nil else { return }
    let range = NSRange(line.startIndex..., in: line)
    guard let match = Self.readyPattern.firstMatch(in: line, range: range),
      let portRange = Range(match.range(at: 1), in: line),
      let port = Int(line[portRange]) else { return }
    DispatchQueue.main.async { [weak self] in self?.becomeReady(port: port) }
  }

  private func becomeReady(port: Int) {
    guard serverURL == nil else { return }
    let url = URL(string: "http://127.0.0.1:\(port)/")!
    AppLog.shared.info("server: ready at \(url)")
    serverURL = url
    readyTimeoutWork?.cancel()
    delegate?.serverController(self, didBecomeReady: url)
  }

  private func scheduleReadyTimeout() {
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.serverURL == nil, !self.stopping else { return }
      AppLog.shared.error("server: readiness timeout (60s)")
      self.spawnedProcess?.terminate()
      self.delegate?.serverController(self, didFail:
        "服务启动超时。\n\n最近日志：\n\(self.logTailText())", canInstallDsh: false)
    }
    readyTimeoutWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
  }

  // MARK: - Crash handling

  private func handleExit(code: Int32) {
    readyTimeoutWork?.cancel()
    spawnedProcess = nil
    if stopping {
      AppLog.shared.info("server: dsh web exited (code \(code)) during shutdown")
      return
    }
    AppLog.shared.error("server: dsh web exited unexpectedly (code \(code))")
    if serverURL == nil {
      delegate?.serverController(self, didFail:
        "服务启动失败（退出码 \(code)）。\n\n最近日志：\n\(logTailText())", canInstallDsh: false)
      return
    }
    serverURL = nil
    let now = Date()
    if now.timeIntervalSince(restartWindowStart) > 60 {
      restartWindowStart = now
      restartAttempts = 0
    }
    restartAttempts += 1
    if restartAttempts <= 3 {
      AppLog.shared.info("server: scheduling restart (attempt \(restartAttempts))")
      delegate?.serverController(self, didUpdateStatus: "服务意外退出，正在重启…")
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        guard let self, !self.stopping else { return }
        self.start()
      }
    } else {
      delegate?.serverController(self, didFail:
        "服务反复退出，已停止自动重启。\n\n最近日志：\n\(self.logTailText())", canInstallDsh: false)
    }
  }

  // MARK: - Shutdown

  /// Terminate the spawned server (no-op when attached) and wait for exit.
  /// dsh's graceful shutdown budget is 5s; SIGKILL follows at 7s.
  func stop() {
    stopping = true
    attachmentMonitorGeneration += 1
    readyTimeoutWork?.cancel()
    guard let process = spawnedProcess, process.isRunning else {
      AppLog.shared.info("server: stop; no spawned process to terminate")
      return
    }
    AppLog.shared.info("server: stopping spawned dsh web (pid \(process.processIdentifier))")
    process.terminate()
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      process.waitUntilExit()
      semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + 7) == .timedOut {
      AppLog.shared.error("server: dsh web did not exit within 7s; sending SIGKILL")
      kill(process.processIdentifier, SIGKILL)
    } else {
      AppLog.shared.info("server: dsh web exited cleanly (code \(process.terminationStatus))")
    }
  }

  // MARK: - Helpers

  /// The tail of captured dsh output, for error dialogs.
  func logTailText() -> String {
    logTail.suffix(60).joined(separator: "\n")
  }

  /// Probe the loopback port and classify what answers.
  /// @param port - target port.
  /// @param completion - always called on the main queue: every consumer
  /// path reaches AppKit/WKWebView delegate calls.
  private func probe(
    port: Int,
    logResult: Bool = true,
    completion: @escaping (ProbeResult) -> Void
  ) {
    guard let url = URL(string: "http://127.0.0.1:\(port)/") else {
      completion(.free)
      return
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 2
    let session = URLSession(configuration: .ephemeral)
    session.dataTask(with: request) { data, response, error in
      let result: ProbeResult
      if error != nil {
        if logResult {
          AppLog.shared.info("server: probe \(port): free (\(error?.localizedDescription ?? ""))")
        }
        result = .free
      } else if let http = response as? HTTPURLResponse, let data,
        http.statusCode < 500,
        (String(data: data, encoding: .utf8) ?? "").contains("DeepSeek Harness") {
        if logResult { AppLog.shared.info("server: probe \(port): dsh web present") }
        result = .dshReady(port: port)
      } else {
        if logResult { AppLog.shared.info("server: probe \(port): other service") }
        result = .otherService
      }
      // URLSession completion handlers run on a background queue; delegate
      // calls touch WKWebView/AppKit, which requires the main thread.
      DispatchQueue.main.async { completion(result) }
    }.resume()
  }

  /// An attached process is intentionally not owned or terminated by this app,
  /// but it can still disappear. Recovering keeps the window useful and also
  /// makes the one-time bundle-ID migration from older builds seamless: the
  /// old shell may stop its server just after the replacement opens.
  private func scheduleAttachedServerHealthCheck(port: Int, generation: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
      guard let self,
        !self.stopping,
        generation == self.attachmentMonitorGeneration,
        self.spawnedProcess == nil else { return }
      self.probe(port: port, logResult: false) { [weak self] result in
        guard let self,
          !self.stopping,
          generation == self.attachmentMonitorGeneration,
          self.spawnedProcess == nil else { return }
        guard let replacementPort = Self.replacementPort(
          afterAttachedProbe: result, attachedPort: port) else {
          self.scheduleAttachedServerHealthCheck(port: port, generation: generation)
          return
        }
        AppLog.shared.info(
          "server: attached dsh on port \(port) disappeared; starting a managed replacement")
        self.serverURL = nil
        self.delegate?.serverController(
          self, didUpdateStatus: "已连接的服务已退出，正在启动替代服务…")
        self.spawn(port: replacementPort)
      }
    }
  }

  /// Locate a runnable `dsh` binary: explicit path, GUI/login-shell PATH,
  /// common Node version managers, then npm npx checkouts (newest
  /// @deepseek-ai/dsh first).
  func resolveDshBinary() -> String? {
    let fm = FileManager.default
    if let cachedDshPath, fm.isExecutableFile(atPath: cachedDshPath) { return cachedDshPath }

    if let path = ExecutableResolver.resolve("dsh", explicitPath: options.dshPath) {
      cachedDshPath = path
      AppLog.shared.info("server: dsh binary resolved: \(path)")
      return path
    }

    // npm and dsh are siblings for global installs. This fallback covers a
    // custom npm prefix even if only npm itself was discoverable.
    if let npmPath = ExecutableResolver.resolve("npm") {
      let npmDirectory = (npmPath as NSString).deletingLastPathComponent
      if let path = ExecutableResolver.resolve(
        "dsh", additionalDirectories: [npmDirectory])
      {
        cachedDshPath = path
        AppLog.shared.info("server: dsh binary resolved beside npm: \(path)")
        return path
      }
    }

    var candidates: [(path: String, rank: Int)] = []
    let npxRoot = (NSHomeDirectory() as NSString).appendingPathComponent(".npm/_npx")
    if let checkouts = try? fm.contentsOfDirectory(atPath: npxRoot) {
      for checkout in checkouts {
        let bin = (npxRoot as NSString)
          .appendingPathComponent("\(checkout)/node_modules/.bin/dsh")
        guard fm.isExecutableFile(atPath: bin) else { continue }
        var rank = 10
        let manifestPath = (npxRoot as NSString).appendingPathComponent("\(checkout)/package.json")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
          let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let dependencies = manifest["dependencies"] as? [String: String],
          let version = dependencies["@deepseek-ai/dsh"] {
          rank = version.split(separator: ".").enumerated().reduce(0) { acc, pair in
            acc * 1000 + (Int(pair.element.prefix(while: \.isNumber)) ?? 0)
          }
        }
        candidates.append((bin, rank))
      }
    }
    guard let best = candidates.max(by: { $0.rank < $1.rank }) else { return nil }
    cachedDshPath = best.path
    AppLog.shared.info("server: dsh binary resolved: \(best.path)")
    return best.path
  }
}

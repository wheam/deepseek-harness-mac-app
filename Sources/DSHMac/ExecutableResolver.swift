import Darwin
import Foundation

/// Finds command-line tools from a GUI app, whose launchd-provided `PATH`
/// normally omits version managers and user npm prefixes.
enum ExecutableResolver {
  static func resolve(
    _ name: String,
    explicitPath: String? = nil,
    additionalDirectories: [String] = []
  ) -> String? {
    resolve(
      name,
      explicitPath: explicitPath,
      additionalDirectories: additionalDirectories,
      homeDirectory: NSHomeDirectory(),
      environment: ProcessInfo.processInfo.environment,
      allowShellLookup: true)
  }

  /// Build an environment in which a resolved npm/dsh/node shim can find its
  /// sibling executables. This is essential for `#!/usr/bin/env node` shims.
  static func processEnvironment(executablePaths: [String] = []) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let executableDirectories = executablePaths.map {
      ($0 as NSString).deletingLastPathComponent
    }
    let pathDirectories = unique(
      executableDirectories
        + standardDirectories(homeDirectory: NSHomeDirectory())
        + splitPath(environment["PATH"]))
    environment["PATH"] = pathDirectories.joined(separator: ":")
    return environment
  }

  // Internal parameters keep filesystem-only resolution deterministic in
  // tests; production callers use the overload above.
  static func resolve(
    _ name: String,
    explicitPath: String?,
    additionalDirectories: [String],
    homeDirectory: String,
    environment: [String: String],
    allowShellLookup: Bool
  ) -> String? {
    let fm = FileManager.default
    if let explicitPath, fm.isExecutableFile(atPath: explicitPath) {
      return explicitPath
    }

    let directDirectories = unique(
      additionalDirectories
        + splitPath(environment["PATH"])
        + standardDirectories(homeDirectory: homeDirectory))
    if let path = firstExecutable(named: name, in: directDirectories, fileManager: fm) {
      return path
    }

    // An interactive login shell sees nvm/fnm setup commonly kept in
    // ~/.zshrc. It also covers arbitrary npm prefixes we cannot predict.
    if allowShellLookup, let path = resolveFromLoginShell(name, environment: environment) {
      return path
    }

    // Finder launches can have no useful SHELL/PATH at all. Scan the common
    // version-manager layouts as a deterministic fallback.
    let versionManagerDirectories = discoverVersionManagerDirectories(
      homeDirectory: homeDirectory, fileManager: fm)
    return firstExecutable(named: name, in: versionManagerDirectories, fileManager: fm)
  }

  private static func standardDirectories(homeDirectory: String) -> [String] {
    [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/usr/bin",
      "/bin",
      (homeDirectory as NSString).appendingPathComponent(".local/bin"),
      (homeDirectory as NSString).appendingPathComponent(".npm-global/bin"),
      (homeDirectory as NSString).appendingPathComponent(".npm/bin"),
      (homeDirectory as NSString).appendingPathComponent(".volta/bin"),
      (homeDirectory as NSString).appendingPathComponent(".asdf/shims"),
      (homeDirectory as NSString).appendingPathComponent(".fnm/current/bin"),
      (homeDirectory as NSString).appendingPathComponent(".local/share/mise/shims"),
      (homeDirectory as NSString).appendingPathComponent(".mise/shims"),
      (homeDirectory as NSString).appendingPathComponent("Library/pnpm"),
    ]
  }

  private static func discoverVersionManagerDirectories(
    homeDirectory: String,
    fileManager: FileManager
  ) -> [String] {
    let rootsAndSuffixes: [(String, String)] = [
      (".nvm/versions/node", "bin"),
      (".fnm/node-versions", "installation/bin"),
      (".local/share/fnm/node-versions", "installation/bin"),
      (".asdf/installs/nodejs", "bin"),
      (".local/share/mise/installs/node", "bin"),
      (".local/share/mise/installs/nodejs", "bin"),
    ]
    var directories: [String] = []
    for (relativeRoot, suffix) in rootsAndSuffixes {
      let root = (homeDirectory as NSString).appendingPathComponent(relativeRoot)
      guard let versions = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
      // Prefer newer-looking versions while remaining deterministic.
      for version in versions.sorted(by: >) {
        directories.append(
          (root as NSString).appendingPathComponent("\(version)/\(suffix)"))
      }
    }
    return directories
  }

  private static func resolveFromLoginShell(
    _ name: String,
    environment: [String: String]
  ) -> String? {
    // Only fixed executable names reach this helper, but keep the shell
    // command constrained in case a future caller passes user input.
    guard name.range(of: #"^[A-Za-z0-9._+-]+$"#, options: .regularExpression) != nil else {
      return nil
    }
    var shells: [String] = []
    if let configured = environment["SHELL"], !configured.isEmpty {
      shells.append(configured)
    }
    if let account = getpwuid(getuid()), let rawShell = account.pointee.pw_shell {
      let accountShell = String(cString: rawShell)
      if !accountShell.isEmpty { shells.append(accountShell) }
    }
    shells.append("/bin/zsh")

    for shell in unique(shells) where FileManager.default.isExecutableFile(atPath: shell) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: shell)
      if (shell as NSString).lastPathComponent == "fish" {
        process.arguments = ["-l", "-i", "-c", "type -p \(name)"]
      } else {
        process.arguments = ["-lic", "command -v -- \(name)"]
      }
      process.environment = environment
      process.standardInput = FileHandle.nullDevice
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      let outputQueue = DispatchQueue(label: "com.deepseek-ai.harness.shell-lookup-output")
      var outputData = Data()
      pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        outputQueue.sync { outputData.append(data) }
      }

      let exited = DispatchSemaphore(value: 0)
      process.terminationHandler = { _ in exited.signal() }
      do {
        try process.run()
      } catch {
        continue
      }
      if exited.wait(timeout: .now() + 4) == .timedOut {
        process.terminate()
        if exited.wait(timeout: .now() + 1) == .timedOut {
          pipe.fileHandleForReading.readabilityHandler = nil
          continue
        }
      }
      pipe.fileHandleForReading.readabilityHandler = nil
      let captured = outputQueue.sync { outputData }
      let output = String(data: captured, encoding: .utf8) ?? ""
      let candidates = output
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .reversed()
      if let path = candidates.first(where: {
        $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0)
      }) {
        return path
      }
    }
    return nil
  }

  private static func firstExecutable(
    named name: String,
    in directories: [String],
    fileManager: FileManager
  ) -> String? {
    for directory in directories where !directory.isEmpty {
      let path = (directory as NSString).appendingPathComponent(name)
      if fileManager.isExecutableFile(atPath: path) { return path }
    }
    return nil
  }

  private static func splitPath(_ path: String?) -> [String] {
    (path ?? "").split(separator: ":").map(String.init)
  }

  private static func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { !$0.isEmpty && seen.insert($0).inserted }
  }
}

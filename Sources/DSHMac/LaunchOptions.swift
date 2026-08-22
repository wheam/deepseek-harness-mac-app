import Foundation

/// Command-line options for the macOS shell.
///
/// These are passed via `open -a "DeepSeek Harness" --args ...` and exist for
/// configuration and testing; normal double-click launches use the defaults.
struct LaunchOptions: CustomStringConvertible {
  /// Force the web server port (default: probe 3080).
  var port: Int?
  /// Always spawn a fresh `dsh web` instead of attaching to a running one.
  var forceSpawn = false
  /// Working directory for the spawned `dsh web` (default: the user's home).
  var cwd: String?
  /// Explicit `dsh` binary path, bypassing auto-resolution.
  var dshPath: String?
  /// Spawn the dsh binary directly instead of through the login shell.
  var direct = false
  /// Log file path (default: ~/Library/Logs/DeepSeekHarness/deepseek-harness.log).
  var logPath: String?
  /// Screenshot aid: replace every page text node with placeholder content.
  var shotScrub = false
  /// Screenshot aid: force the page (and the shell) into the dark theme.
  var shotDark = false
  /// Disable the startup auto-update checks (dsh CLI and the shell itself).
  var noAutoUpdate = false

  var description: String {
    "LaunchOptions(port: \(port.map(String.init) ?? "nil"), forceSpawn: \(forceSpawn),"
      + " cwd: \(cwd ?? "nil"), dshPath: \(dshPath ?? "nil"), direct: \(direct),"
      + " logPath: \(logPath ?? "nil"), shotScrub: \(shotScrub), shotDark: \(shotDark),"
      + " noAutoUpdate: \(noAutoUpdate))"
  }

  /// Parse the process arguments, skipping the executable path at index 0.
  /// @param args - `CommandLine.arguments`.
  /// @returns the parsed options; unknown flags are ignored.
  static func parse(_ args: [String]) -> LaunchOptions {
    var options = LaunchOptions()
    var index = 1
    while index < args.count {
      let flag = args[index]
      let takeValue: () -> String? = {
        index += 1
        return index < args.count ? args[index] : nil
      }
      switch flag {
      case "--port":
        if let value = takeValue(), let port = Int(value) { options.port = port }
      case "--spawn":
        options.forceSpawn = true
      case "--cwd":
        options.cwd = takeValue()
      case "--dsh":
        options.dshPath = takeValue()
      case "--direct":
        options.direct = true
      case "--log":
        options.logPath = takeValue()
      case "--shot-scrub":
        options.shotScrub = true
      case "--shot-dark":
        options.shotDark = true
      case "--no-auto-update":
        options.noAutoUpdate = true
      case "--help":
        print(Self.helpText)
        exit(0)
      default:
        break
      }
      index += 1
    }
    return options
  }

  private static let helpText: String =
    """
    DeepSeek Harness (macOS shell)

    Options:
      --port <n>     force the dsh web port (default: probe 3080)
      --spawn        always start a fresh dsh web, never attach
      --cwd <dir>    working directory for the spawned dsh web
      --dsh <path>   explicit dsh binary path
      --direct       run dsh directly instead of via the login shell
      --log <path>   log file path
      --shot-scrub   replace page text with screenshot placeholders
      --shot-dark    force the screenshot page theme to dark
      --no-auto-update
                     disable CLI and app-shell update checks
      --help         this help
    """
}

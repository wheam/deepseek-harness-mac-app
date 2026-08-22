import Foundation

/// Append-only file logger for the shell app.
///
/// The log lives at `~/Library/Logs/DeepSeekHarness/deepseek-harness.log`
/// (or the `--log` path) and is truncated on each launch. All writes are
/// serialized on a private queue, so any thread may log.
final class AppLog {
  /// Process-wide singleton.
  static let shared = AppLog()

  private var handle: FileHandle?
  private let queue = DispatchQueue(label: "io.github.wheam.deepseek-harness.log")
  private let formatter = DateFormatter()

  private init() {
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
  }

  /// Open (or truncate and reopen) the log file.
  /// @param path - absolute log file path.
  func open(path: String) {
    queue.sync {
      let fm = FileManager.default
      let dir = (path as NSString).deletingLastPathComponent
      try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
      fm.createFile(atPath: path, contents: nil)
      handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
      do {
        try handle?.seekToEnd()
      } catch {
        handle?.seekToEndOfFile()
      }
    }
  }

  /// Write an informational line.
  func info(_ message: String) { write(level: "INFO", message) }

  /// Write an error line.
  func error(_ message: String) { write(level: "ERROR", message) }

  private func write(level: String, _ message: String) {
    queue.async { [weak self] in
      guard let self, let handle = self.handle else { return }
      let line = "\(self.formatter.string(from: Date())) [\(level)] \(message)\n"
      handle.write(line.data(using: .utf8) ?? Data())
    }
  }
}

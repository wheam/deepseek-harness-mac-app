import CryptoKit
import Foundation

enum ReleaseTrustError: LocalizedError {
  case missingExecutable
  case invalidBundleIdentifier
  case invalidCodeSignature(String)
  case missingSigningCertificate
  case untrustedSigningCertificate(String)

  var errorDescription: String? {
    switch self {
    case .missingExecutable:
      return "更新包缺少 DeepSeekHarness 主程序"
    case .invalidBundleIdentifier:
      return "更新包的 Bundle ID 不正确"
    case .invalidCodeSignature(let detail):
      return "更新包代码签名无效：\(detail)"
    case .missingSigningCertificate:
      return "更新包没有可验证的签名证书"
    case .untrustedSigningCertificate(let fingerprint):
      return "更新包签名证书不受信任（SHA256 \(fingerprint)）"
    }
  }
}

/// Trust policy shared by the built-in updater. The public installer carries
/// the same certificate pin. New certificates must be added here before the
/// signing key is rotated so existing clients can migrate safely.
enum ReleaseTrust {
  static let expectedBundleIdentifier = "io.github.wheam.deepseek-harness"
  static let trustedLeafCertificateSHA256: Set<String> = [
    "b27ec2f2110df554e415d0142ea13ab504f359db1698398b61ef702a4f6f481b",
  ]

  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func normalizedSHA256Digest(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.lowercased().hasPrefix("sha256:")
      ? String(value.dropFirst("sha256:".count)).lowercased()
      : value.lowercased()
    guard normalized.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
      return nil
    }
    return normalized
  }

  static func verifyAppBundle(at bundleURL: URL) throws {
    let fm = FileManager.default
    let executable = bundleURL
      .appendingPathComponent("Contents/MacOS/DeepSeekHarness", isDirectory: false)
    guard fm.isExecutableFile(atPath: executable.path) else {
      throw ReleaseTrustError.missingExecutable
    }

    let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
    let infoData = try Data(contentsOf: infoURL)
    let rawInfo = try PropertyListSerialization.propertyList(from: infoData, format: nil)
    guard let info = rawInfo as? [String: Any],
      info["CFBundleIdentifier"] as? String == expectedBundleIdentifier else {
      throw ReleaseTrustError.invalidBundleIdentifier
    }

    let verification = try run(
      executable: "/usr/bin/codesign",
      arguments: ["--verify", "--deep", "--strict", bundleURL.path])
    guard verification.status == 0 else {
      throw ReleaseTrustError.invalidCodeSignature(
        verification.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    let certificateDirectory = fm.temporaryDirectory
      .appendingPathComponent("dsh-signature-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: certificateDirectory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: certificateDirectory) }
    let extraction = try run(
      executable: "/usr/bin/codesign",
      arguments: ["-d", "--extract-certificates", bundleURL.path],
      currentDirectory: certificateDirectory)
    let leafCertificate = certificateDirectory.appendingPathComponent("codesign0")
    guard extraction.status == 0,
      let certificateData = try? Data(contentsOf: leafCertificate) else {
      throw ReleaseTrustError.missingSigningCertificate
    }
    let fingerprint = sha256Hex(certificateData)
    guard trustedLeafCertificateSHA256.contains(fingerprint) else {
      throw ReleaseTrustError.untrustedSigningCertificate(fingerprint)
    }
  }

  private static func run(
    executable: String,
    arguments: [String],
    currentDirectory: URL? = nil
  ) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
  }
}

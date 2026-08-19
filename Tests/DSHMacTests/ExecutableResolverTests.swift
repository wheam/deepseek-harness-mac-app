import Foundation
import XCTest
@testable import DSHMac

final class ExecutableResolverTests: XCTestCase {
  private var temporaryHome = ""

  override func setUpWithError() throws {
    temporaryHome = (NSTemporaryDirectory() as NSString)
      .appendingPathComponent("dsh-resolver-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      atPath: temporaryHome, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if !temporaryHome.isEmpty {
      try? FileManager.default.removeItem(atPath: temporaryHome)
    }
  }

  func testFindsExecutableFromCustomPath() throws {
    let bin = (temporaryHome as NSString).appendingPathComponent("custom-prefix/bin")
    let executable = try makeExecutable(in: bin, named: "resolver-path-fixture")

    let resolved = ExecutableResolver.resolve(
      "resolver-path-fixture",
      explicitPath: nil,
      additionalDirectories: [],
      homeDirectory: temporaryHome,
      environment: ["PATH": bin],
      allowShellLookup: false)

    XCTAssertEqual(resolved, executable)
  }

  func testFindsNvmInstallWhenGuiPathIsEmpty() throws {
    let bin = (temporaryHome as NSString)
      .appendingPathComponent(".nvm/versions/node/v22.10.0/bin")
    let executable = try makeExecutable(in: bin, named: "resolver-nvm-fixture")

    let resolved = ExecutableResolver.resolve(
      "resolver-nvm-fixture",
      explicitPath: nil,
      additionalDirectories: [],
      homeDirectory: temporaryHome,
      environment: ["PATH": "/usr/bin:/bin"],
      allowShellLookup: false)

    XCTAssertEqual(resolved, executable)
  }

  func testAdditionalNpmDirectoryCanRevealSiblingDsh() throws {
    let bin = (temporaryHome as NSString).appendingPathComponent("unknown-node-prefix/bin")
    let executable = try makeExecutable(in: bin, named: "resolver-sibling-fixture")

    let resolved = ExecutableResolver.resolve(
      "resolver-sibling-fixture",
      explicitPath: nil,
      additionalDirectories: [bin],
      homeDirectory: temporaryHome,
      environment: ["PATH": "/usr/bin:/bin"],
      allowShellLookup: false)

    XCTAssertEqual(resolved, executable)
  }

  func testFindsExecutableConfiguredOnlyByInteractiveShell() throws {
    let bin = (temporaryHome as NSString).appendingPathComponent("shell-only/bin")
    let executable = try makeExecutable(in: bin, named: "resolver-shell-fixture")
    let zshrc = (temporaryHome as NSString).appendingPathComponent(".zshrc")
    try Data("export PATH='\(bin):$PATH'\n".utf8)
      .write(to: URL(fileURLWithPath: zshrc))

    let resolved = ExecutableResolver.resolve(
      "resolver-shell-fixture",
      explicitPath: nil,
      additionalDirectories: [],
      homeDirectory: temporaryHome,
      environment: [
        "HOME": temporaryHome,
        "ZDOTDIR": temporaryHome,
        "SHELL": "/bin/zsh",
        "PATH": "/usr/bin:/bin",
      ],
      allowShellLookup: true)

    XCTAssertEqual(resolved, executable)
  }

  private func makeExecutable(in directory: String, named name: String) throws -> String {
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true)
    let path = (directory as NSString).appendingPathComponent(name)
    FileManager.default.createFile(
      atPath: path, contents: Data("#!/bin/sh\n".utf8))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: path)
    return path
  }
}

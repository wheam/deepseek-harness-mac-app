// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "DSHMac",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "DeepSeekHarness", targets: ["DSHMac"]),
  ],
  targets: [
    .executableTarget(
      name: "DSHMac",
      path: "Sources/DSHMac"
    ),
  ]
)

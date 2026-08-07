// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "codex-swift",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "CodexTUI", targets: ["CodexTUI"]),
    .executable(name: "codex-swift", targets: ["codex-swift"]),
    .executable(name: "codex-benchmark", targets: ["CodexBenchmark"]),
  ],
  dependencies: [
    .package(path: "../ratetui-swift"),
    .package(url: "https://github.com/EYHN/kwwk.git", exact: "0.1.36"),
  ],
  targets: [
    .target(
      name: "CodexTUI",
      dependencies: [
        .product(name: "Ratatui", package: "ratetui-swift"),
        .product(name: "RatatuiSyntaxHighlighting", package: "ratetui-swift"),
        .product(name: "KWWKAI", package: "kwwk"),
        .product(name: "KWWKAgent", package: "kwwk"),
      ]
    ),
    .executableTarget(
      name: "codex-swift",
      dependencies: [
        "CodexTUI",
        .product(name: "Ratatui", package: "ratetui-swift"),
      ]
    ),
    .executableTarget(
      name: "CodexBenchmark",
      dependencies: [
        "CodexTUI",
        .product(name: "Ratatui", package: "ratetui-swift"),
      ]
    ),
    .testTarget(
      name: "CodexTUITests",
      dependencies: [
        "CodexTUI",
        .product(name: "Ratatui", package: "ratetui-swift"),
        .product(name: "RatatuiTestSupport", package: "ratetui-swift"),
        .product(name: "KWWKAI", package: "kwwk"),
        .product(name: "KWWKAgent", package: "kwwk"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)

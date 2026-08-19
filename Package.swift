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
    .package(url: "https://github.com/Frank-III/termloom.git", branch: "main"),
    .package(url: "https://github.com/EYHN/kwwk.git", exact: "0.1.45"),
  ],
  targets: [
    .target(
      name: "CodexTUI",
      dependencies: [
        .product(name: "TermLoom", package: "termloom"),
        .product(name: "TermLoomSyntaxHighlighting", package: "termloom"),
        .product(name: "KWWKAI", package: "kwwk"),
        .product(name: "KWWKAgent", package: "kwwk"),
      ]
    ),
    .executableTarget(
      name: "codex-swift",
      dependencies: [
        "CodexTUI",
        .product(name: "TermLoom", package: "termloom"),
      ]
    ),
    .executableTarget(
      name: "CodexBenchmark",
      dependencies: [
        "CodexTUI",
        .product(name: "TermLoom", package: "termloom"),
      ]
    ),
    .testTarget(
      name: "CodexTUITests",
      dependencies: [
        "CodexTUI",
        .product(name: "TermLoom", package: "termloom"),
        .product(name: "TermLoomTestSupport", package: "termloom"),
        .product(name: "KWWKAI", package: "kwwk"),
        .product(name: "KWWKAgent", package: "kwwk"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)

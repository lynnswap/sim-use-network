// swift-tools-version: 6.3
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
  name: "sim-use-network",
  platforms: [
    .macOS("15.4")
  ],
  products: [
    .executable(name: "sim-use-network", targets: ["SimUseNetworkCLI"]),
    .executable(name: "sim-use-network-install", targets: ["SimUseNetworkInstallCLI"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/apple/swift-argument-parser",
      exact: "1.8.2"
    )
  ],
  targets: [
    .target(
      name: "SimUseNetworkCore",
      resources: [
        .copy("Resources/RuntimeArtifacts")
      ]
    ),
    .executableTarget(
      name: "SimUseNetworkCLI",
      dependencies: [
        "SimUseNetworkCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      resources: [
        .copy("Resources/skills")
      ],
      plugins: [
        .plugin(name: "SimUseNetworkBuildInfoPlugin")
      ]
    ),
    .executableTarget(
      name: "SimUseNetworkInstallCLI",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ],
      plugins: [
        .plugin(name: "SimUseNetworkBuildInfoPlugin")
      ]
    ),
    .executableTarget(
      name: "SimUseNetworkBuildInfoTool"
    ),
    .plugin(
      name: "SimUseNetworkBuildInfoPlugin",
      capability: .buildTool(),
      dependencies: ["SimUseNetworkBuildInfoTool"]
    ),
    .testTarget(
      name: "SimUseNetworkCoreTests",
      dependencies: ["SimUseNetworkCore"]
    ),
    .testTarget(
      name: "SimUseNetworkCLITests",
      dependencies: ["SimUseNetworkCLI"]
    ),
    .testTarget(
      name: "SimUseNetworkInstallCLITests",
      dependencies: ["SimUseNetworkInstallCLI"]
    ),
    .testTarget(
      name: "SimUseNetworkBuildInfoToolTests",
      dependencies: ["SimUseNetworkBuildInfoTool"]
    ),
  ]
)

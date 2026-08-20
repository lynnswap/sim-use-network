// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import SimUseNetworkCore

@Test
func runtimeArtifactCompilerBuildsEverySimulatorPlatform() throws {
  let compiler = try RuntimeArtifactCompiler()
  #if arch(arm64)
    let hostArchitecture = "arm64"
  #elseif arch(x86_64)
    let hostArchitecture = "x86_64"
  #else
    Issue.record("Unsupported test host architecture")
    return
  #endif

  for platform in SimulatorPlatform.allCases {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "sim-use-network-artifact-test-\(platform.rawValue)-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = SimulatorRuntime(
      identifier: "test.\(platform.rawValue)",
      platform: platform,
      version: "26.0",
      buildVersion: "test",
      supportedArchitectures: [hostArchitecture],
      name: "\(platform.displayName) test runtime"
    )

    let artifact = try compiler.compile(for: runtime, in: directory)

    #expect(FileManager.default.fileExists(atPath: artifact.libraryURL.path))
    #expect(artifact.architecture == hostArchitecture)
    #expect(artifact.targetTriple == "\(hostArchitecture)-apple-\(platform.targetOS)26.0-simulator")
  }
}

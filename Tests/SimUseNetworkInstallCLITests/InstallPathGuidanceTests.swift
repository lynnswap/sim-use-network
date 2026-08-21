// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import SimUseNetworkInstallCLI

@Suite
struct InstallPathGuidanceTests {
  @Test
  func pathEntrySuppressesGuidance() throws {
    let temporaryDirectory = try TestTemporaryDirectory(prefix: "sim-use-network-path-tests")
    defer { withExtendedLifetime(temporaryDirectory) {} }
    let root = temporaryDirectory.url
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

    let messages = InstallPathGuidance(
      commandDirectory: bin,
      environment: ["PATH": "/usr/bin:\(bin.path):/bin"]
    ).messages()

    #expect(messages.isEmpty)
  }

  @Test
  func zshGuidancePrintsCommandsWithoutEditingTheProfile() throws {
    let temporaryDirectory = try TestTemporaryDirectory(prefix: "sim-use-network-path-tests")
    defer { withExtendedLifetime(temporaryDirectory) {} }
    let root = temporaryDirectory.url
    let bin = root.appendingPathComponent("prefix with space/bin", isDirectory: true)
    let profile = root.appendingPathComponent(".zprofile")

    let messages = InstallPathGuidance(
      commandDirectory: bin,
      environment: [
        "HOME": root.path,
        "PATH": "/usr/bin:/bin",
        "SHELL": "/bin/zsh",
      ]
    ).messages()

    #expect(!FileManager.default.fileExists(atPath: profile.path))
    #expect(messages.contains(where: { $0.contains("printf '") && $0.contains(".zprofile") }))
    #expect(messages.contains("    export PATH='\(bin.path)':\"$PATH\""))
  }

  @Test
  func defaultLocalBinGuidanceUsesThePortableHomeExpression() throws {
    let temporaryDirectory = try TestTemporaryDirectory(prefix: "sim-use-network-path-tests")
    defer { withExtendedLifetime(temporaryDirectory) {} }
    let root = temporaryDirectory.url
    let bin = root.appendingPathComponent(".local/bin", isDirectory: true)

    let messages = InstallPathGuidance(
      commandDirectory: bin,
      environment: [
        "HOME": root.path,
        "PATH": "/usr/bin:/bin",
        "SHELL": "/bin/zsh",
      ]
    ).messages()

    #expect(messages.contains(#"    export PATH="$HOME/.local/bin:$PATH""#))
  }

  @Test
  func existingProfileEntryIsNotSuggestedAgain() throws {
    let temporaryDirectory = try TestTemporaryDirectory(prefix: "sim-use-network-path-tests")
    defer { withExtendedLifetime(temporaryDirectory) {} }
    let root = temporaryDirectory.url
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    let profile = root.appendingPathComponent(".zprofile")
    let exportLine = "export PATH='\(bin.path)':\"$PATH\""
    try Data("\(exportLine)\n".utf8).write(to: profile)

    let messages = InstallPathGuidance(
      commandDirectory: bin,
      environment: [
        "HOME": root.path,
        "PATH": "/usr/bin:/bin",
        "SHELL": "/bin/zsh",
      ]
    ).messages()

    #expect(messages.contains(where: { $0.contains("already contains the PATH entry") }))
    #expect(!messages.contains(where: { $0.contains("printf '") }))
    #expect(messages.contains("    \(exportLine)"))
  }

  @Test
  func unknownShellUsesManualGuidance() throws {
    let temporaryDirectory = try TestTemporaryDirectory(prefix: "sim-use-network-path-tests")
    defer { withExtendedLifetime(temporaryDirectory) {} }
    let root = temporaryDirectory.url
    let bin = root.appendingPathComponent("bin", isDirectory: true)

    let messages = InstallPathGuidance(
      commandDirectory: bin,
      environment: [
        "HOME": root.path,
        "PATH": "/usr/bin:/bin",
        "SHELL": "/opt/homebrew/bin/fish",
      ]
    ).messages()

    #expect(messages.contains("  Add this directory to PATH using the syntax for your shell:"))
    #expect(!messages.contains(where: { $0.contains(".zprofile") }))
    #expect(!messages.contains(where: { $0.contains("printf '") }))
    #expect(!messages.contains(where: { $0.contains("export PATH=") }))
  }

  @Test
  func unsafePathDoesNotProduceAShellCommand() throws {
    let temporaryDirectory = try TestTemporaryDirectory(prefix: "sim-use-network-path-tests")
    defer { withExtendedLifetime(temporaryDirectory) {} }
    let root = temporaryDirectory.url
    let bin = root.appendingPathComponent("colon:bin", isDirectory: true)

    let messages = InstallPathGuidance(
      commandDirectory: bin,
      environment: [
        "HOME": root.path,
        "PATH": "/usr/bin:/bin",
        "SHELL": "/bin/zsh",
      ]
    ).messages()

    #expect(messages.contains(where: { $0.contains("cannot be represented safely") }))
    #expect(!messages.contains(where: { $0.contains("export PATH=") }))
    #expect(!messages.contains(where: { $0.contains("printf '") }))
  }

  @Test
  func earlierExecutableIsReportedAsShadowingTheInstall() throws {
    let temporaryDirectory = try TestTemporaryDirectory(prefix: "sim-use-network-path-tests")
    defer { withExtendedLifetime(temporaryDirectory) {} }
    let root = temporaryDirectory.url
    let shadowDirectory = root.appendingPathComponent("shadow", isDirectory: true)
    let bin = root.appendingPathComponent("prefix/bin", isDirectory: true)
    try FileManager.default.createDirectory(
      at: shadowDirectory,
      withIntermediateDirectories: true
    )
    let shadow = shadowDirectory.appendingPathComponent("sim-use-network")
    try Data("#!/bin/sh\n".utf8).write(to: shadow)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: shadow.path
    )

    let messages = InstallPathGuidance(
      commandDirectory: bin,
      environment: [
        "HOME": root.path,
        "PATH": "\(shadowDirectory.path):\(bin.path)",
        "SHELL": "/bin/zsh",
      ]
    ).messages()

    #expect(messages.contains(where: { $0.contains("appears first on PATH") }))
    #expect(messages.contains("    export PATH='\(bin.path)':\"$PATH\""))
  }

}

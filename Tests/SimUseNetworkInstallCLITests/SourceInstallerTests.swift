// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import SimUseNetworkInstallCLI

@Suite
struct SourceInstallerTests {
  @Test
  func layoutUsesLocalPrefixByDefault() throws {
    let temporaryDirectory = try TestTemporaryDirectory(prefix: "sim-use-network-installer-tests")
    defer { withExtendedLifetime(temporaryDirectory) {} }
    let root = temporaryDirectory.url
    let layout = try SourceInstaller.layout(
      prefix: nil,
      environment: ["HOME": root.path],
      currentDirectory: root
    )

    #expect(layout.prefix == root.appendingPathComponent(".local", isDirectory: true))
    #expect(layout.command.path.hasSuffix("/.local/bin/sim-use-network"))
    #expect(layout.payloadsDirectory.path.hasSuffix("/libexec/sim-use-network/payloads"))
  }

  @Test
  func installPublishesCompletePayloadAndWrapper() throws {
    let fixture = try makeCheckoutFixture()
    defer { withExtendedLifetime(fixture) {} }
    let prefix = fixture.root.appendingPathComponent("install", isDirectory: true)
    let installer = SourceInstaller(
      process: InstallProcess { _, _, _, _ in 0 },
      makeIdentifier: { "first" }
    )

    let lines = try installer.install(
      installerExecutableURL: fixture.installer,
      prefix: prefix.path,
      environment: [
        "HOME": fixture.root.path,
        "PATH": "/usr/bin:/bin",
        "SHELL": "/bin/zsh",
      ]
    )

    let layout = try SourceInstaller.layout(
      prefix: prefix.path,
      environment: [:],
      currentDirectory: fixture.root
    )
    let payload = layout.payloadsDirectory.appendingPathComponent("first", isDirectory: true)
    #expect(FileManager.default.isExecutableFile(atPath: layout.command.path))
    let wrapper = try String(contentsOf: layout.command, encoding: .utf8)
    #expect(wrapper.contains("#!/bin/sh"))
    #expect(wrapper.contains(payload.appendingPathComponent("sim-use-network").path))
    for artifact in SourceInstaller.artifacts {
      #expect(
        FileManager.default.fileExists(
          atPath: payload.appendingPathComponent(artifact.name).path))
    }
    #expect(lines.contains(where: { $0.contains("Installed sim-use-network") }))
    #expect(lines.contains(where: { $0.contains("not on PATH") }))
  }

  @Test
  func failedPrepublicationSmokeTestLeavesThePreviousInstallUntouched() throws {
    let fixture = try makeCheckoutFixture()
    defer { withExtendedLifetime(fixture) {} }
    let prefix = fixture.root.appendingPathComponent("install", isDirectory: true)
    let successfulProcess = InstallProcess { _, _, _, _ in 0 }
    _ = try SourceInstaller(
      process: successfulProcess,
      makeIdentifier: { "first" }
    ).install(
      installerExecutableURL: fixture.installer,
      prefix: prefix.path,
      environment: ["HOME": fixture.root.path, "PATH": "/usr/bin:/bin"]
    )

    let layout = try SourceInstaller.layout(
      prefix: prefix.path,
      environment: [:],
      currentDirectory: fixture.root
    )
    let originalWrapper = try Data(contentsOf: layout.command)
    let failingProcess = InstallProcess { executable, arguments, _, _ in
      if executable.lastPathComponent.hasPrefix(".sim-use-network-"),
        arguments == ["init", "--print"]
      {
        return 9
      }
      return 0
    }

    do {
      _ = try SourceInstaller(
        process: failingProcess,
        makeIdentifier: { "second" }
      ).install(
        installerExecutableURL: fixture.installer,
        prefix: prefix.path,
        environment: ["HOME": fixture.root.path, "PATH": "/usr/bin:/bin"]
      )
      Issue.record("expected installation to fail")
    } catch {
      #expect(error.localizedDescription.contains("Command failed"))
    }

    #expect(try Data(contentsOf: layout.command) == originalWrapper)
    #expect(
      FileManager.default.fileExists(
        atPath: layout.payloadsDirectory.appendingPathComponent("first").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: layout.payloadsDirectory.appendingPathComponent("second").path))
  }

  @Test
  func successfulUpdateRetainsTheImmutablePreviousPayload() throws {
    let fixture = try makeCheckoutFixture()
    defer { withExtendedLifetime(fixture) {} }
    let prefix = fixture.root.appendingPathComponent("updates", isDirectory: true)
    let process = InstallProcess { _, _, _, _ in 0 }
    _ = try SourceInstaller(
      process: process,
      makeIdentifier: { "first" }
    ).install(
      installerExecutableURL: fixture.installer,
      prefix: prefix.path,
      environment: ["HOME": fixture.root.path, "PATH": "/usr/bin:/bin"]
    )
    _ = try SourceInstaller(
      process: process,
      makeIdentifier: { "second" }
    ).install(
      installerExecutableURL: fixture.installer,
      prefix: prefix.path,
      environment: ["HOME": fixture.root.path, "PATH": "/usr/bin:/bin"]
    )

    let layout = try SourceInstaller.layout(
      prefix: prefix.path,
      environment: [:],
      currentDirectory: fixture.root
    )
    #expect(
      FileManager.default.fileExists(
        atPath: layout.payloadsDirectory.appendingPathComponent("first").path))
    #expect(
      FileManager.default.fileExists(
        atPath: layout.payloadsDirectory.appendingPathComponent("second").path))
    let wrapper = try String(contentsOf: layout.command, encoding: .utf8)
    #expect(wrapper.contains("/payloads/second/sim-use-network"))
    #expect(!wrapper.contains("/payloads/first/sim-use-network"))
  }

  @Test
  func prefixSymlinkAliasResolvesToTheExistingManagedInstall() throws {
    let fixture = try makeCheckoutFixture()
    defer { withExtendedLifetime(fixture) {} }
    let realPrefix = fixture.root.appendingPathComponent("real-prefix", isDirectory: true)
    let aliasPrefix = fixture.root.appendingPathComponent("alias-prefix", isDirectory: true)
    try FileManager.default.createDirectory(at: realPrefix, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: aliasPrefix,
      withDestinationURL: realPrefix
    )
    let process = InstallProcess { _, _, _, _ in 0 }
    _ = try SourceInstaller(
      process: process,
      makeIdentifier: { "real" }
    ).install(
      installerExecutableURL: fixture.installer,
      prefix: realPrefix.path,
      environment: ["HOME": fixture.root.path, "PATH": "/usr/bin:/bin"]
    )
    _ = try SourceInstaller(
      process: process,
      makeIdentifier: { "alias" }
    ).install(
      installerExecutableURL: fixture.installer,
      prefix: aliasPrefix.path,
      environment: ["HOME": fixture.root.path, "PATH": "/usr/bin:/bin"]
    )

    let command = realPrefix.appendingPathComponent("bin/sim-use-network")
    #expect(
      try String(contentsOf: command, encoding: .utf8).contains(
        "/payloads/alias/sim-use-network"))
  }

  @Test
  func repositoryRootRequiresTheSwiftPMBuildDirectory() throws {
    let temporaryDirectory = try TestTemporaryDirectory(prefix: "sim-use-network-installer-tests")
    defer { withExtendedLifetime(temporaryDirectory) {} }
    let root = temporaryDirectory.url
    let executable = root.appendingPathComponent("sim-use-network-install")
    FileManager.default.createFile(atPath: executable.path, contents: Data())

    #expect(throws: (any Error).self) {
      _ = try SourceInstaller.repositoryRoot(
        from: executable,
        fileManager: .default
      )
    }
  }

  @Test
  func buildFailureDoesNotCreateTheInstallPrefix() throws {
    let fixture = try makeCheckoutFixture()
    defer { withExtendedLifetime(fixture) {} }
    let prefix = fixture.root.appendingPathComponent("build-failed", isDirectory: true)

    #expect(throws: (any Error).self) {
      _ = try SourceInstaller(
        process: InstallProcess { executable, _, _, _ in
          executable.path == "/usr/bin/env" ? 1 : 0
        },
        makeIdentifier: { "unused" }
      ).install(
        installerExecutableURL: fixture.installer,
        prefix: prefix.path,
        environment: ["HOME": fixture.root.path, "PATH": "/usr/bin:/bin"]
      )
    }

    #expect(!FileManager.default.fileExists(atPath: prefix.path))
  }

  @Test
  func swiftBuildContentsResourcesLayoutIsAccepted() throws {
    let fixture = try makeCheckoutFixture(swiftBuildLayout: true)
    defer { withExtendedLifetime(fixture) {} }
    let prefix = fixture.root.appendingPathComponent("swiftbuild", isDirectory: true)

    _ = try SourceInstaller(
      process: InstallProcess { _, _, _, _ in 0 },
      makeIdentifier: { "swiftbuild" }
    ).install(
      installerExecutableURL: fixture.installer,
      prefix: prefix.path,
      environment: ["HOME": fixture.root.path, "PATH": "/usr/bin:/bin"]
    )

    #expect(
      FileManager.default.fileExists(
        atPath: prefix.appendingPathComponent(
          "libexec/sim-use-network/payloads/swiftbuild/"
            + "sim-use-network_SimUseNetworkCore.bundle/Contents/Resources/"
            + "RuntimeArtifacts/NetworkUnavailableShim.c"
        ).path))
  }

  @Test
  func unmarkedDirectLayoutIsNotMigrated() throws {
    let fixture = try makeCheckoutFixture()
    defer { withExtendedLifetime(fixture) {} }
    let prefix = fixture.root.appendingPathComponent("occupied", isDirectory: true)
    let bin = prefix.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let build = fixture.installer.deletingLastPathComponent()
    for artifact in SourceInstaller.artifacts {
      try FileManager.default.copyItem(
        at: build.appendingPathComponent(artifact.name),
        to: bin.appendingPathComponent(artifact.name)
      )
    }
    let command = bin.appendingPathComponent("sim-use-network")
    let original = try Data(contentsOf: command)

    #expect(throws: (any Error).self) {
      _ = try SourceInstaller(
        process: InstallProcess { _, _, _, _ in 0 },
        makeIdentifier: { "blocked" }
      ).install(
        installerExecutableURL: fixture.installer,
        prefix: prefix.path,
        environment: ["HOME": fixture.root.path, "PATH": "/usr/bin:/bin"]
      )
    }
    #expect(try Data(contentsOf: command) == original)
    #expect(
      !FileManager.default.fileExists(
        atPath: prefix.appendingPathComponent("libexec/sim-use-network").path))
  }

  @Test
  func managedMarkerDoesNotAuthorizeAWrapperWithAnotherExecTarget() throws {
    let fixture = try makeCheckoutFixture()
    defer { withExtendedLifetime(fixture) {} }
    let prefix = fixture.root.appendingPathComponent("tampered", isDirectory: true)
    let installer = SourceInstaller(
      process: InstallProcess { _, _, _, _ in 0 },
      makeIdentifier: { "first" }
    )
    _ = try installer.install(
      installerExecutableURL: fixture.installer,
      prefix: prefix.path,
      environment: ["HOME": fixture.root.path, "PATH": "/usr/bin:/bin"]
    )
    let command = prefix.appendingPathComponent("bin/sim-use-network")
    try Data(
      """
      #!/bin/sh
      # sim-use-network installer-managed wrapper v1
      exec '/tmp/not-owned' "$@"

      """.utf8
    ).write(to: command)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: command.path
    )

    #expect(throws: (any Error).self) {
      _ = try SourceInstaller(
        process: InstallProcess { _, _, _, _ in 0 },
        makeIdentifier: { "second" }
      ).install(
        installerExecutableURL: fixture.installer,
        prefix: prefix.path,
        environment: ["HOME": fixture.root.path, "PATH": "/usr/bin:/bin"]
      )
    }
    #expect(try String(contentsOf: command, encoding: .utf8).contains("/tmp/not-owned"))
  }

  @Test
  func versionOneManagedWrapperRemainsUpgradeable() throws {
    let fixture = try makeCheckoutFixture()
    defer { withExtendedLifetime(fixture) {} }
    let prefix = fixture.root.appendingPathComponent("v1-upgrade", isDirectory: true)
    let layout = try SourceInstaller.layout(
      prefix: prefix.path,
      environment: [:],
      currentDirectory: fixture.root
    )
    let oldPayload = layout.payloadsDirectory.appendingPathComponent("old", isDirectory: true)
    try write(
      "format=1\n",
      to: oldPayload.appendingPathComponent(
        ".sim-use-network-install"))
    let oldExecutable = oldPayload.appendingPathComponent("sim-use-network").path
    try write(
      """
      #!/bin/sh
      # sim-use-network installer-managed wrapper v1
      exec '\(oldExecutable)' "$@"

      """,
      to: layout.command
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: layout.command.path
    )

    _ = try SourceInstaller(
      process: InstallProcess { _, _, _, _ in 0 },
      makeIdentifier: { "new" }
    ).install(
      installerExecutableURL: fixture.installer,
      prefix: prefix.path,
      environment: ["HOME": fixture.root.path, "PATH": "/usr/bin:/bin"]
    )

    let upgradedWrapper = try String(contentsOf: layout.command, encoding: .utf8)
    #expect(upgradedWrapper.contains("/payloads/new/sim-use-network"))
    #expect(FileManager.default.fileExists(atPath: oldPayload.path))
  }

  @Test
  func installLockRejectsAConcurrentInstaller() throws {
    let temporaryDirectory = try TestTemporaryDirectory(prefix: "sim-use-network-installer-tests")
    defer { withExtendedLifetime(temporaryDirectory) {} }
    let root = temporaryDirectory.url
    let lockURL = root.appendingPathComponent("install.lock")
    let first = try SourceInstallLock(url: lockURL)

    #expect(throws: (any Error).self) {
      _ = try SourceInstallLock(url: lockURL)
    }
    withExtendedLifetime(first) {}
  }

  private func makeCheckoutFixture(
    swiftBuildLayout: Bool = false
  ) throws -> CheckoutFixture {
    let temporaryDirectory = try TestTemporaryDirectory(prefix: "sim-use-network-installer-tests")
    let root = temporaryDirectory.url
    try Data("// swift-tools-version: 6.3\n".utf8).write(
      to: root.appendingPathComponent("Package.swift"))
    let build = root.appendingPathComponent(
      ".build/arm64-apple-macosx/release", isDirectory: true)
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    let installer = build.appendingPathComponent("sim-use-network-install")
    try makeExecutable(at: installer)
    try makeExecutable(at: build.appendingPathComponent("sim-use-network"))

    let coreBundle = build.appendingPathComponent(
      "sim-use-network_SimUseNetworkCore.bundle", isDirectory: true)
    let coreResourceRoot =
      swiftBuildLayout
      ? coreBundle.appendingPathComponent("Contents/Resources", isDirectory: true)
      : coreBundle
    try write(
      "shim",
      to: coreResourceRoot.appendingPathComponent(
        "RuntimeArtifacts/NetworkUnavailableShim.c"))

    let cliBundle = build.appendingPathComponent(
      "sim-use-network_SimUseNetworkCLI.bundle", isDirectory: true)
    let cliResourceRoot =
      swiftBuildLayout
      ? cliBundle.appendingPathComponent("Contents/Resources", isDirectory: true)
      : cliBundle
    try write(
      "skill",
      to: cliResourceRoot.appendingPathComponent(
        "skills/sim-use-network/SKILL.md"))
    try write(
      "marker",
      to: cliResourceRoot.appendingPathComponent(
        "skills/sim-use-network/.sim-use-network-skill"))
    return CheckoutFixture(
      temporaryDirectory: temporaryDirectory,
      installer: installer
    )
  }

  private func makeExecutable(at url: URL) throws {
    try write("#!/bin/sh\nexit 0\n", to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: url.path
    )
  }

  private func write(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
  }

}

private final class CheckoutFixture {
  private let temporaryDirectory: TestTemporaryDirectory
  let installer: URL

  var root: URL { temporaryDirectory.url }

  init(
    temporaryDirectory: TestTemporaryDirectory,
    installer: URL
  ) {
    self.temporaryDirectory = temporaryDirectory
    self.installer = installer
  }
}

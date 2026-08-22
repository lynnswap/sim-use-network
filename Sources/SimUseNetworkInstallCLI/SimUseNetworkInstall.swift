// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation

@main
struct SimUseNetworkInstall: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sim-use-network-install",
    abstract: "Build and install sim-use-network from a source checkout.",
    discussion: """
      Build and run the installer from the checkout:
        swift run -c release sim-use-network-install
      """,
    version: SimUseNetworkBuildInfo.version
  )

  @Option(
    help: "Install under <path>/bin and <path>/libexec/sim-use-network (default: ~/.local)."
  )
  var prefix: String?

  @Option(name: .customLong("prebuilt-artifacts"), help: .private)
  var prebuiltArtifacts: String?

  mutating func validate() throws {
    if let prefix, prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw ValidationError("--prefix must not be empty")
    }
    if let prebuiltArtifacts,
      prebuiltArtifacts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw ValidationError("--prebuilt-artifacts must not be empty")
    }
  }

  func run() throws {
    let environment = ProcessInfo.processInfo.environment
    let installer = SourceInstaller()
    let lines: [String]

    if let prebuiltArtifacts {
      let currentDirectory = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
      )
      let artifactsDirectory = URL(
        fileURLWithPath: prebuiltArtifacts,
        isDirectory: true,
        relativeTo: currentDirectory
      )
      // The release bootstrap passes its checksum-verified payload here so source and
      // prebuilt installs share one validation and atomic publication transaction.
      lines = try installer.installPrebuilt(
        artifactsDirectory: artifactsDirectory,
        prefix: prefix,
        environment: environment,
        currentDirectory: currentDirectory
      )
    } else {
      guard let executableURL = Bundle.main.executableURL else {
        throw SourceInstallError.message("Could not locate the installer executable.")
      }
      lines = try installer.install(
        installerExecutableURL: executableURL,
        prefix: prefix,
        environment: environment
      )
    }
    for line in lines {
      print(line)
    }
  }
}

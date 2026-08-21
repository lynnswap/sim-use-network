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
    version: "0.1.0-dev"
  )

  @Option(
    help: "Install under <path>/bin and <path>/libexec/sim-use-network (default: ~/.local)."
  )
  var prefix: String?

  mutating func validate() throws {
    if let prefix, prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw ValidationError("--prefix must not be empty")
    }
  }

  func run() throws {
    guard let executableURL = Bundle.main.executableURL else {
      throw SourceInstallError.message("Could not locate the installer executable.")
    }

    let lines = try SourceInstaller().install(
      installerExecutableURL: executableURL,
      prefix: prefix,
      environment: ProcessInfo.processInfo.environment
    )
    for line in lines {
      print(line)
    }
  }
}

// SPDX-License-Identifier: Apache-2.0

import ArgumentParser

@main
struct SimUseNetwork: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sim-use-network",
    abstract: "Simulate an unavailable network on an Apple Simulator.",
    version: SimUseNetworkBuildInfo.version,
    subcommands: [
      Prepare.self,
      Unavailable.self,
      Available.self,
      Status.self,
      Cleanup.self,
      Doctor.self,
      InstallSkill.self,
    ]
  )
}

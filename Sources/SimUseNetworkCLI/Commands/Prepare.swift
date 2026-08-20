// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import SimUseNetworkCore

struct Prepare: NetworkExecutableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Build the runtime shim, inject nsurlsessiond, and relaunch an installed app."
  )

  @OptionGroup var deviceOptions: DeviceOptions
  @OptionGroup var outputOptions: OutputOptions

  @Option(name: .long, help: "Installed app bundle identifier to relaunch with the shim.")
  var app: String

  @Flag(
    name: .long,
    help: "Allow a runtime build that has not passed the repository end-to-end gate."
  )
  var experimentalRuntime = false

  var jsonOutput: Bool { outputOptions.json }

  mutating func execute() throws -> SessionStatus {
    try NetworkSessionController.live().prepare(
      deviceIdentifier: deviceOptions.device,
      bundleIdentifier: app,
      experimentalRuntime: experimentalRuntime
    )
  }

  func format(_ result: SessionStatus) -> String {
    StatusText.render(result)
  }
}

// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import SimUseNetworkCore

struct Status: NetworkExecutableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Inspect live notify state and exact shim mappings for a prepared session."
  )

  @OptionGroup var deviceOptions: DeviceOptions
  @OptionGroup var outputOptions: OutputOptions

  var jsonOutput: Bool { outputOptions.json }

  mutating func execute() throws -> SessionStatus {
    try NetworkSessionController.live().status(deviceIdentifier: deviceOptions.device)
  }

  func format(_ result: SessionStatus) -> String {
    StatusText.render(result)
  }
}

// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import SimUseNetworkCore

struct Available: NetworkExecutableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Restore the prepared Simulator session to the available network state."
  )

  @OptionGroup var deviceOptions: DeviceOptions
  @OptionGroup var outputOptions: OutputOptions

  var jsonOutput: Bool { outputOptions.json }

  mutating func execute() throws -> SessionStatus {
    try NetworkSessionController.live().setAvailability(
      .available,
      deviceIdentifier: deviceOptions.device
    )
  }

  func format(_ result: SessionStatus) -> String {
    StatusText.render(result)
  }
}

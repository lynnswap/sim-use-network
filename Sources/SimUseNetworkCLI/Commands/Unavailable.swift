// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import SimUseNetworkCore

struct Unavailable: NetworkExecutableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Make the prepared Simulator session report no usable network path."
  )

  @OptionGroup var deviceOptions: DeviceOptions
  @OptionGroup var outputOptions: OutputOptions

  var jsonOutput: Bool { outputOptions.json }

  mutating func execute() throws -> SessionStatus {
    try NetworkSessionController.live().setAvailability(
      .unavailable,
      deviceIdentifier: deviceOptions.device
    )
  }

  func format(_ result: SessionStatus) -> String {
    StatusText.render(result)
  }
}

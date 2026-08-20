// SPDX-License-Identifier: Apache-2.0

import Foundation

package enum SimUseNetworkError: Error, LocalizedError {
  case invalidInput(String)
  case commandFailed(command: String, status: Int32, diagnostics: String)
  case noBootedDevice
  case ambiguousDevices([SimulatorDevice])
  case deviceNotFound(String)
  case sessionAlreadyExists(String)
  case sessionNotFound(String)
  case invalidSession(String)
  case verificationFailed(String)

  package var errorDescription: String? {
    switch self {
    case .invalidInput(let message),
      .invalidSession(let message),
      .verificationFailed(let message):
      message
    case .commandFailed(let command, let status, let diagnostics):
      "Command failed (status \(status)): \(command)\(diagnostics.isEmpty ? "" : "\n\(diagnostics)")"
    case .noBootedDevice:
      "No supported Apple Simulator is booted. Pass --device or boot exactly one Simulator."
    case .ambiguousDevices(let devices):
      "More than one supported Simulator is booted. Pass --device with one of: "
        + devices.map { "\($0.name) [\($0.udid)]" }.joined(separator: ", ")
    case .deviceNotFound(let identifier):
      "No booted Apple Simulator matches \(identifier)."
    case .sessionAlreadyExists(let udid):
      "A sim-use-network session already exists for \(udid). Run cleanup first."
    case .sessionNotFound(let udid):
      "No prepared sim-use-network session exists for \(udid). Run prepare first."
    }
  }
}

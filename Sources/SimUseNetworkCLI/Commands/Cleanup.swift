// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import SimUseNetworkCore

struct CleanupResult: Encodable {
  let deviceUDID: String
  let deviceName: String
  let state = "clean"
  let warnings: [String]
}

struct Cleanup: NetworkExecutableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Restore network, terminate the tool-launched app, and remove all injection."
  )

  @OptionGroup var deviceOptions: DeviceOptions
  @OptionGroup var outputOptions: OutputOptions

  var jsonOutput: Bool { outputOptions.json }

  mutating func execute() throws -> CleanupResult {
    let report = try NetworkSessionController.live().cleanup(
      deviceIdentifier: deviceOptions.device
    )
    return CleanupResult(
      deviceUDID: report.deviceUDID,
      deviceName: report.deviceName,
      warnings: report.warnings
    )
  }

  func format(_ result: CleanupResult) -> String {
    let summary = "Cleaned sim-use-network from \(result.deviceName) [\(result.deviceUDID)]."
    guard !result.warnings.isEmpty else { return summary }
    return summary + "\nWarnings:\n" + result.warnings.map { "- \($0)" }.joined(separator: "\n")
  }
}

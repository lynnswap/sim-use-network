// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import SimUseNetworkCore

struct Doctor: NetworkExecutableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Check device identity, daemon resolution, guest tools, and runtime validation."
  )

  @OptionGroup var deviceOptions: DeviceOptions
  @OptionGroup var outputOptions: OutputOptions

  var jsonOutput: Bool { outputOptions.json }

  mutating func execute() throws -> DoctorReport {
    try NetworkSessionController.live().doctor(deviceIdentifier: deviceOptions.device)
  }

  func format(_ report: DoctorReport) -> String {
    """
    Device: \(report.deviceName) [\(report.deviceUDID)]
    Runtime: \(report.platform) \(report.runtimeVersion) (\(report.runtimeBuild))
    Architectures: \(report.supportedArchitectures.joined(separator: ", "))
    URL loading daemon: \(report.daemonServiceTarget)
    notifyutil: available
    Host architecture: \(report.validationIdentity.architecture)
    Xcode build: \(report.validationIdentity.xcodeBuild)
    CoreSimulator build: \(report.validationIdentity.coreSimulatorBuild)
    Shim ABI: \(report.validationIdentity.shimABIVersion)
    E2E validation: \(report.runtimeValidated ? "passed" : "not recorded; prepare requires --experimental-runtime")
    """
  }
}

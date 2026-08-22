// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import SimUseNetworkCore

struct Doctor: NetworkExecutableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Check device identity, runtime support, daemon resolution, and guest tools."
  )

  @OptionGroup var deviceOptions: DeviceOptions
  @OptionGroup var outputOptions: OutputOptions

  var jsonOutput: Bool { outputOptions.json }

  mutating func execute() throws -> DoctorReport {
    try NetworkSessionController.live().doctor(deviceIdentifier: deviceOptions.device)
  }

  func format(_ report: DoctorReport) -> String {
    let support =
      switch report.platformSupport {
      case .supported: "supported"
      case .experimental: "experimental; prepare requires --experimental-runtime"
      }
    return """
      Device: \(report.deviceName) [\(report.deviceUDID)]
      Runtime: \(report.platform) \(report.runtimeVersion) (\(report.runtimeBuild))
      Architectures: \(report.supportedArchitectures.joined(separator: ", "))
      URL loading daemon: \(report.daemonServiceTarget)
      notifyutil: available
      Host architecture: \(report.runtimeIdentity.architecture)
      Xcode build: \(report.runtimeIdentity.xcodeBuild)
      CoreSimulator build: \(report.runtimeIdentity.coreSimulatorBuild)
      Shim ABI: \(report.runtimeIdentity.shimABIVersion)
      Platform support: \(support)
      """
  }
}

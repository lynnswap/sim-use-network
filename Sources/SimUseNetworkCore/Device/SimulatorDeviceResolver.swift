// SPDX-License-Identifier: Apache-2.0

import Foundation

package struct SimulatorDeviceResolver {
  private let processes: ProcessClient
  private let environment: [String: String]

  package init(
    processes: ProcessClient = .live,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.processes = processes
    self.environment = environment
  }

  package func resolve(explicitIdentifier: String?) throws -> SimulatorDevice {
    let devices = try loadDevices().filter { $0.isAvailable && $0.isBooted }
    let requestedIdentifier = explicitIdentifier ?? environment["SIM_USE_DEVICE"]

    if let requestedIdentifier {
      guard
        let device = devices.first(where: {
          $0.udid.caseInsensitiveCompare(requestedIdentifier) == .orderedSame
        })
      else {
        throw SimUseNetworkError.deviceNotFound(requestedIdentifier)
      }
      return device
    }

    guard !devices.isEmpty else {
      throw SimUseNetworkError.noBootedDevice
    }
    guard devices.count == 1 else {
      throw SimUseNetworkError.ambiguousDevices(devices)
    }
    return devices[0]
  }

  package func loadDevices() throws -> [SimulatorDevice] {
    let xcrun = URL(filePath: "/usr/bin/xcrun")
    let runtimeResult = try processes.checked(xcrun, ["simctl", "list", "runtimes", "--json"])
    let deviceResult = try processes.checked(xcrun, ["simctl", "list", "devices", "--json"])

    let runtimePayload = try JSONDecoder().decode(
      RuntimeListPayload.self,
      from: Data(runtimeResult.standardOutput.utf8)
    )
    let supportedRuntimes = runtimePayload.runtimes.compactMap {
      runtime -> (String, SimulatorRuntime)? in
      guard let platform = SimulatorPlatform(rawValue: runtime.platform) else {
        return nil
      }
      return (
        runtime.identifier,
        SimulatorRuntime(
          identifier: runtime.identifier,
          platform: platform,
          version: runtime.version,
          buildVersion: runtime.buildVersion,
          supportedArchitectures: runtime.supportedArchitectures,
          name: runtime.name
        )
      )
    }
    let runtimes = Dictionary(uniqueKeysWithValues: supportedRuntimes)

    let devicePayload = try JSONDecoder().decode(
      DeviceListPayload.self,
      from: Data(deviceResult.standardOutput.utf8)
    )
    return devicePayload.devices.flatMap { runtimeIdentifier, records -> [SimulatorDevice] in
      guard let runtime = runtimes[runtimeIdentifier] else { return [] }
      return records.map { record in
        SimulatorDevice(
          udid: record.udid,
          name: record.name,
          state: record.state,
          isAvailable: record.isAvailable,
          runtime: runtime
        )
      }
    }
  }
}

private struct RuntimeListPayload: Decodable {
  let runtimes: [RuntimeRecord]
}

private struct RuntimeRecord: Decodable {
  let identifier: String
  let platform: String
  let version: String
  let buildVersion: String
  let supportedArchitectures: [String]
  let name: String

  enum CodingKeys: String, CodingKey {
    case identifier
    case platform
    case version
    case buildVersion = "buildversion"
    case supportedArchitectures
    case name
  }
}

private struct DeviceListPayload: Decodable {
  let devices: [String: [DeviceRecord]]
}

private struct DeviceRecord: Decodable {
  let udid: String
  let name: String
  let state: String
  let isAvailable: Bool
}

// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import SimUseNetworkCore

@Suite
struct SimulatorDeviceResolverTests {
  @Test
  func explicitDeviceSelectsExactBootedSimulator() throws {
    let resolver = makeResolver(environment: [:])
    let device = try resolver.resolve(explicitIdentifier: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")

    #expect(device.name == "Test iPhone")
    #expect(device.runtime.platform == .iOS)
    #expect(device.runtime.buildVersion == "23F77")
  }

  @Test
  func environmentSelectsDeviceWhenOptionIsAbsent() throws {
    let resolver = makeResolver(environment: [
      "SIM_USE_DEVICE": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    ])
    let device = try resolver.resolve(explicitIdentifier: nil)

    #expect(device.name == "Test Watch")
    #expect(device.runtime.platform == .watchOS)
  }

  @Test
  func multipleBootedDevicesRequireExplicitSelection() throws {
    let resolver = makeResolver(environment: [:])

    do {
      _ = try resolver.resolve(explicitIdentifier: nil)
      Issue.record("Expected ambiguous device selection to fail")
    } catch let error as SimUseNetworkError {
      guard case .ambiguousDevices(let devices) = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
      #expect(devices.count == 2)
    }
  }

  private func makeResolver(environment: [String: String]) -> SimulatorDeviceResolver {
    let runtimeJSON = """
      {
        "runtimes": [
          {
            "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            "platform": "iOS",
            "version": "26.5",
            "buildversion": "23F77",
            "supportedArchitectures": ["arm64"],
            "name": "iOS 26.5"
          },
          {
            "identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-27-0",
            "platform": "watchOS",
            "version": "27.0",
            "buildversion": "24R5325f",
            "supportedArchitectures": ["arm64"],
            "name": "watchOS 27.0"
          },
          {
            "identifier": "com.apple.CoreSimulator.SimRuntime.futureOS-1-0",
            "platform": "futureOS",
            "version": "1.0",
            "buildversion": "1A1",
            "supportedArchitectures": ["arm64"],
            "name": "futureOS 1.0"
          }
        ]
      }
      """
    let deviceJSON = """
      {
        "devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
            {
              "udid": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
              "name": "Test iPhone",
              "state": "Booted",
              "isAvailable": true
            }
          ],
          "com.apple.CoreSimulator.SimRuntime.watchOS-27-0": [
            {
              "udid": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
              "name": "Test Watch",
              "state": "Booted",
              "isAvailable": true
            }
          ],
          "com.apple.CoreSimulator.SimRuntime.futureOS-1-0": [
            {
              "udid": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
              "name": "Future Device",
              "state": "Booted",
              "isAvailable": true
            }
          ]
        }
      }
      """
    let processes = ProcessClient { _, arguments, _ in
      let output = arguments.contains("runtimes") ? runtimeJSON : deviceJSON
      return ProcessResult(status: 0, standardOutput: output, standardError: "")
    }
    return SimulatorDeviceResolver(processes: processes, environment: environment)
  }
}

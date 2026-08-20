// SPDX-License-Identifier: Apache-2.0

import Foundation

package struct SimulatorRuntime: Codable, Equatable {
  package let identifier: String
  package let platform: SimulatorPlatform
  package let version: String
  package let buildVersion: String
  package let supportedArchitectures: [String]
  package let name: String
}

package struct SimulatorDevice: Codable, Equatable {
  package let udid: String
  package let name: String
  package let state: String
  package let isAvailable: Bool
  package let runtime: SimulatorRuntime

  package var isBooted: Bool { state == "Booted" }
}

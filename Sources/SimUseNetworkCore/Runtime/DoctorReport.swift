// SPDX-License-Identifier: Apache-2.0

package struct DoctorReport: Codable, Equatable {
  package let deviceUDID: String
  package let deviceName: String
  package let platform: String
  package let runtimeVersion: String
  package let runtimeBuild: String
  package let supportedArchitectures: [String]
  package let daemonServiceTarget: String
  package let notifyUtilityAvailable: Bool
  package let runtimeIdentity: RuntimeIdentity
  package let platformSupport: SimulatorPlatformSupport
}

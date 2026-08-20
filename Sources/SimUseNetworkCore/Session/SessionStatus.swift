// SPDX-License-Identifier: Apache-2.0

import Foundation

package struct SessionStatus: Codable, Equatable {
  package let deviceUDID: String
  package let deviceName: String
  package let platform: String
  package let runtimeVersion: String
  package let runtimeBuild: String
  package let bundleIdentifier: String
  package let phase: SessionPhase
  package let availability: NetworkAvailability
  package let appProcessIdentifier: Int32?
  package let daemonProcessIdentifier: Int32?
  package let daemonRunCount: UInt64?
  package let keeperProcessIdentifier: Int32?
  package let notifyDaemonProcessIdentifier: Int32
  package let notifyDaemonRunCount: UInt64
  package let appShimLoaded: Bool
  package let daemonShimLoaded: Bool
  package let keeperRunning: Bool
  package let notifyDaemonStable: Bool
}

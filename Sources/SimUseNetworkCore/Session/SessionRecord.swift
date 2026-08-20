// SPDX-License-Identifier: Apache-2.0

import Foundation

package enum NetworkAvailability: String, Codable {
  case available
  case unavailable
}

package enum SessionPhase: String, Codable {
  case staged
  case keeperStarting
  case keeperRunning
  case daemonDebugArmed
  case daemonInjected
  case appLaunching
  case ready
  case recovering
}

package struct SessionRecord: Codable, Equatable {
  package static let currentSchemaVersion = 1

  package let schemaVersion: Int
  package let sessionID: UUID
  package let device: SimulatorDevice
  package let bundleIdentifier: String
  package let daemonServiceTarget: String
  package let stateName: String
  package let keeperReadyName: String
  package let appShimReadyName: String
  package let daemonShimReadyName: String
  package let shimPath: String
  package var keeperServiceTarget: String
  package let keeperPlistPath: String
  package var phase: SessionPhase
  package var availability: NetworkAvailability
  package var appProcessIdentifier: Int32?
  package var ownsAppLaunch: Bool
  package var daemonProcessIdentifier: Int32?
  package var daemonRunCount: UInt64?
  package var keeperProcessIdentifier: Int32?
  package let notifyDaemonProcessIdentifier: Int32
  package let notifyDaemonRunCount: UInt64
  package let createdAt: Date

  package init(
    sessionID: UUID,
    device: SimulatorDevice,
    bundleIdentifier: String,
    daemonServiceTarget: String,
    stateName: String,
    keeperReadyName: String,
    appShimReadyName: String,
    daemonShimReadyName: String,
    shimPath: String,
    keeperServiceTarget: String,
    keeperPlistPath: String,
    phase: SessionPhase,
    availability: NetworkAvailability,
    appProcessIdentifier: Int32? = nil,
    ownsAppLaunch: Bool = false,
    daemonProcessIdentifier: Int32? = nil,
    daemonRunCount: UInt64? = nil,
    keeperProcessIdentifier: Int32? = nil,
    notifyDaemonProcessIdentifier: Int32,
    notifyDaemonRunCount: UInt64,
    createdAt: Date = Date()
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.sessionID = sessionID
    self.device = device
    self.bundleIdentifier = bundleIdentifier
    self.daemonServiceTarget = daemonServiceTarget
    self.stateName = stateName
    self.keeperReadyName = keeperReadyName
    self.appShimReadyName = appShimReadyName
    self.daemonShimReadyName = daemonShimReadyName
    self.shimPath = shimPath
    self.keeperServiceTarget = keeperServiceTarget
    self.keeperPlistPath = keeperPlistPath
    self.phase = phase
    self.availability = availability
    self.appProcessIdentifier = appProcessIdentifier
    self.ownsAppLaunch = ownsAppLaunch
    self.daemonProcessIdentifier = daemonProcessIdentifier
    self.daemonRunCount = daemonRunCount
    self.keeperProcessIdentifier = keeperProcessIdentifier
    self.notifyDaemonProcessIdentifier = notifyDaemonProcessIdentifier
    self.notifyDaemonRunCount = notifyDaemonRunCount
    self.createdAt = createdAt
  }
}

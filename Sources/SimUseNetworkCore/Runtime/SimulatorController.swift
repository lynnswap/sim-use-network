// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

package struct StateKeeperStartResult: Equatable {
  package let serviceTarget: String
  package let processIdentifier: Int32
}

package struct LaunchdServiceIdentity: Codable, Equatable {
  package let processIdentifier: Int32
  package let runCount: UInt64
}

private struct StateKeeperServiceState {
  let serviceTarget: String
  let processIdentifier: Int32?
}

package struct SimulatorTimeouts: Sendable {
  package let keeper: TimeInterval
  package let daemon: TimeInterval
  package let app: TimeInterval
  package let notification: TimeInterval
  package let mapping: TimeInterval
  package let cleanup: TimeInterval

  package static let standard = SimulatorTimeouts(
    keeper: 5,
    daemon: 15,
    app: 10,
    notification: 5,
    mapping: 10,
    cleanup: 10
  )
}

package struct SimulatorController {
  private static let daemonLabel = "com.apple.nsurlsessiond"
  private static let networkChangeNotification = "com.apple.system.SystemConfiguration.nwi"

  private let processes: ProcessClient
  private let timeouts: SimulatorTimeouts
  private let xcrun = URL(filePath: "/usr/bin/xcrun")

  package init(
    processes: ProcessClient = .live,
    timeouts: SimulatorTimeouts = .standard
  ) {
    self.processes = processes
    self.timeouts = timeouts
  }

  package func inheritingLease(from lock: DeviceLock) -> SimulatorController {
    SimulatorController(
      processes: processes.inheritingLease(from: lock),
      timeouts: timeouts
    )
  }

  package func resolveDaemonServiceTarget(
    deviceUDID: String,
    platform: SimulatorPlatform
  ) throws -> String {
    let candidates = platform.daemonServiceCandidates
    var failures: [String] = []
    for candidate in candidates {
      let result = try processes.run(
        xcrun,
        ["simctl", "spawn", deviceUDID, "launchctl", "print", candidate],
        [:]
      )
      guard result.status == 0 else {
        failures.append("\(candidate): \(result.combinedOutput)")
        continue
      }
      guard let canonical = Self.parseCanonicalServiceTarget(result.standardOutput),
        canonical.hasSuffix("/\(Self.daemonLabel)")
      else {
        failures.append("\(candidate): canonical service target was not present")
        continue
      }
      return canonical
    }
    throw SimUseNetworkError.verificationFailed(
      "Could not resolve the Simulator URL loading daemon.\n\(failures.joined(separator: "\n"))"
    )
  }

  package func verifyInstalledApp(bundleIdentifier: String, deviceUDID: String) throws {
    _ = try processes.checked(
      xcrun,
      ["simctl", "get_app_container", deviceUDID, bundleIdentifier, "app"]
    )
  }

  package func verifyNotifyUtility(deviceUDID: String) throws {
    _ = try processes.checked(
      xcrun,
      ["simctl", "spawn", deviceUDID, "notifyutil", "-h"]
    )
  }

  package func armDaemonInjection(_ record: SessionRecord) throws {
    _ = try processes.checked(
      xcrun,
      [
        "simctl", "spawn", record.device.udid,
        "launchctl", "debug", record.daemonServiceTarget,
        "--environment",
        "DYLD_INSERT_LIBRARIES=\(record.shimPath)",
        "SIM_USE_NETWORK_STATE_NAME=\(record.stateName)",
        "SIM_USE_NETWORK_READY_NAME=\(record.daemonShimReadyName)",
        "--",
      ]
    )
  }

  package func startStateKeeper(_ record: SessionRecord) throws -> StateKeeperStartResult {
    let domainTarget = Self.domainTarget(from: record.keeperServiceTarget)
    _ = try processes.checked(
      xcrun,
      [
        "simctl", "spawn", record.device.udid,
        "launchctl", "bootstrap", domainTarget, record.keeperPlistPath,
      ]
    )
    guard let service = try stateKeeperServiceState(record) else {
      throw SimUseNetworkError.verificationFailed(
        "The Darwin state keeper was not loaded after bootstrap."
      )
    }
    let processIdentifier = try kickstartStateKeeper(
      deviceUDID: record.device.udid,
      serviceTarget: service.serviceTarget
    )
    try waitForStateKeeperReadiness(
      record,
      serviceTarget: service.serviceTarget,
      processIdentifier: processIdentifier
    )
    return StateKeeperStartResult(
      serviceTarget: service.serviceTarget,
      processIdentifier: processIdentifier
    )
  }

  package func stopStateKeeper(_ record: SessionRecord) throws {
    guard try stateKeeperServiceState(record) != nil else { return }
    _ = try processes.checked(
      xcrun,
      [
        "simctl", "spawn", record.device.udid,
        "launchctl", "bootout", record.keeperServiceTarget,
      ]
    )
    guard
      try waitUntil(
        timeout: timeouts.cleanup,
        condition: {
          try stateKeeperServiceState(record) == nil
        })
    else {
      throw SimUseNetworkError.verificationFailed(
        "The Darwin state keeper is still running after bootout."
      )
    }
  }

  package func stateKeeperProcessIdentifierIfRunning(
    _ record: SessionRecord
  ) throws -> Int32? {
    try stateKeeperServiceState(record)?.processIdentifier
  }

  package func verifyStateKeeper(_ record: SessionRecord) throws {
    guard let expectedProcessIdentifier = record.keeperProcessIdentifier,
      let service = try stateKeeperServiceState(record),
      service.processIdentifier == expectedProcessIdentifier
    else {
      throw SimUseNetworkError.invalidSession(
        "The Darwin state keeper restarted or stopped. Run cleanup."
      )
    }
    guard
      try readNotifyState(
        name: record.keeperReadyName,
        deviceUDID: record.device.udid
      ) == 1
    else {
      throw SimUseNetworkError.invalidSession(
        "The Darwin state keeper registration was lost. Run cleanup."
      )
    }
  }

  package func notifyDaemonIdentity(deviceUDID: String) throws -> LaunchdServiceIdentity {
    try serviceIdentity(
      deviceUDID: deviceUDID,
      serviceTarget: "system/com.apple.notifyd",
      serviceName: "notifyd"
    )
  }

  private func stateKeeperServiceState(
    _ record: SessionRecord
  ) throws -> StateKeeperServiceState? {
    let result = try processes.run(
      xcrun,
      [
        "simctl", "spawn", record.device.udid,
        "launchctl", "print", record.keeperServiceTarget,
      ],
      [:]
    )
    if result.status != 0 {
      if result.status == 113 {
        return nil
      }
      throw SimUseNetworkError.commandFailed(
        command:
          "xcrun simctl spawn \(record.device.udid) launchctl print \(record.keeperServiceTarget)",
        status: result.status,
        diagnostics: result.combinedOutput
      )
    }
    guard let canonicalTarget = Self.parseCanonicalServiceTarget(result.standardOutput) else {
      throw SimUseNetworkError.verificationFailed(
        "launchctl did not report the state keeper's canonical target."
      )
    }
    return StateKeeperServiceState(
      serviceTarget: canonicalTarget,
      processIdentifier: Self.parseProcessIdentifier(result.standardOutput)
    )
  }

  private func waitForStateKeeperReadiness(
    _ record: SessionRecord,
    serviceTarget: String,
    processIdentifier: Int32
  ) throws {
    let ready = try waitUntil(
      timeout: timeouts.keeper,
      condition: {
        _ = try processes.checked(
          xcrun,
          [
            "simctl", "spawn", record.device.udid,
            "notifyutil", "-s", record.keeperReadyName, "1",
          ]
        )
        if try readNotifyState(
          name: record.keeperReadyName,
          deviceUDID: record.device.udid
        ) == 1 {
          return true
        }
        return false
      })
    guard ready else {
      throw SimUseNetworkError.verificationFailed(
        "The Darwin state keeper did not register before the readiness deadline."
      )
    }

    let refreshedProcessIdentifier = try kickstartStateKeeper(
      deviceUDID: record.device.udid,
      serviceTarget: serviceTarget
    )
    guard refreshedProcessIdentifier == processIdentifier else {
      throw SimUseNetworkError.verificationFailed(
        "The Darwin state keeper restarted during readiness verification."
      )
    }
  }

  private func kickstartStateKeeper(
    deviceUDID: String,
    serviceTarget: String
  ) throws -> Int32 {
    let result = try processes.checked(
      xcrun,
      [
        "simctl", "spawn", deviceUDID,
        "launchctl", "kickstart", "-p", serviceTarget,
      ]
    )
    guard
      let processIdentifier = Int32(
        result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    else {
      throw SimUseNetworkError.verificationFailed(
        "launchctl did not return the state keeper process identifier."
      )
    }
    return processIdentifier
  }

  package func restartDaemon(deviceUDID: String, serviceTarget: String) throws -> Int32 {
    let result = try processes.checked(
      xcrun,
      [
        "simctl", "spawn", deviceUDID,
        "launchctl", "kickstart", "-k", "-p", serviceTarget,
      ]
    )
    guard
      let processIdentifier = Int32(
        result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    else {
      throw SimUseNetworkError.verificationFailed(
        "launchctl did not return the URL loading daemon process identifier."
      )
    }
    try waitForDaemonReady(
      deviceUDID: deviceUDID,
      serviceTarget: serviceTarget,
      processIdentifier: processIdentifier
    )
    return processIdentifier
  }

  private func waitForDaemonReady(
    deviceUDID: String,
    serviceTarget: String,
    processIdentifier: Int32
  ) throws {
    let ready = try waitUntil(
      timeout: timeouts.daemon,
      condition: {
        let result = try processes.checked(
          xcrun,
          ["simctl", "spawn", deviceUDID, "launchctl", "print", serviceTarget]
        )
        if Self.parseProcessIdentifier(result.standardOutput) == processIdentifier,
          Self.parseServiceIsRunning(result.standardOutput)
        {
          return true
        }
        return false
      })
    guard ready else {
      throw SimUseNetworkError.verificationFailed(
        "The URL loading daemon did not reach running state with pid \(processIdentifier)."
      )
    }
  }

  package func daemonProcessIdentifier(
    deviceUDID: String,
    serviceTarget: String
  ) throws -> Int32 {
    try daemonIdentity(
      deviceUDID: deviceUDID,
      serviceTarget: serviceTarget
    ).processIdentifier
  }

  package func daemonIdentity(
    deviceUDID: String,
    serviceTarget: String
  ) throws -> LaunchdServiceIdentity {
    try serviceIdentity(
      deviceUDID: deviceUDID,
      serviceTarget: serviceTarget,
      serviceName: "URL loading daemon"
    )
  }

  private func serviceIdentity(
    deviceUDID: String,
    serviceTarget: String,
    serviceName: String
  ) throws -> LaunchdServiceIdentity {
    let result = try processes.checked(
      xcrun,
      ["simctl", "spawn", deviceUDID, "launchctl", "print", serviceTarget]
    )
    guard let processIdentifier = Self.parseProcessIdentifier(result.standardOutput),
      let runCount = Self.parseRunCount(result.standardOutput)
    else {
      throw SimUseNetworkError.verificationFailed(
        "The \(serviceName) is not running or has no launch generation for \(deviceUDID)."
      )
    }
    return LaunchdServiceIdentity(
      processIdentifier: processIdentifier,
      runCount: runCount
    )
  }

  package func launchApp(_ record: SessionRecord) throws -> Int32 {
    let result = try processes.checked(
      xcrun,
      [
        "simctl", "launch", "--terminate-running-process",
        record.device.udid, record.bundleIdentifier,
      ],
      environment: [
        "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": record.shimPath,
        "SIMCTL_CHILD_SIM_USE_NETWORK_STATE_NAME": record.stateName,
        "SIMCTL_CHILD_SIM_USE_NETWORK_READY_NAME": record.appShimReadyName,
      ]
    )
    guard let processIdentifier = Self.parseLaunchProcessIdentifier(result.standardOutput) else {
      throw SimUseNetworkError.verificationFailed(
        "simctl did not report the launched app process identifier: \(result.standardOutput)"
      )
    }
    return processIdentifier
  }

  package func waitForAppProcess(
    _ expectedProcessIdentifier: Int32,
    bundleIdentifier: String,
    deviceUDID: String,
    daemonServiceTarget: String
  ) throws -> Bool {
    try waitUntil(
      timeout: timeouts.app,
      condition: {
        let processIdentifiers = try appProcessIdentifiers(
          bundleIdentifier: bundleIdentifier,
          deviceUDID: deviceUDID,
          daemonServiceTarget: daemonServiceTarget
        )
        if processIdentifiers.contains(expectedProcessIdentifier) {
          return true
        }
        return false
      })
  }

  package func isAppProcessCurrent(_ record: SessionRecord) throws -> Bool {
    guard let expectedProcessIdentifier = record.appProcessIdentifier else {
      return false
    }
    return try appProcessIdentifiers(
      bundleIdentifier: record.bundleIdentifier,
      deviceUDID: record.device.udid,
      daemonServiceTarget: record.daemonServiceTarget
    ).contains(expectedProcessIdentifier)
  }

  private func appProcessIdentifiers(
    bundleIdentifier: String,
    deviceUDID: String,
    daemonServiceTarget: String
  ) throws -> [Int32] {
    let domainTarget = Self.domainTarget(from: daemonServiceTarget)
    let result = try processes.checked(
      xcrun,
      ["simctl", "spawn", deviceUDID, "launchctl", "print", domainTarget]
    )
    let marker = "UIKitApplication:\(bundleIdentifier)["
    return result.standardOutput.split(separator: "\n").compactMap { line in
      guard line.contains(marker),
        let processIdentifier = line.split(whereSeparator: { $0.isWhitespace }).first,
        let value = Int32(processIdentifier),
        value > 0
      else {
        return nil
      }
      return value
    }
  }

  package func terminateInjectedApp(_ record: SessionRecord) throws -> Bool {
    for processIdentifier in try injectedAppProcessIdentifiers(record) {
      if Darwin.kill(processIdentifier, SIGTERM) != 0, errno != ESRCH {
        throw SimUseNetworkError.invalidSession(
          "Could not terminate injected app pid \(processIdentifier): errno \(errno)."
        )
      }
    }
    return try waitUntil(
      timeout: timeouts.cleanup,
      condition: {
        if try injectedAppProcessIdentifiers(record).isEmpty {
          return true
        }
        return false
      })
  }

  private func injectedAppProcessIdentifiers(_ record: SessionRecord) throws -> [Int32] {
    let libraryURL = URL(filePath: record.shimPath)
    return try appProcessIdentifiers(
      bundleIdentifier: record.bundleIdentifier,
      deviceUDID: record.device.udid,
      daemonServiceTarget: record.daemonServiceTarget
    ).filter { processIdentifier in
      try isLibraryMapped(
        libraryURL: libraryURL,
        processIdentifier: processIdentifier
      )
    }
  }

  package func setAvailability(
    _ availability: NetworkAvailability,
    stateName: String,
    deviceUDID: String
  ) throws {
    let state = availability == .unavailable ? "1" : "0"
    _ = try processes.checked(
      xcrun,
      [
        "simctl", "spawn", deviceUDID,
        "notifyutil",
        "-s", stateName, state,
        "-p", stateName,
      ]
    )
    let observed = try readAvailability(stateName: stateName, deviceUDID: deviceUDID)
    guard observed == availability else {
      throw SimUseNetworkError.verificationFailed(
        "Darwin notify state did not change to \(availability.rawValue)."
      )
    }
  }

  package func postNetworkChange(deviceUDID: String) throws {
    _ = try processes.checked(
      xcrun,
      [
        "simctl", "spawn", deviceUDID,
        "notifyutil", "-p", Self.networkChangeNotification,
      ]
    )
  }

  package func setNotifyState(
    _ value: UInt64,
    name: String,
    deviceUDID: String
  ) throws {
    let result = try processes.checked(
      xcrun,
      [
        "simctl", "spawn", deviceUDID,
        "notifyutil", "-s", name, String(value), "-p", name, "-g", name,
      ]
    )
    guard Self.parseNotifyState(result.standardOutput) == value else {
      throw SimUseNetworkError.verificationFailed(
        "Darwin notify state \(name) did not change to \(value)."
      )
    }
  }

  package func verifyNotifyState(
    _ expectedValue: UInt64,
    name: String,
    deviceUDID: String
  ) throws {
    let value = try readNotifyState(name: name, deviceUDID: deviceUDID)
    guard value == expectedValue else {
      throw SimUseNetworkError.verificationFailed(
        "Darwin notify state \(name) was \(value), expected \(expectedValue)."
      )
    }
  }

  package func waitForNotifyState(
    _ expectedValue: UInt64,
    name: String,
    deviceUDID: String
  ) throws -> Bool {
    try waitUntil(
      timeout: timeouts.notification,
      condition: {
        if try readNotifyState(name: name, deviceUDID: deviceUDID) == expectedValue {
          return true
        }
        return false
      })
  }

  package func readAvailability(
    stateName: String,
    deviceUDID: String
  ) throws -> NetworkAvailability {
    let state = try readNotifyState(name: stateName, deviceUDID: deviceUDID)
    switch state {
    case 0: return .available
    case 1: return .unavailable
    default:
      throw SimUseNetworkError.verificationFailed(
        "notifyutil returned an unexpected state for \(stateName): \(state)."
      )
    }
  }

  private func readNotifyState(name: String, deviceUDID: String) throws -> UInt64 {
    let result = try processes.checked(
      xcrun,
      ["simctl", "spawn", deviceUDID, "notifyutil", "-g", name]
    )
    guard let state = Self.parseNotifyState(result.standardOutput) else {
      throw SimUseNetworkError.verificationFailed(
        "notifyutil did not return a state for \(name)."
      )
    }
    return state
  }

  package func isLibraryMapped(libraryURL: URL, processIdentifier: Int32) throws -> Bool {
    guard isProcessRunning(processIdentifier) else { return false }
    let result = try processes.run(
      URL(filePath: "/usr/bin/vmmap"),
      ["-w", String(processIdentifier)],
      [:]
    )
    if result.status != 0 {
      if !isProcessRunning(processIdentifier) {
        return false
      }
      throw SimUseNetworkError.commandFailed(
        command: "/usr/bin/vmmap -w \(processIdentifier)",
        status: result.status,
        diagnostics: result.combinedOutput
      )
    }
    return result.standardOutput.contains(libraryURL.path)
  }

  package func waitForLibraryMapping(
    libraryURL: URL,
    processIdentifier: Int32
  ) throws -> Bool {
    try waitUntil(
      timeout: timeouts.mapping,
      condition: {
        let result = try processes.run(
          URL(filePath: "/usr/bin/vmmap"),
          ["-w", String(processIdentifier)],
          [:]
        )
        if result.status == 0, result.standardOutput.contains(libraryURL.path) {
          return true
        }
        return false
      })
  }

  package func isProcessRunning(_ processIdentifier: Int32) -> Bool {
    if Darwin.kill(processIdentifier, 0) == 0 {
      return true
    }
    return errno == EPERM
  }

  private func waitUntil(
    timeout: TimeInterval,
    condition: () throws -> Bool
  ) rethrows -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while true {
      if try condition() {
        return true
      }
      if ProcessInfo.processInfo.systemUptime >= deadline {
        return false
      }
      usleep(50_000)
    }
  }

  private static func parseCanonicalServiceTarget(_ output: String) -> String? {
    guard let firstLine = output.split(separator: "\n", omittingEmptySubsequences: true).first,
      let delimiter = firstLine.range(of: " = {")
    else {
      return nil
    }
    return String(firstLine[..<delimiter.lowerBound]).trimmingCharacters(in: .whitespaces)
  }

  private static func domainTarget(from serviceTarget: String) -> String {
    serviceTarget.split(separator: "/").dropLast().joined(separator: "/")
  }

  private static func parseProcessIdentifier(_ output: String) -> Int32? {
    for line in output.split(separator: "\n") {
      let components = line.split(separator: "=", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      if components.count == 2, components[0] == "pid", let value = Int32(components[1]) {
        return value
      }
    }
    return nil
  }

  private static func parseRunCount(_ output: String) -> UInt64? {
    for line in output.split(separator: "\n") {
      let components = line.split(separator: "=", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      if components.count == 2,
        components[0] == "runs",
        let value = UInt64(components[1])
      {
        return value
      }
    }
    return nil
  }

  private static func parseServiceIsRunning(_ output: String) -> Bool {
    output.split(separator: "\n").contains { line in
      let components = line.split(separator: "=", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      return components.count == 2
        && components[0] == "state"
        && components[1] == "running"
    }
  }

  private static func parseLaunchProcessIdentifier(_ output: String) -> Int32? {
    guard let suffix = output.split(separator: ":").last else { return nil }
    return Int32(suffix.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func parseNotifyState(_ output: String) -> UInt64? {
    guard let value = output.split(whereSeparator: { $0.isWhitespace }).last else {
      return nil
    }
    return UInt64(value)
  }
}

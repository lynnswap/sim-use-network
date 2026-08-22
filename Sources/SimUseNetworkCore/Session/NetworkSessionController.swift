// SPDX-License-Identifier: Apache-2.0

import Foundation

private struct SessionIntegrity {
  let app: Bool
  let daemon: Bool
  let keeper: Bool
  let notifyDaemon: Bool
}

package struct NetworkSessionController {
  private let devices: SimulatorDeviceResolver
  private let store: SessionStore
  private let artifacts: RuntimeArtifactCompiler
  private let simulator: SimulatorController
  private let stateKeeperPlists: StateKeeperPlistWriter
  private let compatibility: RuntimeCompatibility

  package init(
    devices: SimulatorDeviceResolver = SimulatorDeviceResolver(),
    store: SessionStore,
    artifacts: RuntimeArtifactCompiler,
    simulator: SimulatorController = SimulatorController(),
    stateKeeperPlists: StateKeeperPlistWriter = StateKeeperPlistWriter(),
    compatibility: RuntimeCompatibility = RuntimeCompatibility()
  ) {
    self.devices = devices
    self.store = store
    self.artifacts = artifacts
    self.simulator = simulator
    self.stateKeeperPlists = stateKeeperPlists
    self.compatibility = compatibility
  }

  package static func live() throws -> NetworkSessionController {
    try NetworkSessionController(
      store: SessionStore(),
      artifacts: RuntimeArtifactCompiler()
    )
  }

  private func inheritingLease(from lock: DeviceLock) -> NetworkSessionController {
    NetworkSessionController(
      devices: devices,
      store: store,
      artifacts: artifacts.inheritingLease(from: lock),
      simulator: simulator.inheritingLease(from: lock),
      stateKeeperPlists: stateKeeperPlists,
      compatibility: compatibility.inheritingLease(from: lock)
    )
  }

  package func prepare(
    deviceIdentifier: String?,
    bundleIdentifier: String,
    experimentalRuntime: Bool
  ) throws -> SessionStatus {
    try Self.validateBundleIdentifier(bundleIdentifier)
    let device = try devices.resolve(explicitIdentifier: deviceIdentifier)
    let lock = try store.acquireLock(deviceUDID: device.udid)
    defer { withExtendedLifetime(lock) {} }
    let controller = inheritingLease(from: lock)
    let platformSupport = device.runtime.platform.support
    guard platformSupport.permitsPreparation(experimentalOptIn: experimentalRuntime) else {
      throw SimUseNetworkError.invalidInput(
        "\(device.runtime.platform.displayName) runtime behavior is experimental. "
          + "Pass --experimental-runtime to opt in."
      )
    }

    guard try controller.store.load(deviceUDID: device.udid) == nil else {
      throw SimUseNetworkError.sessionAlreadyExists(device.udid)
    }
    try controller.simulator.verifyInstalledApp(
      bundleIdentifier: bundleIdentifier,
      deviceUDID: device.udid
    )
    let serviceTarget = try controller.simulator.resolveDaemonServiceTarget(
      deviceUDID: device.udid,
      platform: device.runtime.platform
    )
    let notifyDaemonIdentity = try controller.simulator.notifyDaemonIdentity(
      deviceUDID: device.udid
    )
    let sessionID = UUID()
    let stateName = "io.github.lynnswap.sim-use-network.\(device.udid).\(sessionID.uuidString)"
    let keeperReadyName = "\(stateName).keeper-ready"
    let appShimReadyName = "\(stateName).app-ready"
    let daemonShimReadyName = "\(stateName).daemon-ready"
    let keeperLabel =
      "io.github.lynnswap.sim-use-network.keeper."
      + sessionID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let serviceDomain = serviceTarget.split(separator: "/").dropLast().joined(separator: "/")
    let keeperServiceTarget = "\(serviceDomain)/\(keeperLabel)"
    let directory = try controller.store.createFreshSessionDirectory(deviceUDID: device.udid)
    let keeperPlistURL = directory.appending(path: "state-keeper.plist")
    let shimURL = directory.appending(path: "libSimUseNetworkShim.dylib")
    try controller.stateKeeperPlists.write(
      label: keeperLabel,
      stateName: stateName,
      readyName: keeperReadyName,
      appShimReadyName: appShimReadyName,
      daemonShimReadyName: daemonShimReadyName,
      userName: serviceDomain == "system" ? "mobile" : nil,
      to: keeperPlistURL
    )
    var record = SessionRecord(
      sessionID: sessionID,
      device: device,
      bundleIdentifier: bundleIdentifier,
      daemonServiceTarget: serviceTarget,
      stateName: stateName,
      keeperReadyName: keeperReadyName,
      appShimReadyName: appShimReadyName,
      daemonShimReadyName: daemonShimReadyName,
      shimPath: shimURL.path,
      keeperServiceTarget: keeperServiceTarget,
      keeperPlistPath: keeperPlistURL.path,
      phase: .staged,
      availability: .available,
      notifyDaemonProcessIdentifier: notifyDaemonIdentity.processIdentifier,
      notifyDaemonRunCount: notifyDaemonIdentity.runCount
    )
    try controller.store.save(record)

    let artifact: RuntimeArtifact
    do {
      artifact = try controller.artifacts.compile(for: device.runtime, in: directory)
    } catch {
      try? controller.store.remove(deviceUDID: device.udid)
      throw error
    }
    guard artifact.libraryURL.standardizedFileURL == shimURL.standardizedFileURL else {
      try? controller.store.remove(deviceUDID: device.udid)
      throw SimUseNetworkError.verificationFailed(
        "Runtime artifact compiler returned an unexpected output path."
      )
    }

    do {
      record.phase = .keeperStarting
      try controller.store.save(record)
      let keeper = try controller.simulator.startStateKeeper(record)
      record.keeperServiceTarget = keeper.serviceTarget
      record.keeperProcessIdentifier = keeper.processIdentifier
      record.phase = .keeperRunning
      try controller.store.save(record)
      try controller.simulator.setNotifyState(
        0,
        name: record.appShimReadyName,
        deviceUDID: device.udid
      )
      try controller.simulator.setNotifyState(
        0,
        name: record.daemonShimReadyName,
        deviceUDID: device.udid
      )
      try controller.simulator.setAvailability(
        .available,
        stateName: record.stateName,
        deviceUDID: device.udid
      )
      guard
        try controller.simulator.notifyDaemonIdentity(deviceUDID: device.udid)
          == LaunchdServiceIdentity(
            processIdentifier: record.notifyDaemonProcessIdentifier,
            runCount: record.notifyDaemonRunCount
          )
      else {
        throw SimUseNetworkError.verificationFailed(
          "notifyd restarted during prepare."
        )
      }
      record.phase = .daemonDebugArmed
      try controller.store.save(record)
      try controller.simulator.armDaemonInjection(record)
      let daemonProcessIdentifier = try controller.simulator.restartDaemon(
        deviceUDID: device.udid,
        serviceTarget: serviceTarget
      )
      guard
        try controller.simulator.waitForLibraryMapping(
          libraryURL: artifact.libraryURL,
          processIdentifier: daemonProcessIdentifier
        )
      else {
        throw SimUseNetworkError.verificationFailed(
          "The shim was not loaded in nsurlsessiond (pid \(daemonProcessIdentifier))."
        )
      }
      guard
        try controller.simulator.waitForNotifyState(
          1,
          name: record.daemonShimReadyName,
          deviceUDID: device.udid
        )
      else {
        throw SimUseNetworkError.verificationFailed(
          "nsurlsessiond loaded the shim but did not acknowledge healthy state registration."
        )
      }
      let daemonIdentity = try controller.simulator.daemonIdentity(
        deviceUDID: device.udid,
        serviceTarget: serviceTarget
      )
      guard daemonIdentity.processIdentifier == daemonProcessIdentifier else {
        throw SimUseNetworkError.verificationFailed(
          "nsurlsessiond restarted while verifying the shim mapping."
        )
      }

      record.phase = .daemonInjected
      record.daemonProcessIdentifier = daemonProcessIdentifier
      record.daemonRunCount = daemonIdentity.runCount
      try controller.store.save(record)
      record.phase = .appLaunching
      record.ownsAppLaunch = true
      try controller.store.save(record)

      let appProcessIdentifier = try controller.simulator.launchApp(record)
      record.appProcessIdentifier = appProcessIdentifier
      try controller.store.save(record)
      guard
        try controller.simulator.waitForAppProcess(
          appProcessIdentifier,
          bundleIdentifier: bundleIdentifier,
          deviceUDID: device.udid,
          daemonServiceTarget: serviceTarget
        )
      else {
        throw SimUseNetworkError.verificationFailed(
          "The launched app did not appear in the selected Simulator's launchd domain."
        )
      }
      guard
        try controller.simulator.waitForLibraryMapping(
          libraryURL: artifact.libraryURL,
          processIdentifier: appProcessIdentifier
        )
      else {
        throw SimUseNetworkError.verificationFailed(
          "The shim was not loaded in \(bundleIdentifier) (pid \(appProcessIdentifier))."
        )
      }
      guard
        try controller.simulator.waitForNotifyState(
          1,
          name: record.appShimReadyName,
          deviceUDID: device.udid
        )
      else {
        throw SimUseNetworkError.verificationFailed(
          "The app loaded the shim but did not acknowledge healthy state registration."
        )
      }

      record.phase = .ready
      record.daemonProcessIdentifier = daemonProcessIdentifier
      record.appProcessIdentifier = appProcessIdentifier
      let finalIntegrity = try controller.processMappingStatus(record)
      try controller.validateIntegrity(finalIntegrity, record: record)
      try controller.store.save(record)
      return Self.status(
        from: record,
        appShimLoaded: true,
        daemonShimLoaded: true,
        keeperRunning: true,
        notifyDaemonStable: true
      )
    } catch {
      let preparationError = error
      record.phase = .recovering
      try? controller.store.save(record)
      do {
        try controller.recover(record)
        try controller.store.remove(deviceUDID: device.udid)
      } catch {
        throw SimUseNetworkError.invalidSession(
          "Preparation failed: \(preparationError.localizedDescription)\n"
            + "Automatic recovery also failed: \(error.localizedDescription)\n"
            + "Run sim-use-network cleanup --device \(device.udid)."
        )
      }
      throw preparationError
    }
  }

  package func setAvailability(
    _ availability: NetworkAvailability,
    deviceIdentifier: String?
  ) throws -> SessionStatus {
    let device = try devices.resolve(explicitIdentifier: deviceIdentifier)
    let lock = try store.acquireLock(deviceUDID: device.udid)
    defer { withExtendedLifetime(lock) {} }
    let controller = inheritingLease(from: lock)
    var record = try controller.requiredRecord(for: device)
    guard record.phase == .ready else {
      throw SimUseNetworkError.invalidSession(
        "Session for \(device.udid) is in \(record.phase.rawValue). Run cleanup."
      )
    }

    let liveAvailability = try controller.simulator.readAvailability(
      stateName: record.stateName,
      deviceUDID: device.udid
    )
    record.availability = liveAvailability
    try controller.store.save(record)
    let mapping = try controller.processMappingStatus(
      record,
      requireShimAcknowledgement: false
    )
    try controller.validateIntegrity(mapping, record: record)

    try controller.simulator.setNotifyState(
      0,
      name: record.appShimReadyName,
      deviceUDID: device.udid
    )
    try controller.simulator.setNotifyState(
      0,
      name: record.daemonShimReadyName,
      deviceUDID: device.udid
    )
    try controller.simulator.setAvailability(
      availability,
      stateName: record.stateName,
      deviceUDID: device.udid
    )
    let verifiedMapping = try controller.processMappingStatus(
      record,
      expectedAvailability: availability
    )
    try controller.validateIntegrity(verifiedMapping, record: record)
    try controller.simulator.postNetworkChange(deviceUDID: device.udid)
    let finalMapping = try controller.processMappingStatus(
      record,
      expectedAvailability: availability
    )
    try controller.validateIntegrity(finalMapping, record: record)
    record.availability = availability
    try controller.store.save(record)
    return Self.status(
      from: record,
      appShimLoaded: finalMapping.app,
      daemonShimLoaded: finalMapping.daemon,
      keeperRunning: finalMapping.keeper,
      notifyDaemonStable: finalMapping.notifyDaemon
    )
  }

  package func status(deviceIdentifier: String?) throws -> SessionStatus {
    let device = try devices.resolve(explicitIdentifier: deviceIdentifier)
    let lock = try store.acquireLock(deviceUDID: device.udid)
    defer { withExtendedLifetime(lock) {} }
    let controller = inheritingLease(from: lock)
    var record = try controller.requiredRecord(for: device)
    let liveAvailability = try controller.simulator.readAvailability(
      stateName: record.stateName,
      deviceUDID: device.udid
    )
    let mapping = try controller.processMappingStatus(
      record,
      expectedAvailability: liveAvailability
    )
    record.availability = liveAvailability
    return Self.status(
      from: record,
      appShimLoaded: mapping.app,
      daemonShimLoaded: mapping.daemon,
      keeperRunning: mapping.keeper,
      notifyDaemonStable: mapping.notifyDaemon
    )
  }

  package func cleanup(deviceIdentifier: String?) throws -> CleanupReport {
    let device = try devices.resolve(explicitIdentifier: deviceIdentifier)
    let lock = try store.acquireLock(deviceUDID: device.udid)
    defer { withExtendedLifetime(lock) {} }
    let controller = inheritingLease(from: lock)
    guard var record = try controller.store.load(deviceUDID: device.udid) else {
      try controller.store.remove(deviceUDID: device.udid)
      return CleanupReport(
        deviceUDID: device.udid,
        deviceName: device.name,
        warnings: ["No session journal was present; the device was already clean."]
      )
    }
    guard record.device.runtime.identifier == device.runtime.identifier,
      record.device.runtime.buildVersion == device.runtime.buildVersion
    else {
      throw SimUseNetworkError.invalidSession(
        "The Simulator runtime changed after prepare. Run cleanup with the original runtime."
      )
    }

    var warnings: [String] = []
    do {
      try controller.simulator.setAvailability(
        .available,
        stateName: record.stateName,
        deviceUDID: device.udid
      )
    } catch {
      warnings.append("Could not set available before unload: \(error.localizedDescription)")
    }

    let appStopped: Bool
    if record.ownsAppLaunch {
      do {
        appStopped = try controller.simulator.terminateInjectedApp(record)
      } catch {
        warnings.append("Injected app termination failed: \(error.localizedDescription)")
        appStopped = false
      }
    } else {
      appStopped = true
    }

    let restartCount: Int
    switch record.phase {
    case .daemonInjected, .appLaunching, .ready:
      restartCount = 1
    case .daemonDebugArmed, .recovering:
      restartCount = 2
    case .staged, .keeperStarting, .keeperRunning:
      restartCount = 0
    }
    var daemonProcessIdentifier: Int32?
    for _ in 0..<restartCount {
      do {
        daemonProcessIdentifier = try controller.simulator.restartDaemon(
          deviceUDID: device.udid,
          serviceTarget: record.daemonServiceTarget
        )
      } catch {
        warnings.append("Daemon clean restart failed: \(error.localizedDescription)")
      }
    }

    var daemonClean = restartCount == 0
    if let daemonProcessIdentifier {
      do {
        daemonClean = try !controller.simulator.isLibraryMapped(
          libraryURL: URL(filePath: record.shimPath),
          processIdentifier: daemonProcessIdentifier
        )
        if !daemonClean {
          warnings.append("The shim is still loaded after restarting nsurlsessiond.")
        }
      } catch {
        warnings.append("Could not verify the clean daemon mapping: \(error.localizedDescription)")
      }
    }

    var keeperStopped = false
    if appStopped, daemonClean {
      do {
        try controller.simulator.stopStateKeeper(record)
        keeperStopped = true
      } catch {
        warnings.append("State keeper bootout failed: \(error.localizedDescription)")
      }
    } else {
      warnings.append(
        "State keeper was preserved because an injected app or daemon may still be running."
      )
    }

    guard appStopped, daemonClean, keeperStopped else {
      record.phase = .recovering
      record.availability = .available
      try? controller.store.save(record)
      throw SimUseNetworkError.invalidSession(
        "Cleanup did not remove every retaining resource.\n"
          + warnings.joined(separator: "\n")
      )
    }

    do {
      try controller.store.remove(deviceUDID: device.udid)
    } catch {
      record.phase = .recovering
      record.availability = .available
      try? controller.store.save(record)
      throw error
    }
    return CleanupReport(
      deviceUDID: device.udid,
      deviceName: device.name,
      warnings: warnings
    )
  }

  package func bootedDevices() throws -> [SimulatorDevice] {
    try devices.loadDevices().filter { $0.isAvailable && $0.isBooted }
  }

  package func doctor(deviceIdentifier: String?) throws -> DoctorReport {
    let device = try devices.resolve(explicitIdentifier: deviceIdentifier)
    let serviceTarget = try simulator.resolveDaemonServiceTarget(
      deviceUDID: device.udid,
      platform: device.runtime.platform
    )
    try simulator.verifyNotifyUtility(deviceUDID: device.udid)
    let runtimeIdentity = try compatibility.identity(
      runtime: device.runtime,
      daemonServiceTarget: serviceTarget
    )
    return DoctorReport(
      deviceUDID: device.udid,
      deviceName: device.name,
      platform: device.runtime.platform.displayName,
      runtimeVersion: device.runtime.version,
      runtimeBuild: device.runtime.buildVersion,
      supportedArchitectures: device.runtime.supportedArchitectures,
      daemonServiceTarget: serviceTarget,
      notifyUtilityAvailable: true,
      runtimeIdentity: runtimeIdentity,
      platformSupport: device.runtime.platform.support
    )
  }

  private func requiredRecord(for device: SimulatorDevice) throws -> SessionRecord {
    guard let record = try store.load(deviceUDID: device.udid) else {
      throw SimUseNetworkError.sessionNotFound(device.udid)
    }
    guard record.device.runtime.identifier == device.runtime.identifier,
      record.device.runtime.buildVersion == device.runtime.buildVersion
    else {
      throw SimUseNetworkError.invalidSession(
        "The Simulator runtime changed after prepare. Run cleanup before continuing."
      )
    }
    return record
  }

  private func processMappingStatus(
    _ record: SessionRecord,
    expectedAvailability: NetworkAvailability? = nil,
    requireShimAcknowledgement: Bool = true
  ) throws -> SessionIntegrity {
    let libraryURL = URL(filePath: record.shimPath)
    let app =
      try simulator.isAppProcessCurrent(record)
      && (record.appProcessIdentifier.map {
        try simulator.isLibraryMapped(libraryURL: libraryURL, processIdentifier: $0)
      } ?? false)
    let daemon =
      try record.daemonProcessIdentifier.map {
        try simulator.isLibraryMapped(libraryURL: libraryURL, processIdentifier: $0)
      } ?? false
    try simulator.verifyStateKeeper(record)
    if requireShimAcknowledgement {
      let expectedShimState: UInt64 =
        (expectedAvailability ?? record.availability) == .available
        ? 1
        : 2
      guard
        try simulator.waitForNotifyState(
          expectedShimState,
          name: record.appShimReadyName,
          deviceUDID: record.device.udid
        ),
        try simulator.waitForNotifyState(
          expectedShimState,
          name: record.daemonShimReadyName,
          deviceUDID: record.device.udid
        )
      else {
        throw SimUseNetworkError.invalidSession(
          "The app or daemon shim did not acknowledge the live network state. Run cleanup."
        )
      }
    }
    let liveKeeperProcessIdentifier = try simulator.stateKeeperProcessIdentifierIfRunning(record)
    let keeper = liveKeeperProcessIdentifier == record.keeperProcessIdentifier
    let notifyDaemon =
      try simulator.notifyDaemonIdentity(
        deviceUDID: record.device.udid
      )
      == LaunchdServiceIdentity(
        processIdentifier: record.notifyDaemonProcessIdentifier,
        runCount: record.notifyDaemonRunCount
      )
    return SessionIntegrity(
      app: app,
      daemon: daemon,
      keeper: keeper,
      notifyDaemon: notifyDaemon
    )
  }

  private func validateIntegrity(
    _ integrity: SessionIntegrity,
    record: SessionRecord
  ) throws {
    guard integrity.app, integrity.daemon, integrity.keeper, integrity.notifyDaemon else {
      throw SimUseNetworkError.invalidSession(
        "The prepared app, daemon, state keeper, or notifyd identity is no longer intact. Run cleanup."
      )
    }
    let currentDaemon = try simulator.daemonIdentity(
      deviceUDID: record.device.udid,
      serviceTarget: record.daemonServiceTarget
    )
    guard let expectedDaemonProcessIdentifier = record.daemonProcessIdentifier,
      let expectedDaemonRunCount = record.daemonRunCount,
      currentDaemon
        == LaunchdServiceIdentity(
          processIdentifier: expectedDaemonProcessIdentifier,
          runCount: expectedDaemonRunCount
        )
    else {
      throw SimUseNetworkError.invalidSession(
        "nsurlsessiond restarted after prepare. Run cleanup before changing availability."
      )
    }
  }

  private func recover(_ record: SessionRecord) throws {
    var failures: [String] = []
    do {
      try simulator.setAvailability(
        .available,
        stateName: record.stateName,
        deviceUDID: record.device.udid
      )
    } catch {
      failures.append("Could not set available: \(error.localizedDescription)")
    }

    let appStopped: Bool
    if record.ownsAppLaunch {
      do {
        appStopped = try simulator.terminateInjectedApp(record)
      } catch {
        failures.append("Injected app termination failed: \(error.localizedDescription)")
        appStopped = false
      }
    } else {
      appStopped = true
    }

    var cleanProcessIdentifier: Int32?
    for _ in 0..<2 {
      do {
        cleanProcessIdentifier = try simulator.restartDaemon(
          deviceUDID: record.device.udid,
          serviceTarget: record.daemonServiceTarget
        )
      } catch {
        failures.append("Daemon restart failed: \(error.localizedDescription)")
      }
    }
    let daemonClean: Bool
    if let cleanProcessIdentifier {
      do {
        daemonClean = try !simulator.isLibraryMapped(
          libraryURL: URL(filePath: record.shimPath),
          processIdentifier: cleanProcessIdentifier
        )
      } catch {
        failures.append("Daemon mapping verification failed: \(error.localizedDescription)")
        daemonClean = false
      }
    } else {
      daemonClean = false
    }

    var keeperStopped = false
    if appStopped, daemonClean {
      do {
        try simulator.stopStateKeeper(record)
        keeperStopped = true
      } catch {
        failures.append("State keeper bootout failed: \(error.localizedDescription)")
      }
    }

    guard appStopped, daemonClean, keeperStopped else {
      throw SimUseNetworkError.invalidSession(
        "Automatic recovery did not remove every retaining resource.\n"
          + failures.joined(separator: "\n")
      )
    }
  }

  private static func validateBundleIdentifier(_ value: String) throws {
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    guard !value.isEmpty,
      value.rangeOfCharacter(from: allowed.inverted) == nil,
      !value.hasPrefix("."),
      !value.hasSuffix(".")
    else {
      throw SimUseNetworkError.invalidInput("Invalid app bundle identifier: \(value)")
    }
  }

  private static func status(
    from record: SessionRecord,
    appShimLoaded: Bool,
    daemonShimLoaded: Bool,
    keeperRunning: Bool,
    notifyDaemonStable: Bool
  ) -> SessionStatus {
    SessionStatus(
      deviceUDID: record.device.udid,
      deviceName: record.device.name,
      platform: record.device.runtime.platform.displayName,
      runtimeVersion: record.device.runtime.version,
      runtimeBuild: record.device.runtime.buildVersion,
      bundleIdentifier: record.bundleIdentifier,
      phase: record.phase,
      availability: record.availability,
      appProcessIdentifier: record.appProcessIdentifier,
      daemonProcessIdentifier: record.daemonProcessIdentifier,
      daemonRunCount: record.daemonRunCount,
      keeperProcessIdentifier: record.keeperProcessIdentifier,
      notifyDaemonProcessIdentifier: record.notifyDaemonProcessIdentifier,
      notifyDaemonRunCount: record.notifyDaemonRunCount,
      appShimLoaded: appShimLoaded,
      daemonShimLoaded: daemonShimLoaded,
      keeperRunning: keeperRunning,
      notifyDaemonStable: notifyDaemonStable
    )
  }
}

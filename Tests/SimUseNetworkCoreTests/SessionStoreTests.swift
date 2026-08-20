// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import SimUseNetworkCore

@Suite
struct SessionStoreTests {
  @Test
  func recordRoundTripsAtomically() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "sim-use-network-session-store-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SessionStore(rootDirectory: root)
    let record = makeRecord()

    try store.save(record)
    let loaded = try store.load(deviceUDID: record.device.udid)

    #expect(loaded == record)
    let recordURL = store.sessionDirectory(deviceUDID: record.device.udid)
      .appending(path: "session.json")
    let attributes = try FileManager.default.attributesOfItem(atPath: recordURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test
  func removingUnknownSessionIsIdempotent() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "sim-use-network-session-store-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SessionStore(rootDirectory: root)

    try store.remove(deviceUDID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
  }

  private func makeRecord() -> SessionRecord {
    let runtime = SimulatorRuntime(
      identifier: "com.apple.CoreSimulator.SimRuntime.watchOS-27-0",
      platform: .watchOS,
      version: "27.0",
      buildVersion: "24R5325f",
      supportedArchitectures: ["arm64"],
      name: "watchOS 27.0"
    )
    let device = SimulatorDevice(
      udid: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
      name: "Test Watch",
      state: "Booted",
      isAvailable: true,
      runtime: runtime
    )
    return SessionRecord(
      sessionID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
      device: device,
      bundleIdentifier: "com.example.TestApp",
      daemonServiceTarget: "system/com.apple.nsurlsessiond",
      stateName: "io.github.lynnswap.sim-use-network.test",
      keeperReadyName: "io.github.lynnswap.sim-use-network.test.keeper-ready",
      appShimReadyName: "io.github.lynnswap.sim-use-network.test.app-ready",
      daemonShimReadyName: "io.github.lynnswap.sim-use-network.test.daemon-ready",
      shimPath: "/tmp/libSimUseNetworkShim.dylib",
      keeperServiceTarget: "system/io.github.lynnswap.sim-use-network.keeper.test",
      keeperPlistPath: "/tmp/state-keeper.plist",
      phase: .ready,
      availability: .unavailable,
      appProcessIdentifier: 100,
      ownsAppLaunch: true,
      daemonProcessIdentifier: 101,
      daemonRunCount: 4,
      keeperProcessIdentifier: 102,
      notifyDaemonProcessIdentifier: 103,
      notifyDaemonRunCount: 5,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }
}

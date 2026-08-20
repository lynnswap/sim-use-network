// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import SimUseNetworkCore

@Test
func stateKeeperPlistUsesGuestNotifyUtilityAndExactStateName() throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "sim-use-network-keeper-plist-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appending(path: "keeper.plist")

  try StateKeeperPlistWriter().write(
    label: "io.github.lynnswap.sim-use-network.keeper.test",
    stateName: "io.github.lynnswap.sim-use-network.state.test",
    readyName: "io.github.lynnswap.sim-use-network.state.test.keeper-ready",
    appShimReadyName: "io.github.lynnswap.sim-use-network.state.test.app-ready",
    daemonShimReadyName: "io.github.lynnswap.sim-use-network.state.test.daemon-ready",
    userName: "mobile",
    to: url
  )

  let payload = try #require(
    PropertyListSerialization.propertyList(
      from: Data(contentsOf: url),
      format: nil
    ) as? [String: Any]
  )
  #expect(payload["Label"] as? String == "io.github.lynnswap.sim-use-network.keeper.test")
  #expect(
    payload["ProgramArguments"] as? [String] == [
      "/usr/bin/notifyutil",
      "-q",
      "-R",
      "-w",
      "io.github.lynnswap.sim-use-network.state.test",
      "-w",
      "io.github.lynnswap.sim-use-network.state.test.app-ready",
      "-w",
      "io.github.lynnswap.sim-use-network.state.test.daemon-ready",
      "-w",
      "io.github.lynnswap.sim-use-network.state.test.keeper-ready",
    ])
  #expect(payload["RunAtLoad"] == nil)
  #expect(payload["KeepAlive"] as? Bool == true)
  #expect(payload["UserName"] as? String == "mobile")
}

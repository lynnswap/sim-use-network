// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import SimUseNetworkCore

@Suite
struct SimulatorControllerTests {
  @Test
  func resolvesCanonicalDaemonTargetFromLaunchctlOutput() throws {
    let processes = ProcessClient { _, arguments, _ in
      #expect(arguments.suffix(2) == ["print", "user/foreground/com.apple.nsurlsessiond"])
      return ProcessResult(
        status: 0,
        standardOutput: "user/501/com.apple.nsurlsessiond = {\n\tpid = 42\n}",
        standardError: ""
      )
    }
    let controller = SimulatorController(processes: processes)

    let target = try controller.resolveDaemonServiceTarget(
      deviceUDID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
      platform: .iOS
    )

    #expect(target == "user/501/com.apple.nsurlsessiond")
  }

  @Test
  func readsExactDarwinAvailabilityValues() throws {
    let processes = ProcessClient { _, _, _ in
      ProcessResult(
        status: 0,
        standardOutput: "io.github.lynnswap.sim-use-network.test 1",
        standardError: ""
      )
    }
    let controller = SimulatorController(processes: processes)

    let availability = try controller.readAvailability(
      stateName: "io.github.lynnswap.sim-use-network.test",
      deviceUDID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    )

    #expect(availability == .unavailable)
  }

  @Test
  func rejectsUnknownDarwinAvailabilityValue() throws {
    let processes = ProcessClient { _, _, _ in
      ProcessResult(
        status: 0,
        standardOutput: "io.github.lynnswap.sim-use-network.test 8",
        standardError: ""
      )
    }
    let controller = SimulatorController(processes: processes)

    #expect(throws: SimUseNetworkError.self) {
      _ = try controller.readAvailability(
        stateName: "io.github.lynnswap.sim-use-network.test",
        deviceUDID: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
      )
    }
  }
}

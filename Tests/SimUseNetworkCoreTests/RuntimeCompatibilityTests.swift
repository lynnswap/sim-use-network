// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import SimUseNetworkCore

@Suite
struct RuntimeCompatibilityTests {
  @Test
  func identityIncludesFullToolchainAndRuntimeIdentity() throws {
    let compatibility = makeCompatibility(architecture: "arm64")
    let runtime = makeRuntime()

    let identity = try compatibility.identity(
      runtime: runtime,
      daemonServiceTarget: "system/com.apple.nsurlsessiond"
    )
    #expect(
      identity
        == RuntimeValidationIdentity(
          platform: "watchOS",
          runtimeVersion: "27.0",
          runtimeBuild: "24R5325f",
          architecture: "arm64",
          xcodeBuild: "17F109",
          coreSimulatorBuild: "1171.2",
          daemonDomain: "system",
          shimABIVersion: 2
        ))
    #expect(
      try compatibility.isValidated(
        runtime: runtime,
        daemonServiceTarget: "system/com.apple.nsurlsessiond"
      ))
  }

  @Test
  func unmeasuredArchitectureIsNotValidated() throws {
    let compatibility = makeCompatibility(architecture: "x86_64")
    let runtime = makeRuntime()

    #expect(
      try !compatibility.isValidated(
        runtime: runtime,
        daemonServiceTarget: "system/com.apple.nsurlsessiond"
      ))
  }

  private func makeCompatibility(architecture: String) -> RuntimeCompatibility {
    RuntimeCompatibility(
      processes: ProcessClient { executable, arguments, _ in
        switch executable.path {
        case "/usr/bin/uname":
          return ProcessResult(status: 0, standardOutput: architecture, standardError: "")
        case "/usr/bin/xcodebuild":
          return ProcessResult(
            status: 0,
            standardOutput: "Xcode 26.6\nBuild version 17F109",
            standardError: ""
          )
        case "/usr/bin/xcrun" where arguments == ["simctl", "--version"]:
          return ProcessResult(
            status: 0,
            standardOutput: "@(#)PROGRAM:simctl  PROJECT:CoreSimulator-1171.2",
            standardError: ""
          )
        default:
          return ProcessResult(status: 1, standardOutput: "", standardError: "unexpected command")
        }
      })
  }

  private func makeRuntime() -> SimulatorRuntime {
    SimulatorRuntime(
      identifier: "com.apple.CoreSimulator.SimRuntime.watchOS-27-0",
      platform: .watchOS,
      version: "27.0",
      buildVersion: "24R5325f",
      supportedArchitectures: ["arm64"],
      name: "watchOS 27.0"
    )
  }
}

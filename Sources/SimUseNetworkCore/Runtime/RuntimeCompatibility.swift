// SPDX-License-Identifier: Apache-2.0

import Foundation

package struct RuntimeIdentity: Codable, Equatable {
  package let platform: String
  package let runtimeVersion: String
  package let runtimeBuild: String
  package let architecture: String
  package let xcodeBuild: String
  package let coreSimulatorBuild: String
  package let daemonDomain: String
  package let shimABIVersion: UInt32
}

package struct RuntimeCompatibility {
  package static let shimABIVersion: UInt32 = 2

  private let processes: ProcessClient

  package init(processes: ProcessClient = .live) {
    self.processes = processes
  }

  package func inheritingLease(from lock: DeviceLock) -> RuntimeCompatibility {
    RuntimeCompatibility(processes: processes.inheritingLease(from: lock))
  }

  package func identity(
    runtime: SimulatorRuntime,
    daemonServiceTarget: String
  ) throws -> RuntimeIdentity {
    let architecture = try processes.checked(
      URL(filePath: "/usr/bin/uname"),
      ["-m"]
    ).standardOutput
    let xcodeOutput = try processes.checked(
      URL(filePath: "/usr/bin/xcodebuild"),
      ["-version"]
    ).standardOutput
    guard
      let xcodeBuild =
        xcodeOutput
        .split(separator: "\n")
        .first(where: { $0.hasPrefix("Build version ") })?
        .split(separator: " ")
        .last
        .map(String.init)
    else {
      throw SimUseNetworkError.verificationFailed(
        "xcodebuild did not report its build version."
      )
    }

    let simctlOutput = try processes.checked(
      URL(filePath: "/usr/bin/xcrun"),
      ["simctl", "--version"]
    ).standardOutput
    guard let marker = simctlOutput.range(of: "CoreSimulator-") else {
      throw SimUseNetworkError.verificationFailed(
        "simctl did not report its CoreSimulator build."
      )
    }
    let coreSimulatorBuild = String(simctlOutput[marker.upperBound...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !coreSimulatorBuild.isEmpty else {
      throw SimUseNetworkError.verificationFailed(
        "simctl reported an empty CoreSimulator build."
      )
    }

    guard let daemonDomain = daemonServiceTarget.split(separator: "/").first,
      daemonDomain == "user" || daemonDomain == "system"
    else {
      throw SimUseNetworkError.verificationFailed(
        "Unsupported nsurlsessiond launchd domain: \(daemonServiceTarget)."
      )
    }
    return RuntimeIdentity(
      platform: runtime.platform.displayName,
      runtimeVersion: runtime.version,
      runtimeBuild: runtime.buildVersion,
      architecture: architecture,
      xcodeBuild: xcodeBuild,
      coreSimulatorBuild: coreSimulatorBuild,
      daemonDomain: String(daemonDomain),
      shimABIVersion: Self.shimABIVersion
    )
  }
}

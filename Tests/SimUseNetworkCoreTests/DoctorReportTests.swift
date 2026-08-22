// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import SimUseNetworkCore

@Test
func doctorReportEncodesSupportAndDiagnosticIdentity() throws {
  let report = DoctorReport(
    deviceUDID: "DEVICE",
    deviceName: "Test Simulator",
    platform: "visionOS",
    runtimeVersion: "27.0",
    runtimeBuild: "TEST",
    supportedArchitectures: ["arm64"],
    daemonServiceTarget: "user/501/com.apple.nsurlsessiond",
    notifyUtilityAvailable: true,
    runtimeIdentity: RuntimeIdentity(
      platform: "visionOS",
      runtimeVersion: "27.0",
      runtimeBuild: "TEST",
      architecture: "arm64",
      xcodeBuild: "XCODE",
      coreSimulatorBuild: "CORE_SIMULATOR",
      daemonDomain: "user",
      shimABIVersion: 2
    ),
    platformSupport: .experimental
  )

  let object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
  )
  #expect(object["platformSupport"] as? String == "experimental")
  let identity = try #require(object["runtimeIdentity"] as? [String: Any])
  #expect(identity["xcodeBuild"] as? String == "XCODE")
  #expect(object["runtimeValidated"] == nil)
}

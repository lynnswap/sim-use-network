// SPDX-License-Identifier: Apache-2.0

import Foundation

package enum SimulatorPlatform: String, Codable, CaseIterable {
  case iOS
  case watchOS
  case tvOS
  case visionOS = "xrOS"

  package var displayName: String {
    switch self {
    case .visionOS: "visionOS"
    default: rawValue
    }
  }

  package var sdkName: String {
    switch self {
    case .iOS: "iphonesimulator"
    case .watchOS: "watchsimulator"
    case .tvOS: "appletvsimulator"
    case .visionOS: "xrsimulator"
    }
  }

  package var targetOS: String {
    switch self {
    case .iOS: "ios"
    case .watchOS: "watchos"
    case .tvOS: "tvos"
    case .visionOS: "xros"
    }
  }

  package var machOPlatformName: String {
    switch self {
    case .iOS: "IOSSIMULATOR"
    case .watchOS: "WATCHOSSIMULATOR"
    case .tvOS: "TVOSSIMULATOR"
    case .visionOS: "VISIONOSSIMULATOR"
    }
  }

  package var daemonServiceCandidates: [String] {
    switch self {
    case .watchOS:
      ["system/com.apple.nsurlsessiond"]
    case .iOS, .tvOS, .visionOS:
      [
        "user/foreground/com.apple.nsurlsessiond",
        "system/com.apple.nsurlsessiond",
      ]
    }
  }
}

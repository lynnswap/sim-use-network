// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import SimUseNetworkCore

@Suite
struct SimulatorPlatformTests {
  @Test
  func iosAndWatchOSAreSupportedWithoutAnOptIn() {
    for platform in [SimulatorPlatform.iOS, .watchOS] {
      #expect(platform.support == .supported)
      #expect(platform.support.permitsPreparation(experimentalOptIn: false))
    }
  }

  @Test
  func tvOSAndVisionOSRequireAnExperimentalOptIn() {
    for platform in [SimulatorPlatform.tvOS, .visionOS] {
      #expect(platform.support == .experimental)
      #expect(!platform.support.permitsPreparation(experimentalOptIn: false))
      #expect(platform.support.permitsPreparation(experimentalOptIn: true))
    }
  }
}

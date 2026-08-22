// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import SimUseNetworkCLI

@Suite
struct CommandVersionTests {
  @Test
  func commandUsesGeneratedBuildVersion() {
    #expect(SimUseNetwork.configuration.version == SimUseNetworkBuildInfo.version)
  }
}

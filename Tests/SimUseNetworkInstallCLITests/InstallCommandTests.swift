// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import SimUseNetworkInstallCLI

@Suite
struct InstallCommandTests {
  @Test
  func helpDocumentsTheOneCommandSourceInstall() {
    let help = SimUseNetworkInstall.helpMessage(columns: 100)

    #expect(help.contains("swift run -c release sim-use-network-install"))
    #expect(help.contains("--prefix"))
    #expect(!help.contains("--migrate-legacy-install"))
    #expect(!help.contains(".build/release/sim-use-network-install"))
  }

  @Test
  func commandUsesGeneratedBuildVersion() {
    #expect(SimUseNetworkInstall.configuration.version == SimUseNetworkBuildInfo.version)
  }
}

// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import SimUseNetworkBuildInfoTool

@Suite
struct BuildInfoVersionResolverTests {
  @Test
  func explicitVersionIsNormalized() throws {
    let version = try BuildInfoVersionResolver.resolve(
      environmentVersion: "  v0.1.0  "
    )

    #expect(version == "0.1.0")
  }

  @Test
  func missingBuildIdentityUsesDevelopmentFallback() throws {
    let version = try BuildInfoVersionResolver.resolve(environmentVersion: nil)

    #expect(version == "dev")
  }

  @Test
  func explicitEmptyEnvironmentVersionFails() {
    #expect(throws: BuildInfoToolError.self) {
      try BuildInfoVersionResolver.resolve(
        environmentVersion: " \n "
      )
    }
  }

  @Test
  func generatedSourceEscapesTheVersionAsASwiftLiteral() {
    let version = "v0.1.0-\"quoted\"\\line\nnext"
    let source = BuildInfoVersionResolver.generatedSource(version: version)

    #expect(source.contains("static let version = \(String(reflecting: version))"))
    #expect(source.hasSuffix("\n"))
  }
}

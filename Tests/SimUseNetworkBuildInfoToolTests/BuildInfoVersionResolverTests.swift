// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import SimUseNetworkBuildInfoTool

@Suite
struct BuildInfoVersionResolverTests {
  private let packageDirectory = URL(filePath: "/package", directoryHint: .isDirectory)

  @Test
  func environmentVersionOverridesGitDescribe() throws {
    var queriedGit = false

    let version = try BuildInfoVersionResolver.resolve(
      environmentVersion: "  v0.1.0  ",
      packageDirectory: packageDirectory,
      gitDescribe: { _ in
        queriedGit = true
        return "ignored"
      }
    )

    #expect(version == "0.1.0")
    #expect(!queriedGit)
  }

  @Test
  func gitDescribeOwnsSourceCheckoutVersion() throws {
    let version = try BuildInfoVersionResolver.resolve(
      environmentVersion: nil,
      packageDirectory: packageDirectory,
      gitDescribe: { directory in
        #expect(directory == packageDirectory)
        return "v0.1.0-3-gabc123-dirty\n"
      }
    )

    #expect(version == "0.1.0-3-gabc123-dirty")
  }

  @Test
  func missingBuildIdentityUsesDevelopmentFallback() throws {
    let missingVersion = try BuildInfoVersionResolver.resolve(
      environmentVersion: nil,
      packageDirectory: packageDirectory,
      gitDescribe: { _ in nil }
    )
    let failedGit = try BuildInfoVersionResolver.resolve(
      environmentVersion: nil,
      packageDirectory: packageDirectory,
      gitDescribe: { _ in throw CocoaError(.fileNoSuchFile) }
    )

    #expect(missingVersion == "dev")
    #expect(failedGit == "dev")
  }

  @Test
  func explicitEmptyEnvironmentVersionFails() {
    #expect(throws: BuildInfoToolError.self) {
      try BuildInfoVersionResolver.resolve(
        environmentVersion: " \n ",
        packageDirectory: packageDirectory,
        gitDescribe: { _ in "must-not-be-used" }
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

// SPDX-License-Identifier: Apache-2.0

import Foundation
import PackagePlugin

@main
struct SimUseNetworkBuildInfoPlugin: BuildToolPlugin {
  private static let environmentKey = "SIM_USE_NETWORK_BUILD_VERSION"

  func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
    guard target is SourceModuleTarget else { return [] }

    let outputFile = context.pluginWorkDirectoryURL.appending(
      path: target.name,
      directoryHint: .isDirectory
    ).appending(path: "BuildInfo.generated.swift")
    let tool = try context.tool(named: "SimUseNetworkBuildInfoTool")
    var arguments = [
      "--output", outputFile.path,
      "--package-directory", context.package.directoryURL.path,
    ]
    if let environmentVersion = ProcessInfo.processInfo.environment[Self.environmentKey] {
      arguments.append(contentsOf: ["--environment-version", environmentVersion])
    }

    return [
      .buildCommand(
        displayName: "Generate build info for \(target.name)",
        executable: tool.url,
        arguments: arguments,
        outputFiles: [outputFile]
      )
    ]
  }
}

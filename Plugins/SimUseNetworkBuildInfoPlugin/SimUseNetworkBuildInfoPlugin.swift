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
    let environmentVersion = ProcessInfo.processInfo.environment[Self.environmentKey]
    if let environmentVersion {
      arguments.append(contentsOf: ["--environment-version", environmentVersion])
    }

    return [
      .buildCommand(
        displayName: "Generate build info for \(target.name)",
        executable: tool.url,
        arguments: arguments,
        inputFiles: environmentVersion == nil
          ? Self.gitInputFiles(in: context.package.directoryURL)
          : [],
        outputFiles: [outputFile]
      )
    ]
  }

  private static func gitInputFiles(in packageDirectory: URL) -> [URL] {
    guard
      let trackedOutput = gitOutput(
        arguments: ["ls-files", "-z"],
        in: packageDirectory
      )
    else {
      return []
    }

    var inputs = trackedOutput.split(separator: "\0").map {
      packageDirectory.appending(path: String($0))
    }
    let gitDirectory = gitOutput(
      arguments: ["rev-parse", "--absolute-git-dir"],
      in: packageDirectory
    ).flatMap(absoluteURL)
    let commonDirectory = gitOutput(
      arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"],
      in: packageDirectory
    ).flatMap(absoluteURL)

    if let gitDirectory {
      inputs.append(gitDirectory)
      inputs.append(gitDirectory.appending(path: "HEAD"))
      inputs.append(gitDirectory.appending(path: "index"))
    }
    if let commonDirectory {
      inputs.append(commonDirectory)
      inputs.append(
        contentsOf: directoryTree(
          at: commonDirectory.appending(
            path: "refs",
            directoryHint: .isDirectory
          )
        )
      )
      let packedReferences = commonDirectory.appending(path: "packed-refs")
      if FileManager.default.fileExists(atPath: packedReferences.path) {
        inputs.append(packedReferences)
      }
    }
    let worktreePointer = packageDirectory.appending(path: ".git")
    if FileManager.default.fileExists(atPath: worktreePointer.path) {
      inputs.append(worktreePointer)
    }

    var seen = Set<String>()
    return inputs.filter { seen.insert($0.path).inserted }
  }

  private static func gitOutput(arguments: [String], in packageDirectory: URL) -> String? {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(filePath: "/usr/bin/git")
    process.arguments = ["-C", packageDirectory.path] + arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    process.environment = environment

    do {
      try process.run()
    } catch {
      return nil
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(
      decoding: output.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    )
  }

  private static func absoluteURL(_ output: String) -> URL? {
    let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard path.hasPrefix("/") else { return nil }
    return URL(filePath: path, directoryHint: .isDirectory)
  }

  private static func directoryTree(at root: URL) -> [URL] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    var inputs = [root]
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil
      )
    else {
      return inputs
    }
    for case let input as URL in enumerator {
      inputs.append(input)
    }
    return inputs
  }
}

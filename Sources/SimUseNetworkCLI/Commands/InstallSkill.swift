// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Darwin
import Foundation

enum AgentClient: String, CaseIterable, ExpressibleByArgument {
  case codex
  case claude
}

private struct SkillInstallationError: Error, LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

struct SkillOperationResult: Codable {
  let action: String
  let path: String?
  let content: String?
  let warnings: [String]
}

struct InstallSkill: NetworkExecutableCommand {
  private static let markerName = ".sim-use-network-skill"
  private static let markerContents = "sim-use-network-skill-v1\n"

  static let configuration = CommandConfiguration(
    commandName: "init",
    abstract: "Install the bundled sim-use-network agent skill."
  )

  @Option(name: .long, help: "Agent client: codex or claude.")
  var client: AgentClient?

  @Option(
    name: .long, help: "Skill parent directory. The sim-use-network folder is added below it.")
  var dest: String?

  @Flag(name: .customLong("print"), help: "Print the bundled SKILL.md without installing it.")
  var printSkill = false

  @Flag(name: .long, help: "Replace an existing sim-use-network skill directory.")
  var force = false

  @Flag(name: .long, help: "Remove the installed sim-use-network skill directory.")
  var uninstall = false

  @Flag(name: .customLong("json"), help: "Emit a stable JSON result envelope.")
  var jsonOutput = false

  mutating func validate() throws {
    if printSkill && (dest != nil || client != nil || force || uninstall) {
      throw ValidationError("--print cannot be combined with installation options.")
    }
    if dest != nil && client != nil {
      throw ValidationError("Pass either --dest or --client, not both.")
    }
    if force && uninstall {
      throw ValidationError("--force and --uninstall cannot be combined.")
    }
  }

  mutating func execute() throws -> SkillOperationResult {
    if printSkill {
      let sourceDirectory = try Self.skillSourceDirectory()
      let skill = try String(
        contentsOf: sourceDirectory.appending(path: "SKILL.md"),
        encoding: .utf8
      )
      return SkillOperationResult(action: "print", path: nil, content: skill, warnings: [])
    }

    let parentDirectory = try destinationParent()
    let targetDirectory = parentDirectory.appending(
      path: "sim-use-network",
      directoryHint: .isDirectory
    )
    let fileManager = FileManager.default

    if uninstall {
      guard fileManager.fileExists(atPath: targetDirectory.path) else {
        throw SkillInstallationError(
          message: "No sim-use-network skill exists at \(targetDirectory.path)."
        )
      }
      try Self.validateOwnedInstallation(at: targetDirectory)
      try fileManager.removeItem(at: targetDirectory)
      return SkillOperationResult(
        action: "uninstall",
        path: targetDirectory.path,
        content: nil,
        warnings: []
      )
    }

    let sourceDirectory = try Self.skillSourceDirectory()
    try fileManager.createDirectory(
      at: parentDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try Self.rejectOverlappingSource(sourceDirectory, targetDirectory: targetDirectory)
    let targetExists = fileManager.fileExists(atPath: targetDirectory.path)
    if targetExists {
      guard force else {
        throw SkillInstallationError(
          message: "A skill already exists at \(targetDirectory.path). Pass --force to replace it."
        )
      }
      try Self.validateOwnedInstallation(at: targetDirectory)
    }

    let operationID = UUID().uuidString
    let stagingDirectory = parentDirectory.appending(
      path: ".sim-use-network.installing.\(operationID)",
      directoryHint: .isDirectory
    )
    let backupDirectory = parentDirectory.appending(
      path: ".sim-use-network.backup.\(operationID)",
      directoryHint: .isDirectory
    )
    try fileManager.copyItem(at: sourceDirectory, to: stagingDirectory)
    do {
      if targetExists {
        try fileManager.moveItem(at: targetDirectory, to: backupDirectory)
      }
      do {
        try fileManager.moveItem(at: stagingDirectory, to: targetDirectory)
      } catch {
        if targetExists,
          fileManager.fileExists(atPath: backupDirectory.path),
          !fileManager.fileExists(atPath: targetDirectory.path)
        {
          try? fileManager.moveItem(at: backupDirectory, to: targetDirectory)
        }
        throw error
      }
    } catch {
      try? fileManager.removeItem(at: stagingDirectory)
      throw error
    }
    var warnings: [String] = []
    if fileManager.fileExists(atPath: backupDirectory.path) {
      do {
        try fileManager.removeItem(at: backupDirectory)
      } catch {
        warnings.append(
          "Installed the new skill, but could not remove backup at \(backupDirectory.path): "
            + error.localizedDescription
        )
      }
    }
    return SkillOperationResult(
      action: "install",
      path: targetDirectory.path,
      content: nil,
      warnings: warnings
    )
  }

  func format(_ result: SkillOperationResult) -> String {
    switch result.action {
    case "print":
      return (result.content ?? "").trimmingCharacters(in: .newlines)
    case "uninstall":
      return "Removed sim-use-network skill from \(result.path ?? "unknown path")."
    default:
      let summary = "Installed sim-use-network skill at \(result.path ?? "unknown path")."
      guard !result.warnings.isEmpty else { return summary }
      return summary + "\nWarnings:\n" + result.warnings.map { "- \($0)" }.joined(separator: "\n")
    }
  }

  private func destinationParent() throws -> URL {
    if let dest {
      return URL(filePath: NSString(string: dest).expandingTildeInPath, directoryHint: .isDirectory)
        .standardizedFileURL
    }
    if let client {
      return Self.defaultParent(for: client)
    }

    let candidates = AgentClient.allCases.map { ($0, Self.defaultParent(for: $0)) }
    let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.1.path) }
    guard existing.count == 1, let selected = existing.first else {
      throw SkillInstallationError(
        message:
          "Could not select one agent client. Pass --client codex, --client claude, or --dest."
      )
    }
    return selected.1
  }

  private static func defaultParent(for client: AgentClient) -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    switch client {
    case .codex:
      return home.appending(path: ".codex/skills", directoryHint: .isDirectory)
    case .claude:
      return home.appending(path: ".claude/skills", directoryHint: .isDirectory)
    }
  }

  private static func skillSourceDirectory() throws -> URL {
    guard
      let url = Bundle.module.resourceURL?
        .appending(path: "skills", directoryHint: .isDirectory)
        .appending(path: "sim-use-network", directoryHint: .isDirectory),
      FileManager.default.fileExists(atPath: url.appending(path: "SKILL.md").path)
    else {
      throw SkillInstallationError(message: "The bundled sim-use-network skill is missing.")
    }
    return url
  }

  private static func validateOwnedInstallation(at directory: URL) throws {
    var metadata = stat()
    guard lstat(directory.path, &metadata) == 0 else {
      throw SkillInstallationError(
        message: "Could not inspect installation at \(directory.path): errno \(errno)."
      )
    }
    guard metadata.st_mode & S_IFMT != S_IFLNK else {
      throw SkillInstallationError(
        message: "Refusing to replace symbolic-link installation at \(directory.path)."
      )
    }
    let marker = directory.appending(path: markerName)
    guard let contents = try? String(contentsOf: marker, encoding: .utf8),
      contents == markerContents
    else {
      throw SkillInstallationError(
        message: "Refusing to remove \(directory.path) because it is not owned by sim-use-network."
      )
    }
  }

  private static func rejectOverlappingSource(
    _ sourceDirectory: URL,
    targetDirectory: URL
  ) throws {
    var sourceToParent = FileManager.URLRelationship.other
    try FileManager.default.getRelationship(
      &sourceToParent,
      ofDirectoryAt: sourceDirectory,
      toItemAt: targetDirectory.deletingLastPathComponent()
    )
    guard sourceToParent != .same, sourceToParent != .contains else {
      throw SkillInstallationError(
        message: "Refusing to install the bundled skill inside its own source directory."
      )
    }

    guard FileManager.default.fileExists(atPath: targetDirectory.path) else { return }
    var relationship = FileManager.URLRelationship.other
    try FileManager.default.getRelationship(
      &relationship,
      ofDirectoryAt: targetDirectory,
      toItemAt: sourceDirectory
    )
    guard relationship != .same, relationship != .contains else {
      throw SkillInstallationError(
        message: "Refusing to install because the bundled skill is inside \(targetDirectory.path)."
      )
    }
  }
}

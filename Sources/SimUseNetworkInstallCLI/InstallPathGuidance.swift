// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

package struct InstallPathGuidance {
  private enum PathStatus: Equatable {
    case ready
    case missing
    case shadowed(URL)
  }

  private enum Profile {
    case available(URL)
    case existingEntry(URL)
    case unavailable
    case unknownShell
  }

  package let commandDirectory: URL
  package let environment: [String: String]
  package let fileManager: FileManager

  package init(
    commandDirectory: URL,
    environment: [String: String],
    fileManager: FileManager = .default
  ) {
    self.commandDirectory = commandDirectory
    self.environment = environment
    self.fileManager = fileManager
  }

  package func messages() -> [String] {
    let pathStatus = pathStatus()
    guard pathStatus != .ready else { return [] }

    let directoryPath = commandDirectory.standardizedFileURL.path
    guard !directoryPath.contains(":"), !directoryPath.contains(where: \.isNewline) else {
      return [
        "",
        "sim-use-network is installed, but its command directory cannot be represented safely in PATH.",
        "",
        "Next steps:",
        "  Reinstall to a path without ':' or newlines before adding it to PATH.",
      ]
    }

    let exportLine: String
    if let home = nonEmpty(environment["HOME"]),
      commandDirectory.standardizedFileURL
        == URL(fileURLWithPath: home, isDirectory: true)
        .appendingPathComponent(".local/bin", isDirectory: true).standardizedFileURL
    {
      exportLine = #"export PATH="$HOME/.local/bin:$PATH""#
    } else {
      exportLine = "export PATH=\(shellQuote(directoryPath)):\"$PATH\""
    }
    var lines = [""]
    switch pathStatus {
    case .ready:
      return []
    case .missing:
      lines.append("sim-use-network is installed, but its command directory is not on PATH.")
    case .shadowed(let command):
      lines.append("sim-use-network is installed, but \(command.path) appears first on PATH.")
    }
    lines.append("")
    lines.append("Next steps:")

    switch loginProfile(containing: exportLine) {
    case .existingEntry(let profileURL):
      lines.append("  \(profileURL.path) already contains the PATH entry.")
      lines.append("  Open a new terminal, or use sim-use-network in this shell:")
    case .available(let profileURL):
      let appendCommand =
        "printf '\\n%s\\n' \(shellQuote(exportLine)) >> \(shellQuote(profileURL.path))"
      lines.append("  Add sim-use-network to future shell sessions:")
      lines.append("    \(appendCommand)")
      lines.append("")
      lines.append("  Use sim-use-network in this shell:")
    case .unavailable:
      lines.append("  Add the command directory to your shell profile.")
      lines.append("")
      lines.append("  Use sim-use-network in this shell:")
    case .unknownShell:
      lines.append("  Add this directory to PATH using the syntax for your shell:")
      lines.append("    \(directoryPath)")
      lines.append("")
      lines.append("Installed command:")
      lines.append("  \(directoryPath)/sim-use-network")
      return lines
    }

    lines.append("    \(exportLine)")
    lines.append("")
    lines.append("Then run:")
    lines.append("  sim-use-network --help")
    return lines
  }

  private func pathStatus() -> PathStatus {
    guard let path = environment["PATH"] else { return .missing }
    let installedPath = canonicalPath(commandDirectory)
    for entry in path.split(separator: ":", omittingEmptySubsequences: false) {
      let url: URL
      if entry.isEmpty {
        url = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
      } else {
        url = URL(fileURLWithPath: String(entry), isDirectory: true)
      }
      if canonicalPath(url) == installedPath {
        return .ready
      }
      let candidate = url.appendingPathComponent("sim-use-network", isDirectory: false)
      if fileManager.isExecutableFile(atPath: candidate.path) {
        let installedCommand = commandDirectory.appendingPathComponent("sim-use-network")
        if canonicalPath(candidate) == canonicalPath(installedCommand) {
          return .ready
        }
        return .shadowed(candidate.standardizedFileURL)
      }
    }
    return .missing
  }

  private func loginProfile(containing exportLine: String) -> Profile {
    guard let shell = nonEmpty(environment["SHELL"]) else { return .unknownShell }
    let shellName = (shell as NSString).lastPathComponent
    guard shellName == "zsh" || shellName == "bash" else { return .unknownShell }
    guard let home = nonEmpty(environment["HOME"]) else { return .unavailable }

    let homeURL = URL(fileURLWithPath: home, isDirectory: true)
    let profileURL: URL
    switch shellName {
    case "zsh":
      let profileRoot =
        nonEmpty(environment["ZDOTDIR"])
        .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? homeURL
      profileURL = profileRoot.appendingPathComponent(".zprofile", isDirectory: false)
    case "bash":
      let candidates = [".bash_profile", ".bash_login", ".profile"].map {
        homeURL.appendingPathComponent($0, isDirectory: false)
      }
      profileURL = candidates.first(where: isReadableRegularFile) ?? candidates[0]
    default:
      return .unknownShell
    }

    if profileContains(exportLine, at: profileURL) {
      return .existingEntry(profileURL)
    }
    if isReadableRegularFile(profileURL) {
      return fileManager.isWritableFile(atPath: profileURL.path)
        ? .available(profileURL) : .unavailable
    }
    guard isAbsent(profileURL),
      isWritableDirectory(profileURL.deletingLastPathComponent())
    else {
      return .unavailable
    }
    return .available(profileURL)
  }

  private func canonicalPath(_ url: URL) -> String {
    let standardized = url.standardizedFileURL
    guard fileManager.fileExists(atPath: standardized.path) else {
      return standardized.path
    }
    return standardized.resolvingSymlinksInPath().standardizedFileURL.path
  }

  private func profileContains(_ line: String, at url: URL) -> Bool {
    guard let data = fileManager.contents(atPath: url.path),
      let contents = String(data: data, encoding: .utf8)
    else {
      return false
    }
    return contents.split(whereSeparator: \.isNewline).contains { $0 == line }
  }

  private func isReadableRegularFile(_ url: URL) -> Bool {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    guard let attributes = try? fileManager.attributesOfItem(atPath: resolved.path),
      attributes[.type] as? FileAttributeType == .typeRegular
    else {
      return false
    }
    return fileManager.isReadableFile(atPath: resolved.path)
  }

  private func isWritableDirectory(_ url: URL) -> Bool {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    guard let attributes = try? fileManager.attributesOfItem(atPath: resolved.path),
      attributes[.type] as? FileAttributeType == .typeDirectory
    else {
      return false
    }
    return fileManager.isWritableFile(atPath: resolved.path)
  }

  private func isAbsent(_ url: URL) -> Bool {
    var metadata = stat()
    let result = url.path.withCString { Darwin.lstat($0, &metadata) }
    return result != 0 && errno == ENOENT
  }

  private func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }
}

// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

package enum SourceInstallError: Error, LocalizedError {
  case message(String)

  package var errorDescription: String? {
    switch self {
    case .message(let message): message
    }
  }
}

package struct SourceInstaller {
  private static let ownershipMarkerName = ".sim-use-network-install"
  private static let ownershipMarkerContents = "format=1\n"
  private static let wrapperMarkerV1 = "# sim-use-network installer-managed wrapper v1"
  private static let currentWrapperMarker = wrapperMarkerV1
  private static let supportedWrapperMarkers = [wrapperMarkerV1]

  package struct Artifact: Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
      case executable
      case bundle(requiredPaths: [String])
    }

    package let name: String
    package let kind: Kind
  }

  package struct Layout: Equatable, Sendable {
    package let prefix: URL
    package let binDirectory: URL
    package let command: URL
    package let installRoot: URL
    package let payloadsDirectory: URL
  }

  package static let artifacts = [
    Artifact(name: "sim-use-network", kind: .executable),
    Artifact(
      name: "sim-use-network_SimUseNetworkCore.bundle",
      kind: .bundle(requiredPaths: ["RuntimeArtifacts/NetworkUnavailableShim.c"])
    ),
    Artifact(
      name: "sim-use-network_SimUseNetworkCLI.bundle",
      kind: .bundle(requiredPaths: [
        "skills/sim-use-network/SKILL.md",
        "skills/sim-use-network/.sim-use-network-skill",
      ])),
  ]

  private enum ItemKind {
    case regularFile
    case directory
    case symbolicLink
    case other
  }

  private let fileManager: FileManager
  private let process: InstallProcess
  private let makeIdentifier: () -> String

  package init(
    fileManager: FileManager = .default,
    process: InstallProcess = .live,
    makeIdentifier: @escaping () -> String = { UUID().uuidString.lowercased() }
  ) {
    self.fileManager = fileManager
    self.process = process
    self.makeIdentifier = makeIdentifier
  }

  package func install(
    installerExecutableURL: URL,
    prefix: String?,
    environment: [String: String]
  ) throws -> [String] {
    let repositoryRoot = try Self.repositoryRoot(
      from: installerExecutableURL,
      fileManager: fileManager
    )
    let layout = try Self.layout(
      prefix: prefix,
      environment: environment,
      currentDirectory: repositoryRoot
    )
    try validateExistingDestination(layout)

    try process.checked(
      URL(fileURLWithPath: "/usr/bin/env"),
      ["swift", "build", "-c", "release", "--product", "sim-use-network"],
      in: repositoryRoot,
      output: .inherit
    )
    let sourceDirectory = repositoryRoot.appendingPathComponent(
      ".build/release", isDirectory: true
    ).resolvingSymlinksInPath().standardizedFileURL
    guard try itemKind(at: sourceDirectory) == .directory else {
      throw SourceInstallError.message(
        "SwiftPM did not produce the release build directory at \(sourceDirectory.path)."
      )
    }
    return try publish(
      artifactsDirectory: sourceDirectory,
      layout: layout,
      environment: environment
    )
  }

  package func installPrebuilt(
    artifactsDirectory: URL,
    prefix: String?,
    environment: [String: String],
    currentDirectory: URL
  ) throws -> [String] {
    let sourceDirectory = artifactsDirectory.resolvingSymlinksInPath().standardizedFileURL
    guard try itemKind(at: sourceDirectory) == .directory else {
      throw SourceInstallError.message(
        "Could not find the prebuilt artifact directory at \(sourceDirectory.path)."
      )
    }
    let layout = try Self.layout(
      prefix: prefix,
      environment: environment,
      currentDirectory: currentDirectory
    )
    try validateExistingDestination(layout)
    return try publish(
      artifactsDirectory: sourceDirectory,
      layout: layout,
      environment: environment
    )
  }

  private func publish(
    artifactsDirectory: URL,
    layout: Layout,
    environment: [String: String]
  ) throws -> [String] {
    try validateArtifacts(in: artifactsDirectory)
    try prepareInstallDirectories(layout)
    let installLock = try SourceInstallLock(
      url: layout.installRoot.appendingPathComponent("install.lock", isDirectory: false)
    )
    defer { withExtendedLifetime(installLock) {} }
    try validateExistingDestination(layout)

    let identifier = makeIdentifier()
    guard !identifier.isEmpty,
      !identifier.contains("/"),
      !identifier.contains(where: \.isNewline)
    else {
      throw SourceInstallError.message("The installer generated an invalid payload identifier.")
    }

    let stagingPayload = layout.payloadsDirectory.appendingPathComponent(
      ".staging-\(identifier)", isDirectory: true)
    let finalPayload = layout.payloadsDirectory.appendingPathComponent(
      identifier, isDirectory: true)
    let temporaryCommand = layout.binDirectory.appendingPathComponent(
      ".sim-use-network-\(identifier)", isDirectory: false)

    for temporaryURL in [
      stagingPayload,
      finalPayload,
      temporaryCommand,
    ] where try itemKind(at: temporaryURL) != nil {
      throw SourceInstallError.message(
        "Refusing to reuse an existing installer transaction path: \(temporaryURL.path)"
      )
    }

    try fileManager.createDirectory(
      at: stagingPayload,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o755]
    )
    var finalPayloadPublished = false

    do {
      try copyArtifacts(from: artifactsDirectory, to: stagingPayload)
      try Data(Self.ownershipMarkerContents.utf8).write(
        to: stagingPayload.appendingPathComponent(Self.ownershipMarkerName)
      )
      try validateArtifacts(in: stagingPayload)
      try validateOwnershipMarker(in: stagingPayload)
      try process.checked(
        stagingPayload.appendingPathComponent("sim-use-network"),
        ["init", "--print"],
        output: .discard
      )

      let wrapper = try wrapperContents(payload: finalPayload)
      guard
        fileManager.createFile(
          atPath: temporaryCommand.path,
          contents: Data(wrapper.utf8),
          attributes: [.posixPermissions: 0o755]
        )
      else {
        throw SourceInstallError.message(
          "Could not create the command wrapper at \(temporaryCommand.path)."
        )
      }
      try process.checked(
        URL(fileURLWithPath: "/bin/sh"),
        ["-n", temporaryCommand.path],
        output: .discard
      )

      try fileManager.moveItem(at: stagingPayload, to: finalPayload)
      finalPayloadPublished = true

      try process.checked(
        temporaryCommand,
        ["init", "--print"],
        output: .discard
      )

      try atomicRename(temporaryCommand, to: layout.command)
    } catch {
      var cleanupFailures: [String] = []
      var transactionPaths = [stagingPayload, temporaryCommand]
      if finalPayloadPublished {
        transactionPaths.append(finalPayload)
      }
      for transactionPath in transactionPaths {
        do {
          if try itemKind(at: transactionPath) != nil {
            try fileManager.removeItem(at: transactionPath)
          }
        } catch {
          cleanupFailures.append(
            "Could not remove transaction item at \(transactionPath.path): \(error.localizedDescription)"
          )
        }
      }
      if !cleanupFailures.isEmpty {
        throw SourceInstallError.message(
          "Installation failed: \(error.localizedDescription)\nTransaction cleanup also failed:\n"
            + cleanupFailures.map { "- \($0)" }.joined(separator: "\n")
        )
      }
      throw error
    }

    var lines = [
      "Installed sim-use-network to \(layout.command.path)",
      "Installed runtime payload to \(finalPayload.path)",
    ]
    lines.append(
      contentsOf: InstallPathGuidance(
        commandDirectory: layout.binDirectory,
        environment: environment,
        fileManager: fileManager
      ).messages())
    return lines
  }

  package static func layout(
    prefix: String?,
    environment: [String: String],
    currentDirectory: URL
  ) throws -> Layout {
    let prefixPath: String
    if let prefix {
      prefixPath = (prefix as NSString).expandingTildeInPath
    } else if let home = environment["HOME"], !home.isEmpty {
      prefixPath =
        URL(fileURLWithPath: home, isDirectory: true)
        .appendingPathComponent(".local", isDirectory: true).path
    } else {
      throw SourceInstallError.message(
        "HOME is not set. Pass --prefix with an explicit installation prefix."
      )
    }
    guard !prefixPath.contains(where: \.isNewline) else {
      throw SourceInstallError.message(
        "The installation prefix must not contain a newline."
      )
    }

    let prefixURL = URL(
      fileURLWithPath: prefixPath,
      isDirectory: true,
      relativeTo: currentDirectory
    ).standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    let binDirectory = prefixURL.appendingPathComponent("bin", isDirectory: true)
    let installRoot =
      prefixURL
      .appendingPathComponent("libexec", isDirectory: true)
      .appendingPathComponent("sim-use-network", isDirectory: true)
    return Layout(
      prefix: prefixURL,
      binDirectory: binDirectory,
      command: binDirectory.appendingPathComponent("sim-use-network", isDirectory: false),
      installRoot: installRoot,
      payloadsDirectory: installRoot.appendingPathComponent("payloads", isDirectory: true)
    )
  }

  package static func repositoryRoot(
    from executableURL: URL,
    fileManager: FileManager
  ) throws -> URL {
    var directory = executableURL.deletingLastPathComponent().standardizedFileURL
    while directory.path != "/" {
      if directory.lastPathComponent == ".build" {
        let root = directory.deletingLastPathComponent()
        let manifest = root.appendingPathComponent("Package.swift", isDirectory: false)
        guard fileManager.fileExists(atPath: manifest.path) else { break }
        return root
      }
      directory.deleteLastPathComponent()
    }
    throw SourceInstallError.message(
      "Could not locate the sim-use-network source checkout. Run with `swift run -c release sim-use-network-install` from the repository."
    )
  }

  private func prepareInstallDirectories(_ layout: Layout) throws {
    try ensureDirectory(layout.binDirectory, allowSymlink: true)
    try ensureDirectory(layout.installRoot, allowSymlink: false)
    try ensureDirectory(layout.payloadsDirectory, allowSymlink: false)
  }

  private func ensureDirectory(_ url: URL, allowSymlink: Bool) throws {
    if let kind = try itemKind(at: url) {
      if kind == .directory { return }
      if allowSymlink,
        kind == .symbolicLink,
        let attributes = try? fileManager.attributesOfItem(
          atPath: url.resolvingSymlinksInPath().path),
        attributes[.type] as? FileAttributeType == .typeDirectory
      {
        return
      }
      throw SourceInstallError.message("Expected a directory at \(url.path).")
    }
    try fileManager.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755]
    )
  }

  private func validateExistingDestination(_ layout: Layout) throws {
    guard let commandKind = try itemKind(at: layout.command) else { return }
    guard commandKind == .regularFile else {
      throw SourceInstallError.message(
        "Refusing to replace a non-regular command at \(layout.command.path)."
      )
    }
    if let contents = try? String(contentsOf: layout.command, encoding: .utf8),
      try managedWrapperPayload(contents, layout: layout) != nil
    {
      return
    }
    throw SourceInstallError.message(
      "Refusing to replace an unrecognized command at \(layout.command.path). Move it aside, then rerun the installer."
    )
  }

  private func validateArtifacts(in directory: URL) throws {
    for artifact in Self.artifacts {
      let url = directory.appendingPathComponent(artifact.name)
      switch artifact.kind {
      case .executable:
        guard try itemKind(at: url) == .regularFile,
          fileManager.isExecutableFile(atPath: url.path)
        else {
          throw SourceInstallError.message(
            "Missing executable build artifact: \(url.path)"
          )
        }
      case .bundle(let requiredPaths):
        guard try itemKind(at: url) == .directory else {
          throw SourceInstallError.message("Missing resource bundle: \(url.path)")
        }
        let resourceRoot = try bundleResourceRoot(url)
        for relativePath in requiredPaths {
          let requiredURL = resourceRoot.appendingPathComponent(relativePath)
          guard try itemKind(at: requiredURL) == .regularFile else {
            throw SourceInstallError.message(
              "Resource bundle is incomplete: \(requiredURL.path)"
            )
          }
        }
      }
    }
  }

  private func bundleResourceRoot(_ bundle: URL) throws -> URL {
    let swiftBuildResources = bundle.appendingPathComponent(
      "Contents/Resources", isDirectory: true)
    if try itemKind(at: swiftBuildResources) == .directory {
      return swiftBuildResources
    }
    return bundle
  }

  private func validateOwnershipMarker(in payload: URL) throws {
    let marker = payload.appendingPathComponent(Self.ownershipMarkerName)
    guard try itemKind(at: marker) == .regularFile,
      try String(contentsOf: marker, encoding: .utf8) == Self.ownershipMarkerContents
    else {
      throw SourceInstallError.message(
        "Payload is not owned by this installer: \(payload.path)"
      )
    }
  }

  private func copyArtifacts(from source: URL, to destination: URL) throws {
    for artifact in Self.artifacts {
      let sourceURL = source.appendingPathComponent(artifact.name)
      let destinationURL = destination.appendingPathComponent(artifact.name)
      try fileManager.copyItem(at: sourceURL, to: destinationURL)
      if artifact.kind == .executable {
        try fileManager.setAttributes(
          [.posixPermissions: 0o755],
          ofItemAtPath: destinationURL.path
        )
      }
    }
  }

  private func wrapperContents(payload: URL) throws -> String {
    let executable = payload.appendingPathComponent("sim-use-network").path
    guard !executable.contains(where: \.isNewline) else {
      throw SourceInstallError.message(
        "The installation prefix contains a newline and cannot be used in the command wrapper."
      )
    }
    return "#!/bin/sh\n\(Self.currentWrapperMarker)\nexec \(shellQuote(executable)) \"$@\"\n"
  }

  private func managedWrapperPayload(_ contents: String, layout: Layout) throws -> URL? {
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.count == 4,
      lines[0] == "#!/bin/sh",
      Self.supportedWrapperMarkers.contains(lines[1]),
      lines[3].isEmpty
    else {
      return nil
    }

    guard let payloadsKind = try itemKind(at: layout.payloadsDirectory) else { return nil }
    guard payloadsKind == .directory else {
      throw SourceInstallError.message(
        "Expected an installer-owned payload directory at \(layout.payloadsDirectory.path)."
      )
    }
    for name in try fileManager.contentsOfDirectory(atPath: layout.payloadsDirectory.path) {
      let payload = layout.payloadsDirectory.appendingPathComponent(name, isDirectory: true)
      guard try itemKind(at: payload) == .directory else { continue }
      let executable = payload.appendingPathComponent("sim-use-network").path
      guard lines[2] == "exec \(shellQuote(executable)) \"$@\"" else { continue }
      try validateOwnershipMarker(in: payload)
      return payload
    }
    return nil
  }

  private func itemKind(at url: URL) throws -> ItemKind? {
    var metadata = stat()
    let result = url.path.withCString { Darwin.lstat($0, &metadata) }
    guard result == 0 else {
      if errno == ENOENT { return nil }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    switch metadata.st_mode & S_IFMT {
    case S_IFREG: return .regularFile
    case S_IFDIR: return .directory
    case S_IFLNK: return .symbolicLink
    default: return .other
    }
  }

  private func atomicRename(_ source: URL, to destination: URL) throws {
    let result = source.path.withCString { sourcePath in
      destination.path.withCString { destinationPath in
        Darwin.rename(sourcePath, destinationPath)
      }
    }
    guard result == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}

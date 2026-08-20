// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

package struct ProcessResult: Equatable, Sendable {
  package let status: Int32
  package let standardOutput: String
  package let standardError: String

  package var combinedOutput: String {
    [standardOutput, standardError]
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
  }
}

package struct ProcessClient: Sendable {
  private let operation:
    @Sendable (
      _ executable: URL,
      _ arguments: [String],
      _ environment: [String: String],
      _ inheritedLeaseDescriptor: Int32?
    ) throws -> ProcessResult
  private let inheritedLeaseDescriptor: Int32?

  package init(
    run:
      @escaping @Sendable (
        _ executable: URL,
        _ arguments: [String],
        _ environment: [String: String]
      ) throws -> ProcessResult
  ) {
    operation = { executable, arguments, environment, _ in
      try run(executable, arguments, environment)
    }
    inheritedLeaseDescriptor = nil
  }

  private init(
    operation:
      @escaping @Sendable (
        _ executable: URL,
        _ arguments: [String],
        _ environment: [String: String],
        _ inheritedLeaseDescriptor: Int32?
      ) throws -> ProcessResult,
    inheritedLeaseDescriptor: Int32?
  ) {
    self.operation = operation
    self.inheritedLeaseDescriptor = inheritedLeaseDescriptor
  }

  package static let live = ProcessClient(
    operation: { executable, arguments, environment, inheritedLeaseDescriptor in
      let fileManager = FileManager.default
      let captureDirectory = fileManager.temporaryDirectory
        .appending(
          path: "sim-use-network-process-\(UUID().uuidString)", directoryHint: .isDirectory)
      try fileManager.createDirectory(
        at: captureDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      defer { try? fileManager.removeItem(at: captureDirectory) }

      let standardOutputURL = captureDirectory.appending(path: "stdout")
      let standardErrorURL = captureDirectory.appending(path: "stderr")
      guard
        fileManager.createFile(
          atPath: standardOutputURL.path,
          contents: nil,
          attributes: [.posixPermissions: 0o600]
        ),
        fileManager.createFile(
          atPath: standardErrorURL.path,
          contents: nil,
          attributes: [.posixPermissions: 0o600]
        )
      else {
        throw SimUseNetworkError.invalidSession("Could not create process capture files.")
      }

      let standardOutput = try FileHandle(forWritingTo: standardOutputURL)
      let standardError = try FileHandle(forWritingTo: standardErrorURL)
      defer {
        try? standardOutput.close()
        try? standardError.close()
      }

      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      process.environment = ProcessInfo.processInfo.environment.merging(environment) {
        _, replacement in
        replacement
      }
      process.standardOutput = standardOutput
      process.standardError = standardError
      let childLease: FileHandle?
      if let inheritedLeaseDescriptor {
        let duplicate = Darwin.dup(inheritedLeaseDescriptor)
        guard duplicate >= 0 else {
          throw SimUseNetworkError.invalidSession(
            "Could not duplicate the device lease for a child process: errno \(errno)."
          )
        }
        childLease = FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
        process.standardInput = childLease
      } else {
        childLease = nil
      }
      try process.run()
      process.waitUntilExit()
      withExtendedLifetime(childLease) {}
      try standardOutput.close()
      try standardError.close()

      return ProcessResult(
        status: process.terminationStatus,
        standardOutput: String(decoding: try Data(contentsOf: standardOutputURL), as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines),
        standardError: String(decoding: try Data(contentsOf: standardErrorURL), as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
      )
    },
    inheritedLeaseDescriptor: nil
  )

  package func inheritingLease(from lock: DeviceLock) -> ProcessClient {
    ProcessClient(
      operation: operation,
      inheritedLeaseDescriptor: lock.childLeaseDescriptor
    )
  }

  package func run(
    _ executable: URL,
    _ arguments: [String],
    _ environment: [String: String]
  ) throws -> ProcessResult {
    try operation(executable, arguments, environment, inheritedLeaseDescriptor)
  }

  package func checked(
    _ executable: URL,
    _ arguments: [String],
    environment: [String: String] = [:]
  ) throws -> ProcessResult {
    let result = try run(executable, arguments, environment)
    guard result.status == 0 else {
      let command = ([executable.path] + arguments).map(Self.shellQuote).joined(separator: " ")
      throw SimUseNetworkError.commandFailed(
        command: command,
        status: result.status,
        diagnostics: result.combinedOutput
      )
    }
    return result
  }

  private static func shellQuote(_ value: String) -> String {
    guard value.contains(where: { $0.isWhitespace || "'\"\\$`".contains($0) }) else {
      return value
    }
    return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}

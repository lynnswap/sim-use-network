// SPDX-License-Identifier: Apache-2.0

import Foundation

package struct InstallProcess: Sendable {
  package enum Output: Sendable {
    case inherit
    case discard
  }

  private let operation:
    @Sendable (_ executable: URL, _ arguments: [String], _ directory: URL?, _ output: Output) throws
      -> Int32

  package init(
    run:
      @escaping @Sendable (
        _ executable: URL,
        _ arguments: [String],
        _ directory: URL?,
        _ output: Output
      ) throws -> Int32
  ) {
    operation = run
  }

  package static let live = InstallProcess { executable, arguments, directory, output in
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = directory
    switch output {
    case .inherit:
      process.standardOutput = FileHandle.standardOutput
      process.standardError = FileHandle.standardError
    case .discard:
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
    }
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  package func checked(
    _ executable: URL,
    _ arguments: [String],
    in directory: URL? = nil,
    output: Output
  ) throws {
    let status = try operation(executable, arguments, directory, output)
    guard status == 0 else {
      let command = ([executable.path] + arguments).map(Self.shellQuote).joined(separator: " ")
      throw SourceInstallError.message("Command failed (status \(status)): \(command)")
    }
  }

  private static func shellQuote(_ value: String) -> String {
    guard value.contains(where: { $0.isWhitespace || "'\"\\$`".contains($0) }) else {
      return value
    }
    return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}

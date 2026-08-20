// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Darwin
import Foundation

protocol NetworkExecutableCommand: ParsableCommand {
  associatedtype ExecutionResult: Encodable

  var jsonOutput: Bool { get }

  mutating func execute() throws -> ExecutionResult
  func format(_ result: ExecutionResult) -> String
}

extension NetworkExecutableCommand {
  mutating func run() throws {
    if jsonOutput {
      do {
        try JSONEnvelopeWriter.writeSuccess(try execute())
      } catch {
        JSONEnvelopeWriter.writeError(error)
        Darwin.exit(1)
      }
    } else {
      do {
        print(format(try execute()))
      } catch {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
        Darwin.exit(1)
      }
    }
  }
}

enum JSONEnvelopeWriter {
  static func writeSuccess<Value: Encodable>(
    _ value: Value,
    to handle: FileHandle = .standardOutput
  ) throws {
    handle.write(try encoder().encode(SuccessEnvelope(data: value)))
    handle.write(Data([0x0A]))
  }

  static func writeError(
    _ error: Error,
    to handle: FileHandle = .standardOutput
  ) {
    guard let data = try? encoder().encode(ErrorEnvelope(error: error.localizedDescription)) else {
      return
    }
    handle.write(data)
    handle.write(Data([0x0A]))
  }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

private struct SuccessEnvelope<Value: Encodable>: Encodable {
  let ok = true
  let data: Value
}

private struct ErrorEnvelope: Encodable {
  let ok = false
  let error: String
}

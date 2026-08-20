// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import SimUseNetworkCLI

private struct Payload: Encodable {
  let value: String
}

private struct TestFailure: Error, LocalizedError {
  var errorDescription: String? { "expected failure" }
}

@Suite
struct JSONEnvelopeWriterTests {
  @Test
  func successIsCompactSortedJSONWithOneLineFeed() throws {
    let output = try capture { handle in
      try JSONEnvelopeWriter.writeSuccess(Payload(value: "ok"), to: handle)
    }

    #expect(output == #"{"data":{"value":"ok"},"ok":true}"# + "\n")
  }

  @Test
  func failureUsesTheSameOneLineEnvelope() throws {
    let output = try capture { handle in
      JSONEnvelopeWriter.writeError(TestFailure(), to: handle)
    }

    #expect(output == #"{"error":"expected failure","ok":false}"# + "\n")
  }

  private func capture(_ operation: (FileHandle) throws -> Void) throws -> String {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "sim-use-network-json-test-\(UUID().uuidString)"
    )
    FileManager.default.createFile(atPath: url.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try FileHandle(forWritingTo: url)
    try operation(handle)
    try handle.close()
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
  }
}

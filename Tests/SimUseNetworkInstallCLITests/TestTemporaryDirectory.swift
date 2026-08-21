// SPDX-License-Identifier: Apache-2.0

import Foundation

final class TestTemporaryDirectory {
  let url: URL

  init(prefix: String) throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: false
    )
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}

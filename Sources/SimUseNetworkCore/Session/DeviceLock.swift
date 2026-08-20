// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

package final class DeviceLock {
  private let descriptor: Int32

  package var childLeaseDescriptor: Int32 { descriptor }

  package init(fileURL: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )

    descriptor = Darwin.open(
      fileURL.path,
      O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
      0o600
    )
    guard descriptor >= 0 else {
      throw SimUseNetworkError.invalidSession(
        "Could not open the device lock at \(fileURL.path): errno \(errno)."
      )
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(descriptor)
      throw SimUseNetworkError.invalidSession(
        "Another sim-use-network command is already changing this device."
      )
    }
  }

  deinit {
    flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
  }
}

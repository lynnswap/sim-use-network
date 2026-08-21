// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

package final class SourceInstallLock {
  private let descriptor: Int32

  package init(url: URL) throws {
    let openedDescriptor = url.path.withCString {
      Darwin.open($0, O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_RDWR, S_IRUSR | S_IWUSR)
    }
    guard openedDescriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    descriptor = openedDescriptor

    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let lockError = errno
      Darwin.close(descriptor)
      if lockError == EWOULDBLOCK {
        throw SourceInstallError.message(
          "Another sim-use-network installation is already using \(url.path)."
        )
      }
      throw POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO)
    }
  }

  deinit {
    flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
  }
}

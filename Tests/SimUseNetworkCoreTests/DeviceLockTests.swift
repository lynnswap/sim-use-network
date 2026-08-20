// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import SimUseNetworkCore

@Suite
struct DeviceLockTests {
  @Test
  func rejectsConcurrentLeaseForSameDevice() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lockURL = directory.appending(path: "device.lock")
    let first = try DeviceLock(fileURL: lockURL)

    #expect(throws: SimUseNetworkError.self) {
      _ = try DeviceLock(fileURL: lockURL)
    }
    withExtendedLifetime(first) {}
  }

  @Test
  func childProcessReceivesLeaseAsStandardInput() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lockURL = directory.appending(path: "device.lock")
    let lock = try DeviceLock(fileURL: lockURL)
    let client = ProcessClient.live.inheritingLease(from: lock)

    let childInode = try client.checked(
      URL(filePath: "/usr/bin/stat"),
      ["-f", "%i", "/dev/fd/0"]
    ).standardOutput
    let attributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
    let lockInode = try #require(attributes[.systemFileNumber] as? NSNumber)

    #expect(childInode == lockInode.stringValue)
    withExtendedLifetime(lock) {}
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "sim-use-network-lock-test-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
  }
}

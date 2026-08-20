// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

package struct SessionStore {
  package let rootDirectory: URL
  private let fileManager: FileManager

  package init(
    rootDirectory: URL? = nil,
    fileManager: FileManager = .default
  ) throws {
    self.fileManager = fileManager
    if let rootDirectory {
      self.rootDirectory = rootDirectory
    } else {
      guard
        let applicationSupport = fileManager.urls(
          for: .applicationSupportDirectory,
          in: .userDomainMask
        ).first
      else {
        throw SimUseNetworkError.invalidSession("Could not locate Application Support.")
      }
      self.rootDirectory = applicationSupport.appending(
        path: "sim-use-network",
        directoryHint: .isDirectory
      )
    }
  }

  package func acquireLock(deviceUDID: String) throws -> DeviceLock {
    try DeviceLock(fileURL: lockURL(deviceUDID: deviceUDID))
  }

  package func sessionDirectory(deviceUDID: String) -> URL {
    rootDirectory
      .appending(path: "sessions", directoryHint: .isDirectory)
      .appending(path: deviceUDID, directoryHint: .isDirectory)
  }

  package func createSessionDirectory(deviceUDID: String) throws -> URL {
    let directory = sessionDirectory(deviceUDID: deviceUDID)
    try rejectSymbolicLink(at: directory)
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    return directory
  }

  package func createFreshSessionDirectory(deviceUDID: String) throws -> URL {
    let directory = sessionDirectory(deviceUDID: deviceUDID)
    var metadata = stat()
    if lstat(directory.path, &metadata) == 0 {
      throw SimUseNetworkError.invalidSession(
        "An orphaned session directory already exists at \(directory.path). "
          + "Inspect it before removing it and preparing again."
      )
    }
    guard errno == ENOENT else {
      throw SimUseNetworkError.invalidSession(
        "Could not inspect session directory \(directory.path): errno \(errno)."
      )
    }
    return try createSessionDirectory(deviceUDID: deviceUDID)
  }

  package func load(deviceUDID: String) throws -> SessionRecord? {
    try rejectSymbolicLink(at: sessionDirectory(deviceUDID: deviceUDID))
    let url = recordURL(deviceUDID: deviceUDID)
    try rejectSymbolicLink(at: url)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let record = try decoder.decode(SessionRecord.self, from: Data(contentsOf: url))
    guard record.schemaVersion == SessionRecord.currentSchemaVersion else {
      throw SimUseNetworkError.invalidSession(
        "Unsupported session schema \(record.schemaVersion) at \(url.path)."
      )
    }
    guard record.device.udid == deviceUDID else {
      throw SimUseNetworkError.invalidSession(
        "Session identity mismatch at \(url.path). Run cleanup before continuing."
      )
    }
    return record
  }

  package func save(_ record: SessionRecord) throws {
    let directory = try createSessionDirectory(deviceUDID: record.device.udid)
    let url = directory.appending(path: "session.json")
    try rejectSymbolicLink(at: url)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(record).write(to: url, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  package func remove(deviceUDID: String) throws {
    let directory = sessionDirectory(deviceUDID: deviceUDID)
    try rejectSymbolicLink(at: directory)
    guard fileManager.fileExists(atPath: directory.path) else { return }
    try fileManager.removeItem(at: directory)
  }

  private func recordURL(deviceUDID: String) -> URL {
    sessionDirectory(deviceUDID: deviceUDID).appending(path: "session.json")
  }

  private func lockURL(deviceUDID: String) -> URL {
    rootDirectory
      .appending(path: "locks", directoryHint: .isDirectory)
      .appending(path: "\(deviceUDID).lock")
  }

  private func rejectSymbolicLink(at url: URL) throws {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      if errno == ENOENT { return }
      throw SimUseNetworkError.invalidSession(
        "Could not inspect \(url.path): errno \(errno)."
      )
    }
    guard metadata.st_mode & S_IFMT != S_IFLNK else {
      throw SimUseNetworkError.invalidSession(
        "Refusing to use symbolic link at \(url.path)."
      )
    }
  }
}

// SPDX-License-Identifier: Apache-2.0

import Foundation

package struct StateKeeperPlistWriter {
  private let fileManager: FileManager

  package init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  package func write(
    label: String,
    stateName: String,
    readyName: String,
    appShimReadyName: String,
    daemonShimReadyName: String,
    userName: String?,
    to url: URL
  ) throws {
    let payload = StateKeeperLaunchdPayload(
      label: label,
      programArguments: [
        "/usr/bin/notifyutil",
        "-q",
        "-R",
        "-w", stateName,
        "-w", appShimReadyName,
        "-w", daemonShimReadyName,
        "-w", readyName,
      ],
      keepAlive: true,
      userName: userName
    )
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml
    try encoder.encode(payload).write(to: url, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

private struct StateKeeperLaunchdPayload: Encodable {
  let label: String
  let programArguments: [String]
  let keepAlive: Bool
  let userName: String?

  enum CodingKeys: String, CodingKey {
    case label = "Label"
    case programArguments = "ProgramArguments"
    case keepAlive = "KeepAlive"
    case userName = "UserName"
  }
}

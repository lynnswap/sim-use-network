// SPDX-License-Identifier: Apache-2.0

package struct CleanupReport: Codable, Equatable {
  package let deviceUDID: String
  package let deviceName: String
  package let warnings: [String]
}

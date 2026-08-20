// SPDX-License-Identifier: Apache-2.0

import SimUseNetworkCore

enum StatusText {
  static func render(_ status: SessionStatus) -> String {
    """
    Device: \(status.deviceName) [\(status.deviceUDID)]
    Runtime: \(status.platform) \(status.runtimeVersion) (\(status.runtimeBuild))
    App: \(status.bundleIdentifier) pid=\(status.appProcessIdentifier.map(String.init) ?? "not-running")
    Daemon: pid=\(status.daemonProcessIdentifier.map(String.init) ?? "not-running") runs=\(status.daemonRunCount.map(String.init) ?? "unknown")
    State keeper: pid=\(status.keeperProcessIdentifier.map(String.init) ?? "not-running")
    notifyd: pid=\(status.notifyDaemonProcessIdentifier) runs=\(status.notifyDaemonRunCount) stable=\(status.notifyDaemonStable ? "yes" : "no")
    State: \(status.availability.rawValue)
    Shim: app=\(status.appShimLoaded ? "loaded" : "missing") daemon=\(status.daemonShimLoaded ? "loaded" : "missing") keeper=\(status.keeperRunning ? "running" : "missing")
    """
  }
}

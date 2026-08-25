// SPDX-License-Identifier: Apache-2.0

import Foundation

struct ForegroundRequestMetrics: Equatable, Sendable {
  let protocolName: String?
  let connectionWasReused: Bool
}

// URLSession delegates are Sendable; the lock protects the collected metrics.
final class ForegroundRequestMetricsDelegate:
  NSObject,
  URLSessionTaskDelegate,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var metrics: ForegroundRequestMetrics?

  nonisolated var collectedMetrics: ForegroundRequestMetrics? {
    lock.withLock {
      metrics
    }
  }

  nonisolated func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    guard let transaction = metrics.transactionMetrics.last else {
      return
    }

    let collected = ForegroundRequestMetrics(
      protocolName: transaction.networkProtocolName,
      connectionWasReused: transaction.isReusedConnection
    )
    lock.withLock {
      self.metrics = collected
    }
  }
}

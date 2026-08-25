// SPDX-License-Identifier: Apache-2.0

import Foundation

enum BackgroundTransferProbe {
  static func run(request: URLRequest) async -> RequestStatus {
    await withCheckedContinuation { continuation in
      let delegate = BackgroundDownloadDelegate(continuation: continuation)
      let configuration = URLSessionConfiguration.background(
        withIdentifier:
          "io.github.lynnswap.sim-use-network.NetworkProbe.background.\(UUID().uuidString)"
      )
      // Background sessions always wait for connectivity; the model exposes
      // that state.
      configuration.timeoutIntervalForRequest = 15
      configuration.timeoutIntervalForResource = 30

      let session = URLSession(
        configuration: configuration,
        delegate: delegate,
        delegateQueue: nil
      )
      delegate.retain(session: session)
      session.downloadTask(with: request).resume()
    }
  }
}

// URLSession delegates are Sendable; the lock protects every mutable field below.
private final class BackgroundDownloadDelegate:
  NSObject,
  URLSessionDownloadDelegate,
  @unchecked Sendable
{
  private struct State {
    var session: URLSession?
    var downloadedByteCount: Int64?
    var isFinished = false
  }

  private let continuation: CheckedContinuation<RequestStatus, Never>
  private let lock = NSLock()
  private var state = State()

  init(continuation: CheckedContinuation<RequestStatus, Never>) {
    self.continuation = continuation
  }

  func retain(session: URLSession) {
    lock.withLock {
      state.session = session
    }
  }

  nonisolated func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    let byteCount = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize)
      .map(Int64.init) ?? 0
    lock.withLock {
      state.downloadedByteCount = byteCount
    }
  }

  nonisolated func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    let result: RequestStatus
    if let error {
      result = .failed(ProbeFailure(error: error))
    } else {
      let byteCount = lock.withLock {
        state.downloadedByteCount
      }
      result = NetworkProbeModel.status(
        response: task.response,
        byteCount: byteCount ?? 0
      )
    }
    finish(result)
  }

  private nonisolated func finish(_ result: RequestStatus) {
    let session: URLSession? = lock.withLock {
      guard !state.isFinished else {
        return nil
      }
      state.isFinished = true
      defer { state.session = nil }
      return state.session
    }

    guard let session else {
      return
    }
    session.finishTasksAndInvalidate()
    continuation.resume(returning: result)
  }
}

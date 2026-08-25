// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network
import Observation

struct NetworkPathSnapshot: Equatable, Sendable {
  let status: String
  let interfaces: [String]
  let isExpensive: Bool
  let isConstrained: Bool
  let isSatisfied: Bool

  static let waiting = NetworkPathSnapshot(
    status: "Waiting",
    interfaces: [],
    isExpensive: false,
    isConstrained: false,
    isSatisfied: false
  )

  nonisolated init(path: NWPath) {
    switch path.status {
    case .satisfied:
      status = "Satisfied"
    case .unsatisfied:
      status = "Unsatisfied"
    case .requiresConnection:
      status = "Requires Connection"
    @unknown default:
      status = "Unknown"
    }

    interfaces = path.availableInterfaces
      .map { Self.interfaceName($0.type) }
      .sorted()
    isExpensive = path.isExpensive
    isConstrained = path.isConstrained
    isSatisfied = path.status == .satisfied
  }

  private init(
    status: String,
    interfaces: [String],
    isExpensive: Bool,
    isConstrained: Bool,
    isSatisfied: Bool
  ) {
    self.status = status
    self.interfaces = interfaces
    self.isExpensive = isExpensive
    self.isConstrained = isConstrained
    self.isSatisfied = isSatisfied
  }

  private nonisolated static func interfaceName(_ type: NWInterface.InterfaceType) -> String {
    switch type {
    case .other:
      "Other"
    case .wifi:
      "Wi-Fi"
    case .cellular:
      "Cellular"
    case .wiredEthernet:
      "Wired Ethernet"
    case .loopback:
      "Loopback"
    @unknown default:
      "Unknown"
    }
  }
}

struct ProbeFailure: Equatable, Error, Sendable {
  let domain: String
  let code: Int
  let message: String

  nonisolated init(error: any Error) {
    let error = error as NSError
    domain = error.domain
    code = error.code
    message = error.localizedDescription
  }

  nonisolated init(domain: String, code: Int, message: String) {
    self.domain = domain
    self.code = code
    self.message = message
  }
}

enum RequestStatus: Equatable, Sendable {
  case idle
  case running
  case waitingForConnectivity
  case succeeded(
    statusCode: Int,
    byteCount: Int64,
    metrics: ForegroundRequestMetrics?
  )
  case failed(ProbeFailure)

  var summary: String {
    switch self {
    case .idle:
      "Not Run"
    case .running:
      "Running"
    case .waitingForConnectivity:
      "Waiting for Connectivity"
    case .succeeded(let statusCode, let byteCount, _):
      "HTTP \(statusCode), \(byteCount) bytes"
    case .failed(let failure):
      "\(failure.domain) \(failure.code)"
    }
  }

  var detail: String? {
    switch self {
    case .succeeded(_, _, let metrics):
      guard let metrics else {
        return nil
      }
      let protocolName = metrics.protocolName ?? "Unknown protocol"
      return metrics.connectionWasReused
        ? "\(protocolName), reused connection"
        : "\(protocolName), new connection"
    case .failed(let failure):
      return failure.message
    case .idle, .running, .waitingForConnectivity:
      return nil
    }
  }

  var isRunning: Bool {
    self == .running || self == .waitingForConnectivity
  }
}

@MainActor
@Observable
final class NetworkProbeModel {
  private(set) var pathSnapshot = NetworkPathSnapshot.waiting
  private(set) var foregroundStatus = RequestStatus.idle
  private(set) var backgroundStatus = RequestStatus.idle

  private let pathMonitor = NWPathMonitor()
  private let pathQueue = DispatchQueue(
    label: "io.github.lynnswap.sim-use-network.NetworkProbe.path"
  )
  private let foregroundSession: URLSession
  private var isPathMonitorStarted = false

  init() {
    let configuration = URLSessionConfiguration.default
    configuration.waitsForConnectivity = false
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 30
    foregroundSession = URLSession(configuration: configuration)
  }

  func start() {
    guard !isPathMonitorStarted else {
      return
    }
    isPathMonitorStarted = true

    pathMonitor.pathUpdateHandler = { [weak self] path in
      let snapshot = NetworkPathSnapshot(path: path)
      Task { @MainActor [weak self] in
        self?.pathSnapshot = snapshot
      }
    }
    pathMonitor.start(queue: pathQueue)
  }

  func runForegroundRequest(endpoint: String) async {
    guard !foregroundStatus.isRunning else {
      return
    }

    let request: URLRequest
    switch Self.makeRequest(endpoint: endpoint) {
    case .success(let value):
      request = value
    case .failure(let failure):
      foregroundStatus = .failed(failure)
      return
    }

    foregroundStatus = .running
    do {
      let metrics = ForegroundRequestMetricsDelegate()
      let (data, response) = try await foregroundSession.data(
        for: request,
        delegate: metrics
      )
      foregroundStatus = Self.status(
        response: response,
        byteCount: Int64(data.count),
        metrics: metrics.collectedMetrics
      )
    } catch {
      foregroundStatus = .failed(ProbeFailure(error: error))
    }
  }

  func runBackgroundRequest(endpoint: String) async {
    guard !backgroundStatus.isRunning else {
      return
    }

    let request: URLRequest
    switch Self.makeRequest(endpoint: endpoint) {
    case .success(let value):
      request = value
    case .failure(let failure):
      backgroundStatus = .failed(failure)
      return
    }

    backgroundStatus = pathSnapshot.isSatisfied
      ? .running
      : .waitingForConnectivity
    backgroundStatus = await BackgroundTransferProbe.run(request: request)
  }

  func resetResults() {
    guard !foregroundStatus.isRunning, !backgroundStatus.isRunning else {
      return
    }
    foregroundStatus = .idle
    backgroundStatus = .idle
  }

  deinit {
    pathMonitor.cancel()
    foregroundSession.invalidateAndCancel()
  }

  private static func makeRequest(endpoint: String) -> Result<URLRequest, ProbeFailure> {
    guard
      var components = URLComponents(string: endpoint),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      components.host != nil
    else {
      return .failure(
        ProbeFailure(
          domain: "NetworkProbe",
          code: 1,
          message: "Enter an absolute HTTP or HTTPS URL."
        )
      )
    }

    var queryItems = components.queryItems ?? []
    queryItems.append(URLQueryItem(name: "network-probe", value: UUID().uuidString))
    components.queryItems = queryItems

    guard let url = components.url else {
      return .failure(
        ProbeFailure(
          domain: "NetworkProbe",
          code: 2,
          message: "The endpoint could not be converted to a URL."
        )
      )
    }

    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 15
    return .success(request)
  }

  nonisolated static func status(
    response: URLResponse?,
    byteCount: Int64,
    metrics: ForegroundRequestMetrics? = nil
  ) -> RequestStatus {
    guard let response = response as? HTTPURLResponse else {
      return .failed(
        ProbeFailure(
          domain: "NetworkProbe",
          code: 3,
          message: "The request completed without an HTTP response."
        )
      )
    }
    return .succeeded(
      statusCode: response.statusCode,
      byteCount: byteCount,
      metrics: metrics
    )
  }
}

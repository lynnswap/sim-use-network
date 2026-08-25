// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct ContentView: View {
  @Bindable var model: NetworkProbeModel
  @AppStorage("NetworkProbe.endpoint")
  private var endpoint = "https://example.com/"

  var body: some View {
    NavigationStack {
      List {
        Section("Endpoint") {
          TextField("URL", text: $endpoint)
            .accessibilityIdentifier("network-probe.endpoint")
        }

        Section("Network Path") {
          LabeledContent("Status", value: model.pathSnapshot.status)
            .accessibilityIdentifier("network-probe.path.status")
          LabeledContent(
            "Interfaces",
            value: model.pathSnapshot.interfaces.isEmpty
              ? "None"
              : model.pathSnapshot.interfaces.joined(separator: ", ")
          )
          .accessibilityIdentifier("network-probe.path.interfaces")
          LabeledContent(
            "Expensive",
            value: model.pathSnapshot.isExpensive ? "Yes" : "No"
          )
          LabeledContent(
            "Constrained",
            value: model.pathSnapshot.isConstrained ? "Yes" : "No"
          )
        }

        Section("Requests") {
          RequestStatusRow(
            title: "Foreground",
            status: model.foregroundStatus,
            accessibilityIdentifier: "network-probe.foreground.status"
          )
          RequestStatusRow(
            title: "Background",
            status: model.backgroundStatus,
            accessibilityIdentifier: "network-probe.background.status"
          )
        }

        Section("Actions") {
          Button("Run Foreground Request") {
            Task {
              await model.runForegroundRequest(endpoint: endpoint)
            }
          }
          .disabled(model.foregroundStatus.isRunning)
          .accessibilityIdentifier("network-probe.action.foreground")

          Button("Run Background Request") {
            Task {
              await model.runBackgroundRequest(endpoint: endpoint)
            }
          }
          .disabled(model.backgroundStatus.isRunning)
          .accessibilityIdentifier("network-probe.action.background")

          Button("Reset Results") {
            model.resetResults()
          }
          .disabled(
            model.foregroundStatus.isRunning || model.backgroundStatus.isRunning
          )
          .accessibilityIdentifier("network-probe.action.reset")
        }
      }
      .navigationTitle("Network Probe")
    }
    .task {
      model.start()
    }
  }
}

private struct RequestStatusRow: View {
  let title: String
  let status: RequestStatus
  let accessibilityIdentifier: String

  var body: some View {
    LabeledContent {
      VStack(alignment: .trailing, spacing: 2) {
        Text(status.summary)
        if let detail = status.detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    } label: {
      Text(title)
    }
    .accessibilityIdentifier(accessibilityIdentifier)
  }
}

#Preview {
  ContentView(model: NetworkProbeModel())
}

// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@main
struct NetworkProbeApp: App {
  @State private var model = NetworkProbeModel()

  var body: some Scene {
    WindowGroup {
      ContentView(model: model)
    }
  }
}

// SPDX-License-Identifier: Apache-2.0

import ArgumentParser

struct DeviceOptions: ParsableArguments {
  @Option(
    name: .long, help: "Simulator UDID. Defaults to SIM_USE_DEVICE or the only booted Simulator.")
  var device: String?
}

struct OutputOptions: ParsableArguments {
  @Flag(name: .long, help: "Emit a stable JSON result envelope.")
  var json = false
}

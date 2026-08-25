#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
workspace="$repo_root/sim-use-network.xcworkspace"

destinations=(
  "generic/platform=iOS Simulator"
  "generic/platform=macOS"
  "generic/platform=visionOS Simulator"
)

for destination in "${destinations[@]}"; do
  xcodebuild -quiet \
    -workspace "$workspace" \
    -scheme NetworkProbe \
    -configuration Debug \
    -destination "$destination" \
    CODE_SIGNING_ALLOWED=NO \
    build
done

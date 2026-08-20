#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_directory="$(mktemp -d "${TMPDIR:-/tmp}/sim-use-network-shim-tests.XXXXXX")"
trap 'rm -rf "$build_directory"' EXIT

xcrun --sdk macosx clang \
  -std=c17 \
  -Wall -Wextra -Wpedantic -Werror \
  -Wno-unused-function \
  -fblocks \
  -fsanitize=undefined \
  "$repo_root/Tests/RuntimeShimTests/NetworkUnavailableShimTests.c" \
  -o "$build_directory/NetworkUnavailableShimTests"

"$build_directory/NetworkUnavailableShimTests"

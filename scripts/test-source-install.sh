#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/sim-use-network-source-install.XXXXXX")"

cleanup() {
  if [[ -n "$temporary_directory" && -d "$temporary_directory" ]]; then
    rm -rf -- "$temporary_directory"
  fi
}
trap cleanup EXIT

mkdir -p "$temporary_directory/home"
source_checkout="$temporary_directory/source-checkout"
/usr/bin/rsync -a \
  --exclude '.build' \
  --exclude '.git' \
  "$repo_root/" \
  "$source_checkout/"
test ! -e "$source_checkout/.build"

prefix="$temporary_directory/prefix with space and 'quote"
install_log="$temporary_directory/install.log"

(
  cd "$source_checkout"
  HOME="$temporary_directory/home" \
    SHELL=/bin/zsh \
    swift run -c release sim-use-network-install --prefix "$prefix"
) >"$install_log"

command_path="$prefix/bin/sim-use-network"
payload_root="$prefix/libexec/sim-use-network"
payload_directory="$(find "$payload_root/payloads" -mindepth 1 -maxdepth 1 -type d -print)"
test -x "$command_path"
test -n "$payload_directory"
test "$(printf '%s\n' "$payload_directory" | wc -l | tr -d ' ')" -eq 1
test -f "$payload_directory/.sim-use-network-install"
test -x "$payload_directory/sim-use-network"

bundle_resource_root() {
  local bundle="$1"
  if [[ -d "$bundle/Contents/Resources" ]]; then
    printf '%s\n' "$bundle/Contents/Resources"
  else
    printf '%s\n' "$bundle"
  fi
}

installed_core_resources="$(bundle_resource_root \
  "$payload_directory/sim-use-network_SimUseNetworkCore.bundle")"
installed_cli_resources="$(bundle_resource_root \
  "$payload_directory/sim-use-network_SimUseNetworkCLI.bundle")"
test -f "$installed_core_resources/RuntimeArtifacts/NetworkUnavailableShim.c"
test -f "$installed_cli_resources/skills/sim-use-network/SKILL.md"
grep -Fq "not on PATH" "$install_log"
test ! -e "$temporary_directory/home/.zprofile"

release_bin="$(cd "$source_checkout" && swift build -c release --show-bin-path)"
core_bundle="$release_bin/sim-use-network_SimUseNetworkCore.bundle"
cli_bundle="$release_bin/sim-use-network_SimUseNetworkCLI.bundle"
mv "$core_bundle" "$core_bundle.source-install-hidden"
mv "$cli_bundle" "$cli_bundle.source-install-hidden"

"$command_path" init --print >"$temporary_directory/skill.txt"
grep -Fq "name: sim-use-network" "$temporary_directory/skill.txt"

if "$command_path" doctor --device definitely-invalid-udid \
  >"$temporary_directory/doctor.stdout" \
  2>"$temporary_directory/doctor.stderr"
then
  echo "doctor unexpectedly accepted an invalid Simulator UDID" >&2
  exit 1
fi
grep -Fq "No booted Apple Simulator matches definitely-invalid-udid" \
  "$temporary_directory/doctor.stderr"

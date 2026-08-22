#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/sim-use-network-release-install.XXXXXX")"

cleanup() {
  if [[ -n "$temporary_directory" && -d "$temporary_directory" ]]; then
    rm -rf -- "$temporary_directory"
  fi
}
trap cleanup EXIT

release_version="v0.1.0"
expected_version="0.1.0"
dist_root="$temporary_directory/dist"
release_directory="$temporary_directory/release"
home_directory="$temporary_directory/home"
prefix="$temporary_directory/prefix with space and 'quote"
isolated_path="/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$home_directory"
"$repo_root/scripts/build-release.sh" \
  --version "$release_version" \
  --dist-root "$dist_root"
"$repo_root/scripts/package-release.sh" \
  --version "$release_version" \
  --repo lynnswap/sim-use-network \
  --dist-root "$dist_root" \
  --output-dir "$release_directory"
"$repo_root/scripts/verify-release-assets.sh" \
  --version "$release_version" \
  --repo lynnswap/sim-use-network \
  --release-dir "$release_directory"

install_from() {
  local source_directory="$1"
  local destination_prefix="$2"
  /usr/bin/curl -fsSL "file://$source_directory/install.sh" |
    /usr/bin/env \
      SIM_USE_NETWORK_BASE_URL="file://$source_directory" \
      HOME="$home_directory" \
      SHELL=/bin/zsh \
      DEVELOPER_DIR=/definitely-missing \
      PATH="$isolated_path" \
      /bin/sh -s -- --prefix "$destination_prefix"
}

install_from "$release_directory" "$prefix" > "$temporary_directory/install.log"

command_path="$prefix/bin/sim-use-network"
payloads_directory="$prefix/libexec/sim-use-network/payloads"
test -x "$command_path"
test "$("$command_path" --version)" = "$expected_version"
DEVELOPER_DIR=/definitely-missing "$command_path" init --print \
  > "$temporary_directory/skill.txt"
grep -Fq "name: sim-use-network" "$temporary_directory/skill.txt"
grep -Fq "not on PATH" "$temporary_directory/install.log"
test ! -e "$home_directory/.zprofile"

payload_count="$(
  find "$payloads_directory" -mindepth 1 -maxdepth 1 -type d -print |
    wc -l |
    tr -d ' '
)"
test "$payload_count" -eq 1
wrapper_digest_before="$(shasum -a 256 "$command_path" | awk '{ print $1 }')"

tampered_release="$temporary_directory/tampered-release"
mkdir "$tampered_release"
cp "$release_directory/install.sh" "$tampered_release/install.sh"
cp "$release_directory/SHA256SUMS.txt" "$tampered_release/SHA256SUMS.txt"
cp \
  "$release_directory/sim-use-network-darwin-arm64.tar.gz" \
  "$tampered_release/sim-use-network-darwin-arm64.tar.gz"
printf 'tampered\n' >> "$tampered_release/sim-use-network-darwin-arm64.tar.gz"

if install_from "$tampered_release" "$prefix" \
  > "$temporary_directory/tampered.stdout" \
  2> "$temporary_directory/tampered.stderr"
then
  echo "Installer unexpectedly accepted a tampered release archive." >&2
  exit 1
fi
test "$(shasum -a 256 "$command_path" | awk '{ print $1 }')" = "$wrapper_digest_before"
test "$("$command_path" --version)" = "$expected_version"
payload_count="$(
  find "$payloads_directory" -mindepth 1 -maxdepth 1 -type d -print |
    wc -l |
    tr -d ' '
)"
test "$payload_count" -eq 1

install_from "$release_directory" "$prefix" > "$temporary_directory/update.log"
test "$("$command_path" --version)" = "$expected_version"
payload_count="$(
  find "$payloads_directory" -mindepth 1 -maxdepth 1 -type d -print |
    wc -l |
    tr -d ' '
)"
test "$payload_count" -eq 2
core_resource_count="$(
  find "$payloads_directory" \
    -path '*/sim-use-network_SimUseNetworkCore.bundle/RuntimeArtifacts/NetworkUnavailableShim.c' \
    -type f -print |
    wc -l |
    tr -d ' '
)"
test "$core_resource_count" -eq 2

mv "$dist_root" "$temporary_directory/dist-hidden"
mv "$release_directory" "$temporary_directory/release-hidden"
DEVELOPER_DIR=/definitely-missing "$command_path" init --print \
  > "$temporary_directory/installed-skill.txt"
grep -Fq "name: sim-use-network" "$temporary_directory/installed-skill.txt"

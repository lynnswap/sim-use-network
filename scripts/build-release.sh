#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-release.sh --version <tag> [--dist-root <dir>]

Builds and stages the arm64 release payload under:
  <dist-root>/arm64/installer/
  <dist-root>/arm64/payload/
EOF
}

version=""
dist_root="dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:-}"
      shift 2
      ;;
    --dist-root)
      dist_root="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! "$version" =~ ^v[0-9]+[.][0-9]+[.][0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  echo "Release tag must look like v1.2.3." >&2
  exit 1
fi

host_os="$(uname -s)"
host_arch="$(uname -m)"
if [[ "$host_os" != "Darwin" || "$host_arch" != "arm64" ]]; then
  echo "Release binaries must be built natively on macOS arm64, not ${host_os}/${host_arch}." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$dist_root" = /* ]]; then
  dist_base="$dist_root"
else
  dist_base="$repo_root/$dist_root"
fi
expected_version="${version#v}"
arm64_output="$dist_base/arm64"

if [[ -e "$arm64_output" || -L "$arm64_output" ]]; then
  echo "Release staging already exists; use a fresh --dist-root: $arm64_output" >&2
  exit 1
fi

for product in sim-use-network sim-use-network-install; do
  (
    cd "$repo_root"
    SIM_USE_NETWORK_BUILD_VERSION="$version" \
      swift build -c release --arch arm64 --product "$product"
  )
done

release_bin="$(
  cd "$repo_root"
  SIM_USE_NETWORK_BUILD_VERSION="$version" \
    swift build -c release --arch arm64 --show-bin-path
)"
network_binary="$release_bin/sim-use-network"
installer_binary="$release_bin/sim-use-network-install"
core_bundle="$release_bin/sim-use-network_SimUseNetworkCore.bundle"
cli_bundle="$release_bin/sim-use-network_SimUseNetworkCLI.bundle"

for binary in "$network_binary" "$installer_binary"; do
  if [[ ! -f "$binary" || ! -x "$binary" ]]; then
    echo "Missing release executable: $binary" >&2
    exit 1
  fi
  architectures="$(lipo -archs "$binary")"
  if [[ "$architectures" != "arm64" ]]; then
    echo "Expected an arm64 executable at $binary, got: $architectures" >&2
    exit 1
  fi
  codesign --verify --strict "$binary"
  embedded_version="$("$binary" --version)"
  if [[ "$embedded_version" != "$expected_version" ]]; then
    echo "Expected version $expected_version in $binary, got: $embedded_version" >&2
    exit 1
  fi
done

if [[ ! -f "$core_bundle/RuntimeArtifacts/NetworkUnavailableShim.c" ]]; then
  echo "Missing runtime shim resource in $core_bundle" >&2
  exit 1
fi
if [[ ! -f "$cli_bundle/skills/sim-use-network/SKILL.md" \
  || ! -f "$cli_bundle/skills/sim-use-network/.sim-use-network-skill" ]]
then
  echo "Missing bundled agent skill resources in $cli_bundle" >&2
  exit 1
fi

mkdir -p "$dist_base"
staging_directory="$(mktemp -d "${dist_base%/}/.arm64.XXXXXX")"
cleanup() {
  if [[ -n "${staging_directory:-}" && -d "$staging_directory" ]]; then
    rm -rf -- "$staging_directory"
  fi
}
trap cleanup EXIT

mkdir -p "$staging_directory/installer" "$staging_directory/payload"
install -m 755 "$installer_binary" "$staging_directory/installer/sim-use-network-install"
install -m 755 "$network_binary" "$staging_directory/payload/sim-use-network"
cp -R "$core_bundle" "$staging_directory/payload/"
cp -R "$cli_bundle" "$staging_directory/payload/"

if [[ -n "$(find "$staging_directory" -type l -print -quit)" ]]; then
  echo "Release staging must not contain symbolic links." >&2
  exit 1
fi

staged_installer="$staging_directory/installer/sim-use-network-install"
staged_network="$staging_directory/payload/sim-use-network"
if [[ "$("$staged_installer" --version)" != "$expected_version" \
  || "$("$staged_network" --version)" != "$expected_version" ]]
then
  echo "Staged executables do not contain release version $expected_version." >&2
  exit 1
fi

if [[ -e "$arm64_output" || -L "$arm64_output" ]]; then
  echo "Release staging appeared while building: $arm64_output" >&2
  exit 1
fi
mv "$staging_directory" "$arm64_output"
staging_directory=""

echo "Staged arm64 release payload: $arm64_output"

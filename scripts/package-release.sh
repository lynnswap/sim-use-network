#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/package-release.sh --version <tag> [--repo <owner/repo>] [--dist-root <dir>] [--output-dir <dir>]

Requires the staged arm64 tree from scripts/build-release.sh.

Outputs exactly:
  <output-dir>/sim-use-network-darwin-arm64.tar.gz
  <output-dir>/SHA256SUMS.txt
  <output-dir>/install.sh
EOF
}

version=""
release_repo="lynnswap/sim-use-network"
dist_root="dist"
output_dir="release"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:-}"
      shift 2
      ;;
    --repo)
      release_repo="${2:-}"
      shift 2
      ;;
    --dist-root)
      dist_root="${2:-}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:-}"
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

"$repo_root/scripts/validate-release-version.sh" "$version"
if [[ ! "$release_repo" =~ ^[0-9A-Za-z_.-]+/[0-9A-Za-z_.-]+$ ]]; then
  echo "Release repo must look like owner/repo." >&2
  exit 1
fi

if [[ "$dist_root" = /* ]]; then
  dist_base="$dist_root"
else
  dist_base="$repo_root/$dist_root"
fi
if [[ "$output_dir" = /* ]]; then
  output_base="$output_dir"
else
  output_base="$repo_root/$output_dir"
fi

arm64_stage="$dist_base/arm64"
installer="$arm64_stage/installer/sim-use-network-install"
network_binary="$arm64_stage/payload/sim-use-network"
core_bundle="$arm64_stage/payload/sim-use-network_SimUseNetworkCore.bundle"
cli_bundle="$arm64_stage/payload/sim-use-network_SimUseNetworkCLI.bundle"
expected_version="${version#v}"

expected_tree="$(cat <<'EOF'
installer
installer/sim-use-network-install
payload
payload/sim-use-network
payload/sim-use-network_SimUseNetworkCLI.bundle
payload/sim-use-network_SimUseNetworkCLI.bundle/skills
payload/sim-use-network_SimUseNetworkCLI.bundle/skills/sim-use-network
payload/sim-use-network_SimUseNetworkCLI.bundle/skills/sim-use-network/.sim-use-network-skill
payload/sim-use-network_SimUseNetworkCLI.bundle/skills/sim-use-network/SKILL.md
payload/sim-use-network_SimUseNetworkCore.bundle
payload/sim-use-network_SimUseNetworkCore.bundle/RuntimeArtifacts
payload/sim-use-network_SimUseNetworkCore.bundle/RuntimeArtifacts/NetworkUnavailableShim.c
EOF
)"
if [[ ! -d "$arm64_stage" ]]; then
  echo "Missing staged release directory: $arm64_stage" >&2
  exit 1
fi
actual_tree="$(cd "$arm64_stage" && find installer payload -print | LC_ALL=C sort)"
if [[ "$actual_tree" != "$expected_tree" ]]; then
  echo "Staged release tree is not expected." >&2
  printf 'Expected:\n%s\n' "$expected_tree" >&2
  printf 'Actual:\n%s\n' "$actual_tree" >&2
  exit 1
fi
if [[ -n "$(find "$arm64_stage" -type l -print -quit)" ]]; then
  echo "Staged release tree must not contain symbolic links." >&2
  exit 1
fi
if [[ ! -x "$installer" || ! -x "$network_binary" \
  || ! -f "$core_bundle/RuntimeArtifacts/NetworkUnavailableShim.c" \
  || ! -f "$cli_bundle/skills/sim-use-network/SKILL.md" \
  || ! -f "$cli_bundle/skills/sim-use-network/.sim-use-network-skill" ]]
then
  echo "Staged release artifacts have unexpected types or permissions." >&2
  exit 1
fi

for binary in "$installer" "$network_binary"; do
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

mkdir -p "$output_base"
while IFS= read -r existing; do
  name="$(basename "$existing")"
  case "$name" in
    sim-use-network-darwin-arm64.tar.gz|SHA256SUMS.txt|install.sh)
      if [[ ! -f "$existing" || -L "$existing" ]]; then
        echo "Expected release asset path is not a regular file: $existing" >&2
        exit 1
      fi
      ;;
    *)
      echo "Refusing to package into a directory containing an unexpected entry: $existing" >&2
      exit 1
      ;;
  esac
done < <(find "$output_base" -mindepth 1 -maxdepth 1 -print)

temporary_output="$(mktemp -d "${output_base%/}/.package.XXXXXX")"
cleanup() {
  if [[ -n "${temporary_output:-}" && -d "$temporary_output" ]]; then
    rm -rf -- "$temporary_output"
  fi
}
trap cleanup EXIT

archive_name="sim-use-network-darwin-arm64.tar.gz"
archive="$temporary_output/$archive_name"
installer_script="$temporary_output/install.sh"
COPYFILE_DISABLE=1 tar -C "$arm64_stage" -czf "$archive" installer payload

"$repo_root/scripts/render-install-script.sh" \
  --version "$version" \
  --repo "$release_repo" \
  --output "$installer_script"

(
  cd "$temporary_output"
  shasum -a 256 "$archive_name" install.sh > SHA256SUMS.txt
)

rm -f -- \
  "$output_base/$archive_name" \
  "$output_base/SHA256SUMS.txt" \
  "$output_base/install.sh"
install -m 644 "$archive" "$output_base/$archive_name"
install -m 644 "$temporary_output/SHA256SUMS.txt" "$output_base/SHA256SUMS.txt"
install -m 755 "$installer_script" "$output_base/install.sh"

echo "Created release archive: $output_base/$archive_name"
echo "Created checksum file: $output_base/SHA256SUMS.txt"
echo "Created install script: $output_base/install.sh"

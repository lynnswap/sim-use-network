#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/verify-release-assets.sh --version <tag> --repo <owner/repo> [--release-dir <dir>] [--archive-sha256 <sha256>]
EOF
}

version=""
release_repo=""
release_dir="release"
archive_sha256=""

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
    --release-dir)
      release_dir="${2:-}"
      shift 2
      ;;
    --archive-sha256)
      archive_sha256="${2:-}"
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
if [[ ! "$release_repo" =~ ^[0-9A-Za-z_.-]+/[0-9A-Za-z_.-]+$ ]]; then
  echo "Release repo must look like owner/repo." >&2
  exit 1
fi
if [[ -n "$archive_sha256" && ! "$archive_sha256" =~ ^[0-9A-Fa-f]{64}$ ]]; then
  echo "Archive SHA256 must be a 64-character hex digest." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$release_dir" = /* ]]; then
  release_base="$release_dir"
else
  release_base="$repo_root/$release_dir"
fi
archive_name="sim-use-network-darwin-arm64.tar.gz"
expected_assets="$(printf '%s\n' SHA256SUMS.txt install.sh "$archive_name" | LC_ALL=C sort)"

if [[ ! -d "$release_base" ]]; then
  echo "Missing release directory: $release_base" >&2
  exit 1
fi
actual_assets="$(
  find "$release_base" -mindepth 1 -maxdepth 1 -print |
    while IFS= read -r path; do basename "$path"; done |
    LC_ALL=C sort
)"
if [[ "$actual_assets" != "$expected_assets" ]]; then
  echo "Release asset set is not expected." >&2
  printf 'Expected:\n%s\n' "$expected_assets" >&2
  printf 'Actual:\n%s\n' "$actual_assets" >&2
  exit 1
fi
for asset in "$archive_name" SHA256SUMS.txt install.sh; do
  if [[ ! -f "$release_base/$asset" || -L "$release_base/$asset" ]]; then
    echo "Release asset is not a regular file: $asset" >&2
    exit 1
  fi
done

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/sim-use-network-release-verify.XXXXXX")"
cleanup() {
  rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

(
  cd "$release_base"
  shasum -a 256 "$archive_name" install.sh > "$temporary_directory/SHA256SUMS.expected"
)
if ! cmp -s "$temporary_directory/SHA256SUMS.expected" "$release_base/SHA256SUMS.txt"; then
  echo "SHA256SUMS.txt does not match the expected release assets." >&2
  diff -u "$temporary_directory/SHA256SUMS.expected" "$release_base/SHA256SUMS.txt" || true
  exit 1
fi
(
  cd "$release_base"
  shasum -a 256 -c SHA256SUMS.txt
)

if [[ -n "$archive_sha256" ]]; then
  actual_archive_sha256="$(shasum -a 256 "$release_base/$archive_name" | awk '{ print $1 }')"
  expected_archive_sha256="$(printf '%s' "$archive_sha256" | tr 'A-F' 'a-f')"
  if [[ "$actual_archive_sha256" != "$expected_archive_sha256" ]]; then
    echo "Archive SHA256 does not match the trusted build output." >&2
    echo "Expected: $expected_archive_sha256" >&2
    echo "Actual:   $actual_archive_sha256" >&2
    exit 1
  fi
fi

sh -n "$release_base/install.sh"
"$repo_root/scripts/render-install-script.sh" \
  --version "$version" \
  --repo "$release_repo" \
  --output "$temporary_directory/install.expected.sh"
if ! cmp -s "$temporary_directory/install.expected.sh" "$release_base/install.sh"; then
  echo "install.sh does not match the rendered installer for $version." >&2
  diff -u "$temporary_directory/install.expected.sh" "$release_base/install.sh" || true
  exit 1
fi

cat <<'EOF' | LC_ALL=C sort > "$temporary_directory/archive.expected"
installer/
installer/sim-use-network-install
payload/
payload/sim-use-network
payload/sim-use-network_SimUseNetworkCLI.bundle/
payload/sim-use-network_SimUseNetworkCLI.bundle/skills/
payload/sim-use-network_SimUseNetworkCLI.bundle/skills/sim-use-network/
payload/sim-use-network_SimUseNetworkCLI.bundle/skills/sim-use-network/.sim-use-network-skill
payload/sim-use-network_SimUseNetworkCLI.bundle/skills/sim-use-network/SKILL.md
payload/sim-use-network_SimUseNetworkCore.bundle/
payload/sim-use-network_SimUseNetworkCore.bundle/RuntimeArtifacts/
payload/sim-use-network_SimUseNetworkCore.bundle/RuntimeArtifacts/NetworkUnavailableShim.c
EOF
tar -tzf "$release_base/$archive_name" > "$temporary_directory/archive.unsorted"
LC_ALL=C sort "$temporary_directory/archive.unsorted" > "$temporary_directory/archive.actual"
if ! cmp -s "$temporary_directory/archive.expected" "$temporary_directory/archive.actual"; then
  echo "Release archive entries are not expected." >&2
  diff -u "$temporary_directory/archive.expected" "$temporary_directory/archive.actual" || true
  exit 1
fi

cat <<'EOF' | LC_ALL=C sort > "$temporary_directory/archive-types.expected"
d installer/
- installer/sim-use-network-install
d payload/
- payload/sim-use-network
d payload/sim-use-network_SimUseNetworkCLI.bundle/
d payload/sim-use-network_SimUseNetworkCLI.bundle/skills/
d payload/sim-use-network_SimUseNetworkCLI.bundle/skills/sim-use-network/
- payload/sim-use-network_SimUseNetworkCLI.bundle/skills/sim-use-network/.sim-use-network-skill
- payload/sim-use-network_SimUseNetworkCLI.bundle/skills/sim-use-network/SKILL.md
d payload/sim-use-network_SimUseNetworkCore.bundle/
d payload/sim-use-network_SimUseNetworkCore.bundle/RuntimeArtifacts/
- payload/sim-use-network_SimUseNetworkCore.bundle/RuntimeArtifacts/NetworkUnavailableShim.c
EOF
tar -tvzf "$release_base/$archive_name" > "$temporary_directory/archive.verbose"
if ! awk '
  {
    kind = substr($1, 1, 1)
    if (kind != "d" && kind != "-") exit 1
    print kind " " $NF
  }
' "$temporary_directory/archive.verbose" > "$temporary_directory/archive-types.unsorted"
then
  echo "Release archive contains a link or another unsupported entry type." >&2
  exit 1
fi
LC_ALL=C sort "$temporary_directory/archive-types.unsorted" \
  > "$temporary_directory/archive-types.actual"
if ! cmp -s \
  "$temporary_directory/archive-types.expected" \
  "$temporary_directory/archive-types.actual"
then
  echo "Release archive entry types are not expected." >&2
  diff -u \
    "$temporary_directory/archive-types.expected" \
    "$temporary_directory/archive-types.actual" || true
  exit 1
fi

extraction_directory="$temporary_directory/extracted"
mkdir "$extraction_directory"
tar -xzf "$release_base/$archive_name" -C "$extraction_directory"
if [[ -n "$(find "$extraction_directory" -type l -print -quit)" ]]; then
  echo "Extracted release tree must not contain symbolic links." >&2
  exit 1
fi
installer="$extraction_directory/installer/sim-use-network-install"
network_binary="$extraction_directory/payload/sim-use-network"
if [[ ! -x "$installer" || ! -x "$network_binary" ]]; then
  echo "Release archive executables are not executable." >&2
  exit 1
fi

if [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]; then
  expected_version="${version#v}"
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
fi

echo "Verified release assets for $version."

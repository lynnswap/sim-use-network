#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: scripts/validate-release-version.sh <tag>" >&2
  exit 1
fi

version="$1"
semver_pattern='^v(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)(-([0-9A-Za-z-]+)([.][0-9A-Za-z-]+)*)?(\+([0-9A-Za-z-]+)([.][0-9A-Za-z-]+)*)?$'

if [[ ! "$version" =~ $semver_pattern ]]; then
  echo "Release tag must be a SemVer 2.0.0 version with a leading v, such as v1.2.3 or v1.2.3-rc.1." >&2
  exit 1
fi

version_without_build="${version%%+*}"
if [[ "$version_without_build" == *-* ]]; then
  prerelease="${version_without_build#*-}"
  IFS='.' read -r -a identifiers <<< "$prerelease"
  for identifier in "${identifiers[@]}"; do
    if [[ "$identifier" =~ ^[0-9]+$ && "$identifier" != "0" && "$identifier" == 0* ]]; then
      echo "Numeric prerelease identifiers must not contain leading zeroes: $version" >&2
      exit 1
    fi
  done
fi

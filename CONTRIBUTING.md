# Contributing

Contributions are welcome, especially independent runtime validation and safer
cleanup verification.

## Local checks

```bash
swift build
swift test
./scripts/test-source-install.sh
./scripts/test-runtime-shim.sh
actionlint
git diff --check
```

The runtime C source must compile with warnings as errors for each Simulator SDK
present in the selected Xcode:

```bash
SOURCE=Sources/SimUseNetworkCore/Resources/RuntimeArtifacts/NetworkUnavailableShim.c

xcrun --sdk iphonesimulator clang \
  -target arm64-apple-ios26.5-simulator \
  -std=c17 -Wall -Wextra -Wpedantic -Werror \
  -fblocks -DSIM_USE_NETWORK_SHIM_ABI_VERSION=2 \
  -fsyntax-only "$SOURCE"
```

Use the equivalent `watchsimulator`, `appletvsimulator`, and `xrsimulator`
triples when those SDKs are installed.

## Runtime evidence

Do not mark a runtime validated from a successful build or dylib mapping alone.
A dedicated Simulator must demonstrate:

1. available `NWPath` and a successful HTTP request that establishes a reusable
   pooled connection;
2. unavailable `NWPath`, no reported interfaces, and an offline error when the
   same `URLSession` attempts a cache-bypassed request over that pre-established
   pool in the same app process;
3. restored path and HTTP behavior;
4. an online Mac canary in every phase;
5. cleanup leaves neither app nor daemon mapping the shim;
6. a daemon-owned/background URLSession path fails while unavailable.

Record the Xcode build, CoreSimulator build, platform, runtime version/build,
architecture, canonical daemon domain, and shim ABI. Undocumented observations
belong in the support matrix, not in comments presented as public Apple
contracts.

## Pull requests

Keep one owner boundary per pull request. Include the observed invariant,
changed owner, tests, runtime matrix impact, and cleanup evidence.

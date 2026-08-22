# sim-use-network

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![CI](https://github.com/lynnswap/sim-use-network/actions/workflows/ci.yml/badge.svg)](https://github.com/lynnswap/sim-use-network/actions/workflows/ci.yml)

An unofficial companion extension for
[sim-use](https://github.com/lycorp-jp/sim-use) that lets developers and AI
agents test an app's unavailable-network behavior on Apple Simulators while the
Mac stays online.

`sim-use-network` changes two observable layers together:

- the injected app sees no usable routed interface through `NWPath`;
- new external connections owned by that Simulator's `nsurlsessiond` fail with
  `ENETDOWN`;
- outbound I/O on covered existing external sockets is rejected instead of
  allowing a pooled HTTP connection to bypass the unavailable state.

It is an experimental development tool built on undocumented Simulator
behavior. It does not change real Wi-Fi, cellular, Bluetooth, or airplane-mode
state.

## Requirements

- an Apple Silicon Mac
- macOS 26.2 or later
- Xcode 26.4 or later with the selected Simulator SDK
- a booted Apple Simulator and an app already installed on it

See Apple's [Xcode system requirements](https://developer.apple.com/xcode/system-requirements/)
for the host OS required by a particular Xcode release.

No `sudo`, Packet Filter rule, host route change, proxy, or DNS mutation is
used. Although the prebuilt executable's deployment target is macOS 15.4,
`prepare` still needs the newer Xcode toolchain above to compile its bundled C
shim for the selected Simulator runtime.

## Install

Install the latest release under `~/.local`:

```bash
curl -fsSL https://github.com/lynnswap/sim-use-network/releases/latest/download/install.sh | sh
```

The installer publishes a command wrapper at
`~/.local/bin/sim-use-network` and keeps the executable and both required
resource bundles together under `~/.local/libexec/sim-use-network`.
Each wrapper targets one immutable payload. Older payloads are retained so a
command that was already running can continue to resolve its matching resources.

If the command directory is missing from `PATH` or another command shadows the
new install, the installer prints shell-safe commands for the current session
and, when it can identify a writable zsh or bash login profile, for future
sessions. It never edits or sources a shell profile itself.

<details>
<summary>Other install options</summary>

### Custom prefix

```bash
curl -fsSL https://github.com/lynnswap/sim-use-network/releases/latest/download/install.sh \
  | sh -s -- --prefix /path/to/prefix
```

### Specific version

```bash
curl -fsSL https://github.com/lynnswap/sim-use-network/releases/download/v0.1.0/install.sh | sh
```

### Build from source

From a `sim-use-network` checkout, build and install the command in one step:

```bash
git clone https://github.com/lynnswap/sim-use-network.git
cd sim-use-network
swift run -c release sim-use-network-install
```

Source builds require Swift 6.3. The default prefix and installed layout are the
same as for the release installer.

Use another prefix when needed:

```bash
swift run -c release sim-use-network-install --prefix /path/to/prefix
```

</details>

## Quick start

Use the same exact device UDID with both CLIs:

```bash
export SIM_USE_DEVICE=<SIMULATOR_UDID>

sim-use-network doctor
sim-use-network prepare --app com.example.MyApp

sim-use-network unavailable
sim-use ui
sim-use tap --label 'Retry'
sim-use ui

sim-use-network available
sim-use-network cleanup
```

`prepare` terminates and relaunches the installed app with the runtime shim. If
you need LLDB, attach Xcode to that relaunched process after `prepare`.

`cleanup` is mandatory and idempotent. Run it even if `available` fails. It
restores available state when possible, terminates the
tool-launched app, restarts the selected Simulator's URL loading daemon without
injection, verifies removal, and deletes the session artifacts.

## Agent skill

Install the bundled skill into Codex or Claude:

```bash
sim-use-network init --client codex
sim-use-network init --client claude
```

You can also inspect or install it somewhere else:

```bash
sim-use-network init --print
sim-use-network init --dest /path/to/skills
```

The skill composes `sim-use-network`'s network lifecycle with `sim-use`'s
observe-act-verify UI loop and makes cleanup part of the completion contract.

## Commands

```text
doctor       Resolve the exact device, runtime, daemon, and guest tools
prepare      Build a platform artifact, inject the daemon, and relaunch the app
unavailable Make fresh path evaluation and new external connections unavailable
available   Restore system behavior while keeping the prepared session loaded
status      Read live Darwin state and verify exact process mappings
cleanup     Restore, unload, verify, and remove the complete session
init        Install or print the bundled agent skill
```

Every device command accepts `--device <UDID>`. If omitted, resolution is:

1. `SIM_USE_DEVICE`;
2. the only booted, available Apple Simulator.

Multiple booted Simulators are never resolved through `booted`; the command
fails and asks for an exact UDID. All commands accept `--json`; both success and
runtime failure use compact one-line envelopes compatible with `sim-use`.

## Platform support

iOS and watchOS Simulators are supported. End-to-end behavior has been tested
on iOS 26.5/27.0 and watchOS 26.5/27.0 on Apple Silicon with Xcode 26.6. Other
Simulator runtime and Xcode versions are allowed but are not guaranteed.

The artifact compiler also builds tvOS and visionOS Simulator shims, but their
runtime behavior has not been validated. Preparing either platform requires an
explicit `--experimental-runtime` opt-in.

Each platform gets a separate Mach-O because Simulator platform identity is
encoded in `LC_BUILD_VERSION`. `doctor` reports the exact runtime, toolchain,
daemon domain, architecture, and shim ABI for diagnostics; those fields are not
a static allowlist.

## Scope

The unavailable state covers:

- fresh `NWPath` route evaluation in the injected app;
- new `connect` and `connectx` calls to non-loopback IPv4/IPv6 destinations in
  the injected app and selected Simulator's `nsurlsessiond`;
- `send`, `sendto`, `sendmsg`, `write`, and `writev` on covered external sockets,
  including an HTTP connection pooled before the state change;
- dynamic available/unavailable switching while the prepared process mappings
  remain intact.

It does not cover:

- physical devices or real radio state;
- Settings, Control Center, status-bar, or airplane-mode UI;
- `WCSession`, IDS, or companion routing;
- tearing down kernel socket state or guaranteeing already-buffered inbound data;
- protocol-level behavior for WebSockets, UDP, QUIC, or HTTP/3, which remains
  unvalidated even though covered outbound POSIX entry points are rejected;
- target-app-only transport isolation: daemon injection affects new URLSession
  connections for every app in the selected Simulator.

Use a dedicated or disposable Simulator. See [Design](Documentation/Design.md)
for owner and cleanup boundaries.

## Safety model

- A per-UDID lock prevents concurrent mutations.
- Mutation children inherit the same lease, so a killed CLI cannot race a still-
  running `simctl`/`launchctl` child against recovery.
- Recovery evidence is written before service-scoped launchd mutation.
- The daemon's canonical launchd domain is discovered from the selected device,
  not guessed from the platform name.
- Guest tools are invoked by guest `PATH`; host-absolute paths are used only for
  the per-session shim artifact.
- Both app and daemon mappings are verified before a session becomes ready.
- Each shim acknowledges successful state registration and every applied state
  generation before the CLI posts the `NWPath` refresh notification.
- A temporary launchd-owned `notifyutil` process retains each session's Darwin
  state registration across separate CLI invocations.
- A daemon restart invalidates unavailable switching instead of silently
  weakening the simulation.
- Cleanup never erases or globally shuts down Simulators.
- Cleanup stops the state keeper only after the injected app and daemon are gone.

## Acknowledgements

`sim-use-network` exists because `sim-use` made fast, agent-first Simulator
interaction practical. This project deliberately follows familiar `sim-use`
conventions such as `--device`, `SIM_USE_DEVICE`, structured JSON output, and a
bundled agent skill so network-state testing fits naturally into the same
workflow.

Thank you to [LY Corporation](https://github.com/lycorp-jp) and every
[sim-use contributor](https://github.com/lycorp-jp/sim-use/graphs/contributors)
for building and open-sourcing that foundation. `sim-use-network` is an
independent, unofficial companion project and is not affiliated with or endorsed
by LY Corporation.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Simulator/runtime findings must separate
documented behavior from observations tied to an exact Xcode and runtime build.

## License

Apache License 2.0. See [LICENSE](LICENSE).

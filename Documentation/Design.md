# Design

## Consumer stories

1. A developer prepares an installed app on one booted Apple Simulator, switches
   the app between available and unavailable network states without changing the
   Mac network, then performs an explicit cleanup.
2. An agent uses `sim-use-network` for network state and `sim-use` for the
   observe-act-verify UI loop against the same device UDID.
3. A developer runs one source-checkout command that builds the CLI, publishes
   its complete resource payload, and receives actionable PATH guidance.

The package distributes the runtime CLI and a source installer as separate
executable products. There is no public Swift library surface:
`SimUseNetworkCore` is an internal owner boundary consumed only by the runtime
CLI and its tests. `SimUseNetworkInstallCLI` has no module dependency on the
runtime targets; it asks SwiftPM to build the runtime product and installs the
resulting executable and resource bundles as one artifact set.

```text
SimUseNetworkCLI -> SimUseNetworkCore -> xcrun / simctl / launchctl
                                      -> per-platform Simulator shim

SimUseNetworkInstallCLI -> swift build --product sim-use-network
                        -> ~/.local/libexec payload + ~/.local/bin wrapper
```

The C shim is a resource, not a SwiftPM target. The host executable and a
Simulator dynamic library have different destination triples, so the CLI builds
one platform-specific artifact with the selected Xcode toolchain during
`prepare`.

## Owners

| Invariant | Owner |
| --- | --- |
| Exact booted device and runtime identity | `SimulatorDeviceResolver` |
| One active mutation at a time per UDID | `DeviceLock`, inherited by every mutation child |
| Session phase and recovery evidence | `SessionStore` |
| Platform-specific artifact | `RuntimeArtifactCompiler` |
| App path state | Shim loaded in the target app process |
| New `URLSession` connection failure | Shim loaded in that Simulator's `nsurlsessiond` |
| Available/unavailable source of truth | Session-specific Darwin notify state |
| Signal-safe process-local state | Shim dispatch callback and lock-free atomic |
| Applied-state completion | Per-process app/daemon acknowledgement keys |
| Darwin notify registration lifetime | Per-session launchd state keeper |
| Rollback and complete removal | `NetworkSessionController` |
| Source artifact set, staged activation, transaction cleanup, and PATH guidance | `SourceInstaller` |

The session journal is recovery evidence, not a second network-state source of
truth. The Darwin notification state controls the live shim behavior.

## Lifecycle

```text
absent -> staged -> keeperStarting -> keeperRunning -> daemonDebugArmed
       -> daemonInjected -> appLaunching -> ready.available
                                           <-> ready.unavailable
       -> recovering -> absent
ready.* -> cleaning -> absent
```

`prepare` compiles and signs the shim, writes recovery evidence, bootstraps a
temporary state keeper in the selected Simulator's canonical launchd domain,
injects the URL loading daemon, then launches the target app with the same shim.
A failed step rolls the state back to available, restarts the daemon without
injection, and removes the keeper. `cleanup` is the only complete close
operation: it sets available, terminates the launched app, restarts the daemon
cleanly, verifies removal, stops the keeper last, and deletes the session.
Repeating cleanup after the journal was deleted succeeds as already clean.

Every child process receives a duplicate of the per-UDID lease as standard
input. If the CLI is killed, an in-flight `simctl` or `launchctl` child therefore
keeps the lock until it exits; recovery cannot race and later re-arm injection.

Availability updates are ordered:

```text
clear app/daemon acknowledgements
-> update and post the semantic state
-> wait for both shim dispatch callbacks to cache and acknowledge it
-> post the NWI refresh notification
-> revalidate app, daemon, keeper, and notifyd identities
```

## Source installation

The installer first builds and validates all three required artifacts: the host
executable, the Core resource bundle, and the CLI resource bundle. It stages
them under one installer-owned payload directory and smoke-tests the staged
CLI before changing the active install. A prefix-local lock serializes updates.

Activation atomically publishes a regular shell wrapper at
`bin/sim-use-network`. The wrapper `exec`s one immutable payload identifier
instead of exposing the executable as a symlink because SwiftPM resolves
`Bundle.module` resources beside the invoked executable path. The candidate
wrapper is smoke-tested against the final immutable payload before one atomic
rename publishes it, so a validation failure never changes the previous command.

Old payloads are retained: a process launched by the previous wrapper can read
its bundled C source after a later installation has completed. Removing a
cohort without a process-lifetime lease would break that invariant or mix CLI
and shim generations. The one-time migration from the former bin-adjacent
layout retains those legacy bundles for the same reason.

The installer recognizes its ownership marker and the exact legacy layout
previously documented by this repository. Migrating that unmarked layout
requires the explicit `--migrate-legacy-install` authority; the default path
refuses to replace an unrelated or merely legacy-shaped command. PATH guidance
is output only: the installer never edits or sources shell profiles.

## Supported contract

- A fresh `NWPath` in the injected app reports no usable routed interface while
  unavailable.
- New external IPv4/IPv6 connections owned by the injected processes fail with
  `ENETDOWN` while unavailable.
- Covered send/write entry points reject outbound I/O on external sockets that
  were connected before the state change.
- Loopback and Unix-domain IPC remain available.
- Restoring available state delegates all intercepted calls to the system.
- The Mac network and other Simulator devices are not changed.

This does not change radio hardware, Settings or Control Center UI. It does not
cover physical devices, `WCSession`/IDS, buffered inbound data, or guarantee
protocol-level behavior for WebSockets, UDP, QUIC, or HTTP/3. The daemon-side
effect applies to every app using `nsurlsessiond` in the selected Simulator, so
a dedicated Simulator is recommended.

## Compatibility

Simulator runtime implementation is undocumented. Platform/runtime build,
architecture, Xcode build, CoreSimulator build, canonical daemon domain, and
shim ABI form one validation identity. The CLI also records launchd PID and run
generation for `notifyd` and `nsurlsessiond`.

The artifact gate requires an exact architecture slice, dylib Mach-O type,
minimum OS/platform, install name and dependency set, code signature,
version-specific ABI export, and exact `__interpose` fixups. A successful clang
exit or process mapping alone is not preparation proof. Tested identities are
documented separately from the mechanism's general architecture.

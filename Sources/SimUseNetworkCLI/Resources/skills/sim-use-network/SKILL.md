---
name: sim-use-network
description: Simulate an unavailable network for an app on an Apple Simulator, then restore and clean up the injected session. Use together with sim-use when testing offline UI, NWPath handling, retry behavior, or network error states.
---

# sim-use-network

Use `sim-use-network` for network availability and `sim-use` for UI observation
and interaction. Always pass the same exact Simulator UDID to both tools.

## Preflight

```bash
sim-use-network doctor --device <UDID>
sim-use ui --device <UDID>
```

Stop if `doctor` cannot resolve one booted Apple Simulator, its URL loading
daemon, or `notifyutil`. An unvalidated runtime requires the user's explicit
approval before adding `--experimental-runtime`.

Use a dedicated or disposable Simulator. The daemon-side shim affects covered
network I/O for every app using `nsurlsessiond` in the selected Simulator, not
only the target bundle ID. Do not prepare a shared Simulator with unrelated apps
under test.

## Prepare

```bash
sim-use-network prepare \
  --device <UDID> \
  --app <BUNDLE_ID>
```

`prepare` terminates and relaunches the installed app so the runtime shim is
present from process start. Attach Xcode to the relaunched process afterward if
a debugger is needed.

## Observe, change, verify

```bash
sim-use-network unavailable --device <UDID>
sim-use ui --device <UDID>

# Perform one UI action, then verify it through sim-use.
sim-use tap --label 'Retry' --device <UDID>
sim-use ui --device <UDID>

sim-use-network available --device <UDID>
sim-use-network status --device <UDID>
```

Treat `unavailable` as an app-observed network-path and covered transport state,
not as a real Wi-Fi switch or airplane mode. It does not cover physical devices,
radio UI, WCSession/IDS, buffered inbound data, or every protocol-specific path.

## Cleanup

Cleanup is mandatory, including after a failed test:

```bash
sim-use-network available --device <UDID>
sim-use-network cleanup --device <UDID>
```

Run `cleanup` even when `available` reports an error; cleanup owns the forced
unload path. It terminates the tool-launched app and restarts that Simulator's
`nsurlsessiond` without injection. Do not report completion until cleanup
succeeds. If cleanup reports recovery state, preserve the exact error and ask
the user before shutting down or erasing a Simulator.

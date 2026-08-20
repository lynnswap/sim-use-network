# Security

`sim-use-network` is a local development tool. Do not embed its shim in an app
archive, TestFlight build, App Store build, or physical-device product.

Please report a vulnerability privately through GitHub's security advisory
workflow for this repository. Include the affected command, platform/runtime
build, whether cleanup succeeded, and whether another Simulator or the Mac host
was affected.

The expected blast radius of a prepared session is the selected Simulator. The
`nsurlsessiond` injection can affect new URLSession connections for other apps
inside that Simulator; it must never affect host networking or a different
device UDID.

# vdisplay

A macOS virtual display CLI for Intel and Apple Silicon. It creates system display outputs that Sunshine and other applications can discover and capture natively.

The P0 foreground implementation is available: `run`, `list`, and `doctor`. It uses a small Objective-C bridge to the private `CGVirtualDisplay` API, with no external runtime dependencies. Background agents and persistent profiles are not implemented yet.

## Build

Requires macOS and an Xcode toolchain with Swift 5.9 or later. The package targets macOS 13+, but runtime validation currently covers only Apple Silicon on macOS 27.0. See [validation results](docs/validation.md).

```sh
swift build
.build/debug/vdisplay --help
```

To compile the Intel target separately:

```sh
swift build --arch x86_64 --scratch-path .build-intel
```

Cross-compilation does not establish Intel hardware compatibility.

## Use

Run as the current graphical console user, without sudo:

```sh
.build/debug/vdisplay doctor
.build/debug/vdisplay list --json
.build/debug/vdisplay run --name "Remote Display" --width 1920 --height 1080
```

`run` prints JSON after confirming the actual mode and stays in the foreground. Stop it with Ctrl-C or SIGTERM to remove its display. Adding or removing a display can cause macOS to rearrange windows.

For 4K pixels with a 1920x1080 logical desktop:

```sh
.build/debug/vdisplay run --name "Retina Remote" --width 3840 --height 2160 --scale 2 --refresh 60
```

Width and height mean output pixels. Scale is 1 or 2; dimensions must be divisible by scale. Only SDR at 60 Hz is supported in this release. The system may reject particular dimensions; the command reports an error rather than substituting another mode. Creation and removal each have a five-second confirmation deadline.

Diagnostics go to stderr; results go to stdout. Exit codes: 0 success, 2 invalid arguments, 3 missing private API, 4 unavailable graphical user session, 5 display operation or other runtime failure. With no arguments, the CLI prints help.

`list` reports system displays, modes, and names where available. Ownership is `unknown` because this phase has no shared registry. The foreground owner's readiness output marks its display as `this-process`. Display IDs and foreground serial identities are ephemeral, not persistent profile identifiers.

WindowServer manages display content. vdisplay does not implement capture buffers, encoding, or streaming, and does not manage Sunshine processes, configuration, or sessions. Choose the desired display in the consuming application. Native discovery does not automatically select it.

## Tests

Unit tests require the Xcode test tools. Process and hardware scripts also require `jq` on PATH; no dependency is installed automatically.

```sh
swift test
scripts/test-cli.sh
```

These checks do not create a display. The opt-in hardware test below temporarily creates one extended screen, checks enumeration and mode dimensions, sends SIGTERM, and verifies removal and restoration of the initial display ID list:

```sh
scripts/test-display-lifecycle.sh
scripts/test-display-lifecycle.sh .build/debug/vdisplay 3840 2160 2
```

Run hardware tests sequentially in a graphical session without other concurrent display changes. Tests can move existing windows through normal macOS layout behavior. The script only signals the owner process it starts.

## Project documentation

- [Collaboration guidelines](AGENTS.md)
- [Design and roadmap](docs/design.md)
- [Validation record and limitations](docs/validation.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)

Private APIs may change between macOS releases. The repository retains its [GPLv3 LICENSE](LICENSE).

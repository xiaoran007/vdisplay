# Development

Read [AGENTS.md](../AGENTS.md) before contributing. Project content is English. Keep changes focused and include meaningful tests for behavior and failure cases.

## Architecture

The Swift CLI uses a dedicated Objective-C bridge to the private `CGVirtualDisplay` API. There are no external runtime dependencies. WindowServer owns display content; vdisplay does not allocate capture buffers or manage Sunshine.

Each background profile has a separate owner process to avoid sharing CoreGraphics mode caches across creation cycles. launchd manages processes, while file locks serialize mutations and prevent duplicate owners. There is no socket server. Persistent configuration and worker state are separate; owner tokens bind readiness to the current process lease.

See [design and roadmap](design.md) and [third-party notices](../THIRD_PARTY_NOTICES.md) for API sources and licensing.

## Build

```sh
swift build
swift build -c release
swift build --arch x86_64 --scratch-path .build-intel
```

Cross-compilation does not establish Intel hardware compatibility. Release builds are installed locally from source; signing, notarization, binary releases, and package-manager distribution are deferred during rapid iteration.

## Tests and CI


Unit tests require the Xcode test tools. Display-enumerating process checks and hardware scripts also require `jq` on PATH; no dependency is installed automatically.

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

GitHub Actions runs unit tests, CLI checks with `--no-display`, and release builds on `macos-15` (arm64) and `macos-15-intel`. It does not create displays, install agents, or invoke the hardware lifecycle script. Profile/controller tests use temporary directories and simulated launchctl responses. The workflow will run after these commits are pushed; local checks do not constitute a hosted CI result.


For checks without graphical-session access or jq:

```sh
swift test
scripts/test-cli.sh .build/debug/vdisplay --no-display
```

Preset and configuration tests exercise parsing, overrides, strict validation, and profile expansion without creating displays. Config files are input snapshots, separate from the versioned profile store.

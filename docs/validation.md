# P0 Validation Record

Date: 2026-09-22.

## Environment

- Host architecture: arm64 (Apple Silicon).
- OS: macOS 27.0, build 26A428.
- Compiler: Apple Swift 6.4, swiftlang-6.4.0.34.1.
- Xcode developer directory: `/Applications/Xcode.app/Contents/Developer`.
- Session: logged-in graphical console user, one physical DELL S2725QS display attached.
- Physical display before and after checks: 3840x2160 pixels, 1920x1080 logical dimensions, 120 Hz.

## Completed checks

| Check | Result |
| --- | --- |
| `swift test` | Six XCTest cases passed; includes multiple malformed-input cases, pixel/logical dimension distinctions, and incorrect/unknown refresh rates |
| `scripts/test-cli.sh` | Help, exit codes, stdout/stderr separation, and JSON enumeration passed; no screen creation |
| `vdisplay doctor` | Graphical user session and required private classes/selectors available |
| 1920x1080, scale 1 | Actual logical and pixel dimensions 1920x1080 at 60 Hz; separate CLI process observed the display |
| 3840x2160, scale 2 | Actual pixel dimensions 3840x2160, logical dimensions 1920x1080 at 60 Hz; separate CLI process observed the display |
| SIGTERM cleanup for both modes | Owner exited successfully, display disappeared, original display ID list restored |
| Native arm64 debug build | Passed; Mach-O architecture arm64, minimum OS load command 13.0 |
| x86_64 debug cross-build | Passed; Mach-O architecture x86_64, minimum OS load command 13.0; not run on Intel hardware |

The x86_64 build emitted an architecture deprecation warning referring to macOS 27.0. Inspection with `vtool` confirmed the output binary's minimum OS is 13.0. This does not establish runtime support on older releases.

## Issues found and resolved during validation

Initial display creation was visible to enumeration but mode queries returned no mode. Registering CoreGraphics display notifications before creation initialized state against the old topology. Moving registration after creation, and avoiding pre-creation enumeration, made the requested mode readable on this host. The readiness loop reads actual state, so correctness does not depend on receiving the add notification.

A [separate upstream implementation](https://github.com/go-macos/virtualdisplay#what-was-measured-not-assumed) reports a related creator-process mode-cache limitation. It informed investigation only; no code or fallback behavior was imported. Our observed result is specific to the environment above.

Explicit autorelease pools in the Objective-C bridge and a global callback queue resolved the initial cleanup timeout. The final implementation releases the owned reference and checks native enumeration before reporting removal. It does not create extra displays or retry with alternative configurations.

An initial test-script attempt to validate JSON arrays with `plutil` failed. The process-level test now uses the installed `jq` and explicitly documents that test dependency.

## Not yet validated

- Intel hardware, older macOS versions, and other Apple Silicon hardware.
- Sunshine/Moonlight capture, input mapping, or streaming frame rate.
- Headless, locked, logged-out, sleep/wake, or closed-lid operation.
- SIGINT and forced termination as separate integration scenarios.
- Multiple simultaneous owned displays, persistent identity, or background agents.
- HDR, VRR, refresh rates other than 60 Hz, and resource/performance benchmarks.
- Release builds, Universal 2 packaging, signing, and notarization.

Unit tests and read-only checks run independently of display creation. Hardware integration remains an explicit script invocation and must not be treated as a headless CI test.

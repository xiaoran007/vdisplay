# Project Collaboration Guidelines

## Goals and scope

- vdisplay is a macOS virtual display CLI targeting Intel (x86_64) and Apple Silicon (arm64).
- Own display creation, configuration, lifecycle, and inspection. Sunshine and other consumers own capture, encoding, transport, and input.
- Expose displays through native macOS enumeration and capture interfaces. Do not manage Sunshine processes, configuration, or session hooks; add no Sunshine-specific commands or capture buffer allocation/transfer.
- Follow private API approaches demonstrated by established open-source projects. Isolate private APIs and record sources, revisions, and limitations.
- P0 implementation is in progress. See README.md for implemented commands and `docs/design.md` for the roadmap.

## Working practices

- All project content must be in English, including documentation, code, comments, CLI output, examples, filenames, and Git commit messages. Conversation with the user may remain in Chinese.
- Read relevant code and documentation before editing. Keep implementations simple; do not add unrequested fallback logic, silent degradation, or unrelated features.
- Request installation of missing dependencies instead of installing them without authorization or substituting a degraded implementation.
- Before using Python, check the project venv first, then Conda environments. Always ask for authorization before using system Python.
- This is a system utility, not a research project. Add meaningful automated tests for behavior and failure cases, and run relevant tests for implementation changes. Keep validation proportional; documentation-only changes do not require runtime validation.
- Provide granular progress for long operations when practical. Report actual stages when the total is unknown; do not invent percentages.
- Make small, focused Git commits. Exclude unrelated user changes; do not push or rewrite history without authorization.
- Do not use subagents unless explicitly requested by the user.

## Implementation constraints

- Prefer system frameworks and minimal dependencies. The proposed stack is a Swift CLI with an Objective-C private API bridge; follow the agreed design scope.
- Keep private declarations and OS adaptation in a dedicated module, rather than scattering private selectors and version handling through business logic.
- Report unsupported APIs, modes, or environments explicitly. Compatibility checks must not become hidden retries or alternative implementations.
- Distinguish logical dimensions, pixel dimensions, requested refresh rates, and actual output. Display creation does not establish streaming success.
- Distinguish persistent profile identity from runtime `CGDirectDisplayID`; do not promise that the latter survives restarts.
- Use stdout for results/JSON, stderr for diagnostics, and explicit command exit codes.
- Perform display operations in the user's graphical login session. Use an explicit foreground process or user LaunchAgent to own the lifecycle.
- Explain display layout effects before runtime validation. Only manipulate displays owned by this project; physical display management is outside the initial scope.
- Do not describe cross-compilation as successful Intel/Apple Silicon hardware validation. Record OS, architecture, hardware, and observed results.
- Check licenses before copying or porting code. Pin upstream commits and preserve required attribution and license text. Retain the existing GPLv3 LICENSE unless the user requests a change.

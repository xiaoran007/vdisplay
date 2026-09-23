# Command guide

Run commands as the current graphical console user, without sudo. `vdisplay --help` lists commands. With no arguments, it prints help.

## Display settings

Both `run` and `profile add ALIAS` accept the same settings:

```sh
vdisplay run PRESET [OPTIONS]
vdisplay run --config FILE [OPTIONS]
vdisplay run --size WIDTHxHEIGHT [OPTIONS]
vdisplay profile add ALIAS PRESET [OPTIONS]
```

The preset, when used, must come before options. Use `vdisplay presets` or `vdisplay presets --json` to list presets. A preset and `--config` cannot be combined.

| Option | Meaning |
| --- | --- |
| `--config FILE` | Read a JSON configuration from this path |
| `--size WIDTHxHEIGHT` | Output pixel dimensions, with a lowercase `x` |
| `--width PIXELS --height PIXELS` | Separate pixel dimensions, instead of `--size` |
| `--name NAME` | Display name; default `vdisplay` |
| `--scale 1\|2` | Pixel-to-logical scale; default `1` |
| `--refresh 60` | Refresh rate; only `60` is supported |

Explicit options override preset or file values. `--size` cannot be combined with `--width` or `--height`. Repeated options are errors. Without a preset or file, dimensions are required. With a base, either dimension may be overridden individually.

JSON files require numeric `width` and `height`. Optional keys are `name`, `scale`, and `refresh`, with the defaults above. Unknown keys, null values, and invalid configurations are rejected, even if a flag would replace the invalid field. Pixel dimensions must be positive integers divisible by scale. The system can reject a requested mode; vdisplay reports that failure.

## Foreground and inspection

`run` owns one display until Ctrl-C or SIGTERM. Readiness output reports the actual mode; creation and removal each have a five-second confirmation deadline.

```sh
vdisplay doctor
vdisplay list
vdisplay list --json
```

`doctor` checks the session and API availability. `list` shows system displays; ownership is `unknown`. Use `status PROFILE` to inspect a background profile. A runtime display ID can change across starts and is not a persistent identity.

Results go to stdout, diagnostics to stderr. Exit codes are `0` for success, `2` for invalid arguments/configuration, `3` for missing private API, `4` for unavailable graphical user session, and `5` for display operations or other runtime failures.

## Profiles and background operation

```sh
vdisplay profile add remote 4k-hidpi
vdisplay agent install
vdisplay start remote
vdisplay status remote --json
vdisplay stop remote
vdisplay profile remove remote
```

Aliases are unique ASCII identifiers. Profiles retain their UUID and serial number across starts. To change a saved configuration, stop and remove the profile, then add it again; this assigns a new identity.

`agent install` copies the current executable to a stable location. It does not start a display. `start` enables a per-profile LaunchAgent and waits for mode readiness; starting an already ready profile returns its current state. `stop` waits for removal and disables login restoration while retaining the saved profile. Both accept `--wait`, which is already the default.

Jobs do not automatically restart after crashes. Inspect status and logs, then explicitly use `start` to retry. A failed start leaves login restoration enabled; use `stop` to disable it.

## Update and uninstall

Stop every enabled profile before updating:

```sh
vdisplay stop remote
# In your source checkout:
git pull
swift build -c release
install -m 755 .build/release/vdisplay "$HOME/.local/bin/vdisplay"
vdisplay agent install
vdisplay start remote
```

Repeat stop/start for each profile. The background executable is a separate copy; rebuilding or replacing the CLI alone does not update it. For foreground use only, omit agent installation and profile commands.

To uninstall, stop all profiles, then:

```sh
vdisplay agent uninstall
rm "$HOME/.local/bin/vdisplay"
```

Agent uninstallation requires all profiles to be stopped/disabled. It preserves saved profiles and logs. Remove individual profiles with `profile remove ALIAS` before deleting the CLI if desired.

## Files and troubleshooting

Under `~/Library/Application Support/vdisplay/`:

- `profiles.json`: saved configurations; use the CLI to manage these.
- `bin/vdisplay`: background executable.
- `runtime/`: worker state and ownership locks.
- `logs/<UUID>.log`: worker output and diagnostics.

Enabled jobs are stored in `~/Library/LaunchAgents/io.vdisplay.profile.<uuid>.plist`.

If a screen does not start, run `doctor`, inspect `status PROFILE --json`, and read its log. Status checks live ownership, so an exited worker's saved display ID is not reported as ready. Private APIs can change between macOS versions; consult the [validation record](validation.md).

Successfully creating a display does not prove streaming works. Select the output in your capture application and configure that application's permissions there.

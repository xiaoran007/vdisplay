# vdisplay

Create a virtual screen on your Mac from the terminal. Use it with Sunshine or another remote desktop application that discovers macOS displays natively.

Targets Intel and Apple Silicon Macs running macOS 13 or later. Currently supports SDR at 60 Hz, including HiDPI. Compatibility depends on private macOS APIs; see the [tested configurations and limitations](docs/validation.md).

## Build and install

During early development, installation is from source only. Signed binaries, notarized installers, and Homebrew packages are not provided.

You need Git and an Xcode toolchain with Swift 5.9 or later installed on your Mac.

```sh
git clone https://github.com/xiaoran007/vdisplay.git
cd vdisplay
swift build -c release
mkdir -p "$HOME/.local/bin"
install -m 755 .build/release/vdisplay "$HOME/.local/bin/vdisplay"
export PATH="$HOME/.local/bin:$PATH"
```

Add the `export PATH` line to your shell configuration (usually `~/.zshrc`) to make it available in future terminals. The build targets your Mac's architecture.

## Create a screen

Run from your logged-in Mac desktop session, without `sudo`:

```sh
vdisplay run 1080p
```

The command prints the actual display mode as JSON when ready. Keep it running; **Ctrl-C removes the screen**. Adding or removing screens can rearrange windows.

Select the new display in Sunshine or your remote desktop application. vdisplay creates the display; capture, permissions, streaming, and input are handled by that application.

## Choose a preset

```sh
vdisplay presets
vdisplay run 4k-hidpi
```

| Preset | Output pixels | Logical desktop | Refresh |
| --- | --- | --- | --- |
| `1080p` | 1920×1080 | 1920×1080 | 60 Hz |
| `1440p` | 2560×1440 | 2560×1440 | 60 Hz |
| `4k` | 3840×2160 | 3840×2160 | 60 Hz |
| `4k-hidpi` | 3840×2160 | 1920×1080 | 60 Hz |
| `ultrawide` | 3440×1440 | 3440×1440 | 60 Hz |
| `portrait` | 1080×1920 | 1080×1920 | 60 Hz |

Presets are convenient settings, not a guarantee that every Mac or macOS release supports the mode.

## Keep a screen in the background

Save a profile, install the background executable, and start it:

```sh
vdisplay profile add remote 4k-hidpi
vdisplay agent install
vdisplay start remote
vdisplay status remote
```

The display survives closing the terminal and is recreated when you next log in to the graphical desktop. It cannot run before login or FileVault unlock. Background behavior is awaiting manual hardware validation.

```sh
vdisplay stop remote           # Remove the screen and disable login restoration
vdisplay start remote          # Enable it again
vdisplay profile list          # Show saved profiles
```

## Customize a screen

Override a preset or specify dimensions directly:

```sh
vdisplay run 4k-hidpi --name "Remote Display"
vdisplay run --size 2560x1440 --scale 1
```

For reusable settings, create a JSON file such as [examples/display.json](examples/display.json):

```json
{
  "name": "Remote Display",
  "width": 3840,
  "height": 2160,
  "scale": 2,
  "refresh": 60
}
```

```sh
vdisplay run --config display.json
vdisplay profile add remote --config display.json
```

Width and height are output pixels. Scale `2` halves the logical desktop dimensions. Explicit flags override file values. A saved profile stores a snapshot, so later file changes do not change it.

See the [command guide](docs/usage.md) for all flags, configuration rules, updating, uninstalling, and troubleshooting.

## Development

See the [development guide](docs/development.md), [design](docs/design.md), and [validation record](docs/validation.md). Contributions follow [AGENTS.md](AGENTS.md).

Licensed under [GPLv3](LICENSE). See [third-party notices](THIRD_PARTY_NOTICES.md) for private API references and attribution.

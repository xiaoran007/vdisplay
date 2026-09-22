# vdisplay

A virtual display command-line tool for Intel and Apple Silicon Macs, providing independent, configurable display outputs for Sunshine and other remote desktop software.

Status: workspace initialized and initial source research and implementation design completed. No executable has been implemented yet.

- [Project collaboration guidelines](AGENTS.md)
- [Research and implementation design](docs/design.md)

The proposed implementation uses Swift with an Objective-C bridge to the private macOS `CGVirtualDisplay` API. A persistent process in the user's session owns display lifetimes. The initial release targets SDR, 60 Hz, custom dimensions, and optional HiDPI.

Consumers discover and capture virtual displays through native macOS interfaces; the system manages display content. vdisplay does not manage Sunshine processes, configuration, or sessions, and does not implement image buffers or a streaming pipeline.

Minimum OS support, compatibility across architectures, and Sunshine interoperability remain subject to hardware validation. Commands in the design document are interface proposals.

The repository retains its existing [GPLv3 LICENSE](LICENSE).

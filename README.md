<p align="center"><img src="assets/icon.png" width="112" alt="LocalLink icon"></p>

# LocalLink

A native macOS workspace for connecting to your own Mac through Moonlight, Sunshine, and Tailscale. Independent of Parsec.

**[Download the macOS preview](https://github.com/random-guy-05/LocalLink/releases/tag/v0.3.0)** · macOS 14+ · Intel and Apple Silicon

![LocalLink connection dashboard](assets/preview.png)

## What it does

- Native SwiftUI dashboard, picture controls, connection diagnostics, setup flow, menu bar controls, and keyboard shortcuts.
- Smooth, Sharper, and Travel profiles, with configurable bitrate, resolution, frame rate, codec, frame pacing, and pointer behavior.
- VideoToolbox hardware decode availability checks and an option to require hardware decoding.
- Actual Tailscale route and round-trip measurements, bounded engine logs, diagnostic exports, and recent viewer sessions.
- Temporary SSH authentication, a verified Sunshine host installer, and a private dashboard tunnel.

Moonlight performs the streaming, decoding, and input transport. Sunshine hosts the remote desktop. LocalLink is a custom controller for those components; it does not replace their video codecs or streaming protocol.

## Install

1. Download `LocalLink-0.3.0-universal.dmg` from the release page.
2. Open the DMG and drag **LocalLink** into **Applications**.
3. Install [Moonlight](https://moonlight-stream.org/) and [Tailscale](https://tailscale.com/download/mac) separately on the viewing Mac.
4. Open LocalLink and enter your host's Tailscale IP or hostname under **Setup**.

This preview is ad-hoc signed and **not Apple-notarized**. If macOS blocks the downloaded app, follow [Apple's documented Privacy & Security → Open Anyway process](https://support.apple.com/102445). It does not require disabling Gatekeeper. A Developer ID certificate and notarization are needed for a normal verified-developer download experience.

The DMG contains LocalLink and its guide. It does not bundle Moonlight, Sunshine, Tailscale, personal host addresses, SSH keys, or account credentials.

## Set up the host

The host setup helper requires a Mac running macOS 14.2+ with Tailscale connected. Install [Sunshine](https://docs.lizardbyte.dev/projects/sunshine/latest/) on it, or use LocalLink's **Authenticate SSH → Install on mini** flow. SSH requires Remote Login enabled for the host account.

Passwords are entered privately in Terminal and are not stored by LocalLink. A temporary SSH connection expires after ten idle minutes. Host addresses, SSH trust, and the account short name are saved only in the current user's Application Support directory. Changing the configured host invalidates setup authentication for the previous host.

On the host, allow Sunshine's screen recording, audio access as requested, and Accessibility permissions. Restart Sunshine after granting permissions. Create its admin login, then use **Pair this Mac** and enter the displayed PIN on Sunshine's PIN page. The host needs to remain awake, signed in, and running Sunshine.

The fresh host configuration disables UPnP and keeps its administration page on localhost. The app can open that page through a local SSH tunnel. Existing Sunshine installations and settings are preserved.

## Performance

Smooth requests hardware decoding, V-Sync, and frame pacing at up to 60 fps. Sharper raises bitrate; Travel lowers resolution and bandwidth. Responsive mode disables V-Sync and frame pacing and can introduce tearing or uneven motion. Full-color 4:4:4 is opt-in and requires compatible hardware on both ends.

Resolution matching uses the viewer's current Retina backing canvas, which may differ from the physical panel resolution when display scaling is active. It does not resize or create the host's display. No preset guarantees native-like latency or delivered FPS on every internet connection.

The diagnostics chart reports **network round trips**, not video latency, bandwidth, or frame loss. Use Moonlight's in-stream overlay (`Control–Option–Shift–S`) for actual delivered FPS, dropped frames, and decoding time. Real host permissions, audio, input, and internet streaming still require a live test with your hardware.

Network checks run every 20 seconds only while the app is foregrounded and idle. They pause during managed viewer sessions. There are no continuous UI animation loops, and engine logs are bounded.

## Build

Requires macOS 14+ and Apple's Command Line Tools. No Node runtime or web server is used.

```sh
bash build.sh                                      # Current architecture
LOCALLINK_ARCHS="x86_64 arm64" bash build.sh         # Universal app
bash test.sh                                       # Regression and installed-engine checks
```

Build output is `dist/LocalLink.app`. The build signs locally and replaces source-path prefixes in the binary. No private host configuration is read into release resources.

To create the styled DMG:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-release.txt
DMGBUILD=.venv/bin/dmgbuild bash release.sh
```

`dist/` and `build/` are ignored by Git. The release includes SHA-256 checksums. A GitHub Actions build also compiles the universal app and runs the core regressions; it does not establish a live remote desktop session.

## Source layout

| File | Responsibility |
| --- | --- |
| `Core.swift` | Settings, migration, hardware checks, route parsing, host classification |
| `Runtime.swift` | Bounded subprocess capture, timeouts, viewer ownership, disconnect cleanup |
| `SessionModel.swift` | Session flow, diagnostics, private settings, host setup |
| `Views.swift` | Native workspace pages and pairing sheet |
| `LocalLink.swift` | App lifecycle, menu bar, keyboard shortcuts, internal UI renderer |
| `Resources/` | Generic guide and setup helpers |
| `Tests/` | Availability, validation, migration, process, and engine contract regressions |

Third-party software is installed separately and retains its own licenses: [Moonlight](https://github.com/moonlight-stream/moonlight-qt), [Sunshine](https://github.com/LizardByte/Sunshine), and [Tailscale](https://github.com/tailscale/tailscale).

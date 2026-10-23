<p align="center"><img src="assets/icon.png" width="112" alt="LocalLink icon"></p>

# LocalLink

A native remote desktop app for your own Macs. **LocalLink handles capture, video encoding and decoding, system sound, and mouse and keyboard control itself.** No Parsec, Sunshine, Moonlight, browser runtime, or streaming server application is required. Tailscale provides the private connection between your Macs.

**[Download the native engine preview](https://github.com/random-guy-05/LocalLink/releases/tag/v0.4.0)** · macOS 14+ · Intel and Apple Silicon

![LocalLink native dashboard](assets/preview.png)

Version 0.4 replaces the third-party streaming stack used by 0.3. It is an early native-engine preview, not a verified replacement for a mature remote desktop product. End-to-end streaming, permissions, audio and input on a physical host still need testing. No claim of Parsec-level latency or smoothness is made.

## Install on both Macs

1. Download `LocalLink-0.4.0-universal.dmg`, open it, and drag LocalLink to Applications on **both** Macs.
2. Keep [Tailscale](https://tailscale.com/download/mac) connected on both Macs.
3. On the host Mac, open LocalLink → **Share this Mac**. Give **LocalLink** Screen Recording (screen and system audio) and Accessibility permissions. Restart LocalLink after granting Screen Recording.
4. Click **Start sharing this Mac**, then **Copy key**. Keep the host awake, signed in, and LocalLink running. LocalLink prevents idle system sleep while sharing; it does not bypass the lock screen, FileVault login, or a closed laptop lid.
5. On the viewing Mac, enter the host’s Tailscale IP or hostname and paste its pairing key. Click **Connect to Mac**.
6. Click the picture in the remote desktop window for input. Use the toolbar for full screen; Command–Shift–D disconnects. Closing the viewer disconnects it. Stop sharing on the host to make it unavailable.

There is no Sunshine dashboard, Moonlight pairing, SSH password, or additional host service. Permissions previously given to another app do not apply to LocalLink.

This preview is ad-hoc signed and **not Apple-notarized**. If macOS blocks the downloaded app, use [Apple’s Privacy & Security → Open Anyway process](https://support.apple.com/102445). Developer ID signing and notarization remain future release work.

## Native engine

| Component | Implementation |
| --- | --- |
| Screen and system sound | Apple ScreenCaptureKit |
| H.264 / HEVC encode and decode | Apple VideoToolbox, hardware required |
| Video presentation | AVSampleBufferDisplayLayer, with a bounded latest decoded surface |
| Stereo audio | 48 kHz float PCM through AVAudioEngine; no audio driver installation |
| Mouse and keyboard | CoreGraphics events, gated by Accessibility |
| Secure transport | Apple Network.framework, TLS 1.2 PSK AES-128-GCM over TCP |
| Internet reachability | Your existing Tailscale connection; port 48100 |
| Pairing secrets | 256-bit system randomness, stored in macOS Keychain |
| Interface | SwiftUI and AppKit |

Each TLS connection authenticates the pairing key. TLS session resumption and tickets are disabled so old authenticated sessions cannot bypass a changed key. The TLS PSK identity is bound to the key. No self-signed certificate bypass, plaintext fallback, telemetry, hosted account, or public signaling service is used. This PSK suite does not provide forward secrecy by itself; Tailscale supplies an additional encrypted network layer.

The host accepts one streaming viewer at a time, caps pending handshakes, validates protocol version and stream bounds, bounds packets before allocation, releases pressed keys on disconnection/focus loss, and stops capture when the viewer leaves. Treat the pairing key as remote-control access: anyone with it can connect while sharing is on. **New pairing key** revokes the old key. The host listener can bind to interfaces beyond Tailscale; restrict port 48100 with your firewall if required. Do not forward it publicly.

## Picture and performance

- **Smooth:** up to 2560 × 1600, 60 fps, 28 Mbps.
- **Sharper:** up to 3840 × 2160, 60 fps, 50 Mbps.
- **Travel:** up to 1920 × 1080, 60 fps, 10 Mbps.
- HEVC is the default. Switch it off for hardware H.264 compatibility.
- Host display proportions are preserved. These are requested upper bounds, not guaranteed delivered frame rates or resolutions. No virtual display is created.
- The host skips raw capture frames before encoding when transmission is busy; the viewer can replace decoded surfaces awaiting presentation. Compressed inter-frame references are not discarded.
- The toolbar measures decoded surfaces passed to the renderer, encoded video throughput and connection round trips. The FPS count is not a display scanout measurement; RTT is not click-to-photon latency. Audio bandwidth is additional (about 3.1 Mbps of uncompressed stereo).

Current limits: one display (the first capture display), one viewer, SDR 8-bit 4:2:0, no clipboard/file transfer, no HDR/4:4:4, no multi-monitor selector, and no automatic launch or reconnection. TCP can stall on packet loss; adaptive bitrate and a datagram transport remain future work. Audio uses a small bounded buffer without adaptive A/V clock synchronization. The app cannot promise a near-native experience on every internet connection.

## Build and verify

Requires Apple Command Line Tools on macOS 14+. No third-party runtime, package manager or dependency download is needed to build the app.

```sh
bash build.sh
LOCALLINK_ARCHS="x86_64 arm64" bash build.sh
bash test.sh
```

`dist/LocalLink.app` is the universal app. Tests check encrypted loopback traffic, wrong-key rejection, binary and stream bounds, and synthetic hardware H.264/HEVC video round trips. Synthetic tests never capture the screen or inject input. GitHub CI compiles both architectures and runs the transport tests; its virtual machine skips hardware codec tests. Neither replaces a two-Mac session test.

To package the optional styled DMG (packaging-only Python dependency):

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-release.txt
DMGBUILD=.venv/bin/dmgbuild bash release.sh
```

The release includes a SHA-256 checksum. Personal addresses, pairing keys and local settings are never bundled.

## Source

`Native/Transport.swift` defines the secure channel and bounded protocol. `Video.swift` captures, encodes and decodes video. `Audio.swift` carries native stereo sound. `Control.swift` renders surfaces and handles input. `Model.swift` owns sessions, host lifecycle, permissions and Keychain. `App.swift` contains the native interface. Earlier streaming integrations remain available in Git history at tag `v0.3.0`.

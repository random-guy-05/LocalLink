# Changelog

## 0.5.2

- Both windows use a standard macOS title bar. The green button toggles native full screen instead of zooming; Control–Command–F and the toolbar do the same.
- Viewer-only change; a 0.5.1 host does not need updating.

## 0.5.1

- The legacy `CGPreflightScreenCaptureAccess` check no longer blocks the host from starting. ScreenCaptureKit enforces permission, and **This Mac → Test screen access** checks it directly.
- Without Accessibility, the host offers a labelled view-only stream; input still requires permission.
- A real capture denial reaches the viewer and stops retries with the actual error, instead of reconnecting forever.

Ad-hoc signed updates change the identity macOS uses for privacy permissions. If capture is denied after an update, remove LocalLink's old entries from **Screen & System Audio Recording** and **Accessibility**, add the current `/Applications/LocalLink.app`, and reopen it. Your pairing key is unchanged.

## 0.5

- Redesigned workspace, native full screen, higher-quality profiles (including Studio, which needs a 0.5 host) and persistent connections.
- Connection health uses authenticated ping/pong, so a static desktop stays connected.
- The last session and sharing state restore on launch, and **Experience → Open at login** is available.
- Update both Macs. Existing keys carry over; if macOS asks for Keychain access after updating, allow it.

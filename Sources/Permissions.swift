import Foundation
import ScreenCaptureKit
import AppKit

enum HostPermissions {
    struct Snapshot { var screen: Bool; var input: Bool }
    static func snapshot() -> Snapshot { Snapshot(screen: CGPreflightScreenCaptureAccess(), input: AXIsProcessTrusted()) }
    static func message(for error: Error) -> String {
        let value = error as NSError
        if value.domain == SCStreamErrorDomain && value.code == -3801 {
            return "macOS denied Screen Recording to this running LocalLink build. On the host: quit LocalLink, remove its old entry from Privacy & Security → Screen & System Audio Recording, then add /Applications/LocalLink.app again and reopen it. Existing permission entries can refer to an older build after an update. Your pairing key is unchanged."
        }
        return "Screen capture could not start: \(value.localizedDescription) (\(value.domain), \(value.code)). Check the host’s LocalLink window for details."
    }
}

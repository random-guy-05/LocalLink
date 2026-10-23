import SwiftUI
import AppKit

@MainActor enum NativeWindowControls {
    static func configure(_ window: NSWindow) {
        window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
        window.styleMask.remove(.fullSizeContentView)
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.collectionBehavior.subtract([.fullScreenAuxiliary, .fullScreenNone])
        window.collectionBehavior.insert(.fullScreenPrimary)
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = false
        }
        // The green traffic light enters a native fullscreen Space instead of zooming.
        if let green = window.standardWindowButton(.zoomButton) {
            green.target = window
            green.action = #selector(NSWindow.toggleFullScreen(_:))
            green.isEnabled = true
        }
    }
}

private final class StandardWindowHook: NSView {
    private weak var configuredWindow: NSWindow?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, configuredWindow !== window else { return }
        configuredWindow = window
        NativeWindowControls.configure(window)
    }
}

struct StandardWindowBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { StandardWindowHook() }
    func updateNSView(_ view: NSView, context: Context) {}
}

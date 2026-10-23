import SwiftUI
import AppKit

@MainActor final class ViewerWindowState: ObservableObject {
    @Published var fullscreen = false
    weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var entered = false
    func attach(_ window: NSWindow, model: NativeModel) {
        guard self.window !== window else { return }
        self.window = window
        window.title = "\(model.computerName) — LocalLink"
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.backgroundColor = .black
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in Task { @MainActor in self?.fullscreen = true } })
        observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in Task { @MainActor in self?.fullscreen = false } })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak model] _ in Task { @MainActor in model?.closeViewerWindow() } })
        if model.autoFullscreen, !entered {
            entered = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak window, weak model] in
                guard let window, window.isVisible, model?.wantsConnection == true, !window.styleMask.contains(.fullScreen) else { return }
                window.toggleFullScreen(nil)
            }
        }
    }
    func toggle() { window?.toggleFullScreen(nil) }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}

private final class WindowHook: NSView {
    var attach: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { attach?(window) } }
}
struct ViewerWindowBridge: NSViewRepresentable {
    @ObservedObject var state: ViewerWindowState
    let model: NativeModel
    func makeNSView(context: Context) -> NSView {
        let view = WindowHook(); view.attach = { [weak state, weak model] window in if let model { state?.attach(window, model: model) } }; return view
    }
    func updateNSView(_ view: NSView, context: Context) { if let window = view.window { state.attach(window, model: model) } }
}

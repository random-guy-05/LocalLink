import AppKit
import SwiftUI
import Combine
import AVFoundation

/// Monterey predates SwiftUI's openWindow and MenuBarExtra APIs. Keep the same
/// workspace and viewer views, with AppKit owning their windows and menus.
@MainActor final class LegacyApplication: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let model: NativeModel
    private var windows: [String: NSWindow] = [:]
    private var statusItem: NSStatusItem?
    private var connectionObserver: AnyCancellable?

    init(model: NativeModel) { self.model = model; super.init() }

    static func run() {
        let app = NSApplication.shared
        let delegate = LegacyApplication(model: NativeModel())
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.connected.to.line.below", accessibilityDescription: "LocalLink")
        let tray = NSMenu()
        add("Open LocalLink", action: #selector(showWorkspace), to: tray)
        add("Open desktop", action: #selector(showDesktop), to: tray)
        tray.addItem(.separator())
        add("Stop sharing this Mac", action: #selector(stopSharing), to: tray)
        add("Quit LocalLink", action: #selector(quit), to: tray)
        item.menu = tray; statusItem = item
        connectionObserver = model.$wantsConnection.removeDuplicates().sink { [weak self] wanted in
            guard wanted else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.model.wantsConnection else { return }
                self.openWindow(id: "remote")
            }
        }
        openWindow(id: "workspace")
        model.startLifecycle()
    }

    func openWindow(id: String, show: Bool = true) {
        guard id == "workspace" || id == "remote" else { return }
        let window: NSWindow
        if let existing = windows[id] { window = existing }
        else {
            let remote = id == "remote"
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: remote ? 1440 : 1100, height: remote ? 900 : 790), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = remote ? "Remote Mac" : "LocalLink"
            window.contentMinSize = remote ? NSSize(width: 640, height: 400) : NSSize(width: 980, height: 720)
            let action = LocalWindowAction { [weak self] in self?.openWindow(id: $0) }
            if remote {
                window.contentView = NSHostingView(rootView: NativeViewer(model: model).environment(\.localWindowAction, action))
            } else {
                window.contentView = NSHostingView(rootView: NativeHome(model: model).environment(\.localWindowAction, action))
            }
            NativeWindowControls.configure(window)
            window.center()
            windows[id] = window
        }
        if show {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func add(_ title: String, action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; item.keyEquivalentModifierMask = modifiers; menu.addItem(item)
    }
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = app; main.addItem(appItem)
        add("About LocalLink", action: #selector(about), to: app)
        app.addItem(.separator()); add("Quit LocalLink", action: #selector(quit), key: "q", to: app)
        let edit = NSMenu(title: "Edit"); let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); editItem.submenu = edit; main.addItem(editItem)
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        let connection = NSMenu(title: "Connection"); let connectionItem = NSMenuItem(title: "Connection", action: nil, keyEquivalent: ""); connectionItem.submenu = connection; main.addItem(connectionItem)
        add("Connect", action: #selector(connect), key: "\r", to: connection)
        add("Disconnect", action: #selector(disconnect), key: "d", modifiers: [.command, .shift], to: connection)
        add("Toggle full screen", action: #selector(fullscreen), key: "f", modifiers: [.command, .control], to: connection)
        add("Release keyboard & pointer", action: #selector(releaseInput), key: "\u{1b}", modifiers: [.command, .control, .option], to: connection)
        connection.addItem(.separator()); add("Stop sharing this Mac", action: #selector(stopSharing), to: connection)
        let window = NSMenu(title: "Window"); let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: ""); windowItem.submenu = window; main.addItem(windowItem)
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        add("LocalLink workspace", action: #selector(showWorkspace), to: window)
        add("Remote desktop", action: #selector(showDesktop), to: window)
        NSApp.windowsMenu = window
        return main
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(connect): return !model.wantsConnection
        case #selector(disconnect), #selector(showDesktop): return model.wantsConnection
        case #selector(stopSharing): return model.hosting
        case #selector(fullscreen): return NSApp.keyWindow != nil
        default: return true
        }
    }
    @objc private func connect() { model.connect() }
    @objc private func disconnect() { model.disconnect() }
    @objc private func releaseInput() { model.toggleInput() }
    @objc private func stopSharing() { model.stopHosting() }
    @objc private func fullscreen() { NSApp.keyWindow?.toggleFullScreen(nil) }
    @objc private func showWorkspace() { openWindow(id: "workspace") }
    @objc private func showDesktop() { openWindow(id: "remote") }
    @objc private func about() { NSApp.orderFrontStandardAboutPanel(nil) }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { openWindow(id: "workspace") }; return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { model.prepareForTermination(); return .terminateNow }
    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }

    static func smokeTest() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let model = NativeModel(preview: true)
        let controller = LegacyApplication(model: model)
        app.mainMenu = controller.makeMainMenu()
        for id in ["workspace", "remote"] {
            controller.openWindow(id: id, show: false)
            let window = controller.windows[id]!
            precondition(window.contentView != nil && window.styleMask.contains([.titled, .closable, .miniaturizable, .resizable]))
            precondition(window.collectionBehavior.contains(.fullScreenPrimary))
            precondition(window.standardWindowButton(.zoomButton)?.action == #selector(NSWindow.toggleFullScreen(_:)))
            let original = window
            window.close(); controller.openWindow(id: id, show: false)
            precondition(controller.windows[id] === original)
        }
        precondition(app.mainMenu?.items.contains { $0.title == "Connection" } == true)
        let canvas = NativeVideoView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        var pixels: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        precondition(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &pixels) == kCVReturnSuccess)
        let buffer = pixels!
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), plane == 0 ? 16 : 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        precondition(canvas.display.isReadyForMoreMediaData)
        canvas.present(buffer)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        precondition(canvas.display.status != .failed, canvas.display.error?.localizedDescription ?? "Video presentation failed")
        canvas.clearDisplay()
        model.shutdown()
        print("PASS: Monterey window routing, close/reopen, native controls and Connection menu; no connection, capture, input injection or Keychain writes")
        print("PASS: synthetic frame enqueue and clear using \(RuntimeCompatibility.legacyAPIs ? "legacy" : "current") display APIs (not a test on an older operating system)")
    }
}

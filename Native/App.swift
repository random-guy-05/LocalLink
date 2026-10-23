import SwiftUI
import AppKit

let accent = Color(red: 0.65, green: 0.59, blue: 1)
let ink = Color(red: 0.075, green: 0.078, blue: 0.10)
let muted = Color.white.opacity(0.48)

@MainActor final class NativeDelegate: NSObject, NSApplicationDelegate {
    weak var model: NativeModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { model?.prepareForTermination(); return .terminateNow }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

struct LocalLinkNativeApp: App {
    @NSApplicationDelegateAdaptor(NativeDelegate.self) var delegate
    @StateObject private var model = NativeModel()
    var body: some Scene {
        WindowGroup("LocalLink", id: "workspace") {
            NativeHome(model: model).onAppear { delegate.model = model; model.startLifecycle() }
        }.defaultSize(width: 1100, height: 790).windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Connection") {
                Button("Connect") { model.connect() }.keyboardShortcut(.return, modifiers: .command).disabled(model.wantsConnection)
                Button("Disconnect") { model.disconnect() }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(!model.wantsConnection)
                Button("Toggle full screen") { NSApp.keyWindow?.toggleFullScreen(nil) }.keyboardShortcut("f", modifiers: [.command, .control])
                Button("Release keyboard & pointer") { model.toggleInput() }.keyboardShortcut(.escape, modifiers: [.command, .option, .control])
                Divider()
                Button("Stop sharing this Mac") { model.stopHosting() }.disabled(!model.hosting)
            }
        }
        Window("Remote Mac", id: "remote") { NativeViewer(model: model) }.defaultSize(width: 1440, height: 900).windowStyle(.hiddenTitleBar)
        MenuBarExtra("LocalLink", systemImage: "rectangle.connected.to.line.below") { NativeTray(model: model) }
    }
}

@main enum NativeMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--engine-info") {
            print("LocalLink 0.5.1 native preview\nCapture: ScreenCaptureKit\nVideo: VideoToolbox hardware H.264 / HEVC\nSound: ScreenCaptureKit + AVAudioEngine\nInput: CoreGraphics\nNetwork: Network.framework TLS 1.2 PSK AES-128-GCM, port 48100\nExternal streaming applications: none")
            return
        }
        if let index = args.firstIndex(of: "--render-preview"), index + 1 < args.count {
            let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.appearance = NSAppearance(named: .darkAqua)
            let model = NativeModel(preview: true); model.host = "your-mini.example.ts.net"; model.viewerKey = "preview"; model.screenAllowed = false; model.inputAllowed = false
            if args.contains("--host-page") { model.page = .host }
            if args.contains("--experience-page") { model.page = .picture }
            let view = NSHostingView(rootView: NativeHome(model: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 790), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view; window.orderFront(nil)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
                do { try data.write(to: URL(fileURLWithPath: args[index + 1])); exit(0) } catch { exit(1) }
            }
            app.run(); return
        }
        LocalLinkNativeApp.main()
    }
}

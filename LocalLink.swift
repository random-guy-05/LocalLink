import SwiftUI
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: SessionModel?
    func applicationDidFinishLaunching(_ notification: Notification) { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
    func applicationWillTerminate(_ notification: Notification) { model?.disconnect() }
}

struct LocalLinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = SessionModel()
    var body: some Scene {
        WindowGroup("LocalLink", id: "workspace") {
            ContentView(model: model).onAppear { delegate.model = model }
        }
        .defaultSize(width: 1120, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Connection") {
                Button("Open my Mac") { model.connect() }.keyboardShortcut(.return, modifiers: .command).disabled(!model.canConnect)
                Button("Check connection") { Task { await model.refresh() } }.keyboardShortcut("r").disabled(model.busy || model.checking)
                Button("Disconnect viewer") { model.disconnect() }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(model.phase != .session)
                Divider()
                Button("Pair this Mac") { model.pair() }.disabled(!model.canConnect)
            }
            CommandMenu("Navigate") {
                ForEach(Array(AppPage.allCases.enumerated()), id: \.element.id) { index, page in
                    Button(page.title) { model.page = page }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
            }
        }
        MenuBarExtra("LocalLink", systemImage: "rectangle.connected.to.line.below") { TrayMenu(model: model) }
    }
}

struct TrayMenu: View {
    @ObservedObject var model: SessionModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Mac mini · \(model.displayStatus)")
        Divider()
        if model.phase == .session {
            Button("Return to viewer") { model.showViewer() }
            Button("Disconnect") { model.disconnect() }
        } else {
            Button("Open my Mac") { model.connect() }.disabled(!model.canConnect)
            Button("Check connection") { Task { await model.refresh() } }.disabled(model.checking || model.busy)
        }
        Divider()
        Button("Open LocalLink") { openWindow(id: "workspace"); NSApplication.shared.activate(ignoringOtherApps: true) }
        Button("Quit LocalLink") { NSApplication.shared.terminate(nil) }
    }
}

@main enum LocalLinkMain {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--hardware-info") {
            let value = ViewerHardware.current()
            print("Canvas: \(value.caption)\nH.264 hardware decode: \(value.h264)\nHEVC hardware decode: \(value.hevc)")
            return
        }
        if let index = arguments.firstIndex(of: "--print-arguments"), index + 1 < arguments.count {
            var settings = StreamSettings()
            settings.apply(Profile(rawValue: arguments[index + 1]) ?? .smooth, hardware: .current())
            if let json = try? JSONEncoder().encode(settings.arguments) { print(String(decoding: json, as: UTF8.self)) }
            return
        }
        if let index = arguments.firstIndex(of: "--render-preview"), index + 1 < arguments.count {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.appearance = NSAppearance(named: .darkAqua)
            let model = SessionModel(preview: true)
            if let pageIndex = arguments.firstIndex(of: "--page"), pageIndex + 1 < arguments.count { model.page = AppPage(rawValue: arguments[pageIndex + 1]) ?? .connect }
            let view = NSHostingView(rootView: ContentView(model: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view; window.orderFront(nil)
            Task { @MainActor in
                if arguments.contains("--live") { await model.refresh(allowPreview: true) }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
                do { try data.write(to: URL(fileURLWithPath: arguments[index + 1])); print("Rendered interface preview."); exit(0) }
                catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            }
            application.run()
            return
        }
        LocalLinkApp.main()
    }
}

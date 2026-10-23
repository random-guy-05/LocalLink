import SwiftUI
import AppKit

private let accent = Color(red: 0.36, green: 0.88, blue: 0.74)
private let ink = Color(red: 0.055, green: 0.066, blue: 0.085)

@MainActor final class NativeDelegate: NSObject, NSApplicationDelegate {
    weak var model: NativeModel?
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.appearance = NSAppearance(named: .darkAqua) }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

struct LocalLinkNativeApp: App {
    @NSApplicationDelegateAdaptor(NativeDelegate.self) var delegate
    @StateObject private var model = NativeModel()
    var body: some Scene {
        WindowGroup("LocalLink", id: "workspace") {
            NativeHome(model: model).onAppear { delegate.model = model }
        }.defaultSize(width: 1080, height: 760).windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Connection") {
                Button("Connect") { model.connect() }.keyboardShortcut(.return, modifiers: .command).disabled(model.connected || model.connecting)
                Button("Disconnect") { model.disconnect() }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(!model.connected && !model.connecting)
                Divider()
                Button("Stop sharing this Mac") { model.stopHosting() }.disabled(!model.hosting)
            }
        }
        Window("Remote Mac", id: "remote") { NativeViewer(model: model) }.defaultSize(width: 1280, height: 800)
        MenuBarExtra("LocalLink", systemImage: "rectangle.connected.to.line.below") {
            Text(model.hosting ? model.hostStatus : "LocalLink · native preview")
            Button("Disconnect viewer") { model.disconnect() }.disabled(!model.connected && !model.connecting)
            Button("Stop sharing") { model.stopHosting() }.disabled(!model.hosting)
            Divider()
            Button("Quit LocalLink") { NSApp.terminate(nil) }
        }
    }
}

@main enum NativeMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--engine-info") {
            print("LocalLink 0.4.1 native preview\nCapture: ScreenCaptureKit\nVideo: VideoToolbox hardware H.264 / HEVC\nSound: ScreenCaptureKit + AVAudioEngine\nInput: CoreGraphics\nNetwork: Network.framework TLS 1.2 PSK AES-128-GCM, port 48100\nExternal streaming applications: none")
            return
        }
        if let index = args.firstIndex(of: "--render-preview"), index + 1 < args.count {
            let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.appearance = NSAppearance(named: .darkAqua)
            let model = NativeModel(preview: true); model.host = "your-mini.example.ts.net"; model.screenAllowed = false; model.inputAllowed = false
            if args.contains("--host-page") { model.page = .host }
            let view = NSHostingView(rootView: NativeHome(model: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
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

struct NativeHome: View {
    @ObservedObject var model: NativeModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 12) {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage()).resizable().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) { Text("LocalLink").font(.system(size: 21, weight: .semibold)); Text("YOUR MAC, WITH YOU").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.3).foregroundStyle(.secondary) }
                }.padding(.top, 30)
                VStack(spacing: 8) {
                    ForEach(NativePage.allCases, id: \.self) { page in
                        Button { model.page = page } label: {
                            HStack(spacing: 11) {
                                Image(systemName: page == .connect ? "rectangle.connected.to.line.below" : page == .host ? "display.and.arrow.down" : "slider.horizontal.3").frame(width: 20)
                                Text(page.rawValue).font(.system(size: 13, weight: .medium)); Spacer()
                            }.padding(13).background(model.page == page ? accent.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(model.page == page ? accent : .secondary)
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 9) {
                    Label("Native engine", systemImage: "cpu").font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
                    Text("Capture, video, sound and control built into LocalLink.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                    Text("0.4.1 · PREVIEW").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).padding(.top, 5)
                }.padding(15).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            }.padding(22).frame(width: 240).background(.black.opacity(0.22))
            Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text("WORKSPACE / \(model.page.rawValue.uppercased())").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.4).foregroundStyle(.secondary)
                        Spacer()
                        Label("Encrypted · direct", systemImage: "lock.shield").font(.system(size: 11)).foregroundStyle(accent)
                    }
                    if let error = model.error {
                        HStack(alignment: .top) { Image(systemName: "exclamationmark.circle"); Text(error).textSelection(.enabled); Spacer(); Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.font(.system(size: 12)).foregroundStyle(Color.orange).padding(15).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    switch model.page {
                    case .connect: connect
                    case .host: hosting
                    case .picture: picture
                    }
                }.padding(36)
            }
        }.frame(minWidth: 920, minHeight: 680).background(ink).preferredColorScheme(.dark)
        .onChange(of: model.connected) { _, connected in if connected { openWindow(id: "remote") } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
    }
    private var connect: some View {
        VStack(alignment: .leading, spacing: 25) {
            title("Your other Mac.\nRight here.", subtitle: "A private connection, with a native engine on both ends.")
            VStack(alignment: .leading, spacing: 20) {
                HStack { Label("REMOTE MAC", systemImage: "desktopcomputer").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(accent); Spacer(); Text("PORT 48100").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) }
                field("Tailscale IP or hostname") { TextField("Host address", text: $model.host).textFieldStyle(.roundedBorder).disabled(model.connecting || model.connected) }
                field("Pairing key from the host Mac") { SecureField("Paste the key from Share this Mac", text: $model.viewerKey).textFieldStyle(.roundedBorder).disabled(model.connecting || model.connected) }
                HStack(spacing: 12) {
                    if model.connected {
                        Button { openWindow(id: "remote") } label: { Label("Open remote desktop", systemImage: "arrow.up.right.square").frame(height: 30) }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                        Button("Disconnect") { model.disconnect() }
                    } else if model.connecting {
                        ProgressView().controlSize(.small); Text(model.status).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer(); Button("Cancel") { model.disconnect() }
                    } else {
                        Button { model.connect() } label: { HStack { Text("Connect to Mac"); Image(systemName: "arrow.right") }.fontWeight(.semibold).frame(height: 30).padding(.horizontal, 13) }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black).disabled(!model.hostValid || model.viewerKey.isEmpty)
                        Text("⌘ Return").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
            }.padding(24).panel()
            HStack(alignment: .top, spacing: 14) { Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(accent); Text("Keep Tailscale connected on both Macs. Open this same LocalLink app on your mini, choose Share this Mac, and copy its pairing key here.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5) }.padding(20).panel()
            Text("NATIVE ENGINE PREVIEW · End-to-end performance on your mini still needs testing.").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
        }
    }
    private var hosting: some View {
        VStack(alignment: .leading, spacing: 24) {
            title("Make this Mac\navailable to you.", subtitle: "Run this on your Mac mini. Keep LocalLink open while sharing.")
            VStack(alignment: .leading, spacing: 16) {
                Text("MACOS PERMISSIONS").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.2).foregroundStyle(.secondary)
                permission("Screen Recording", detail: "Stream your display and system sound.", allowed: model.screenAllowed, action: model.screenPermission)
                Divider().overlay(.white.opacity(0.04))
                permission("Accessibility", detail: "Receive your mouse and keyboard input.", allowed: model.inputAllowed, action: model.inputPermission)
                Text("Enable LocalLink in both panels. After granting Screen Recording, quit and reopen LocalLink.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(22).panel()
            VStack(alignment: .leading, spacing: 16) {
                HStack { Circle().fill(model.hosting ? accent : .gray).frame(width: 7, height: 7); Text(model.hostStatus).font(.system(size: 13, weight: .medium)); Spacer() }
                if !model.hostKey.isEmpty {
                    HStack {
                        Group { if model.showKey { Text(model.hostKey).textSelection(.enabled) } else { Text("•••• •••• •••• •••• •••• ••••") } }.font(.system(size: 11, design: .monospaced)).lineLimit(2)
                        Spacer()
                        Button { model.showKey.toggle() } label: { Image(systemName: model.showKey ? "eye.slash" : "eye") }
                        Button("Copy key") { model.copy(model.hostKey) }
                    }.padding(12).background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    if model.hosting { Button("Stop sharing") { model.stopHosting() }.buttonStyle(.borderedProminent).tint(.red) }
                    else { Button("Start sharing this Mac") { model.startHosting() }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black) }
                    Spacer()
                    Button("New pairing key") { model.rotateKey() }.disabled(model.hosting)
                }
                Text("Anyone with this key can connect while sharing is on. A new key revokes the old one. Keys stay in this Mac’s Keychain.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(22).panel()
        }
    }
    private var picture: some View {
        VStack(alignment: .leading, spacing: 24) {
            title("Clear picture.\nRoom to move.", subtitle: "Hardware encoding and decoding. Up to 60 frames per second.")
            VStack(spacing: 12) {
                ForEach(PicturePreset.allCases, id: \.self) { preset in
                    Button { model.preset = preset } label: {
                        HStack(spacing: 15) {
                            Image(systemName: preset == .smooth ? "water.waves" : preset == .sharp ? "sparkles.rectangle.stack" : "airplane").font(.system(size: 22)).frame(width: 34).foregroundStyle(accent)
                            VStack(alignment: .leading, spacing: 5) { Text(preset.rawValue).font(.system(size: 15, weight: .semibold)); Text(preset == .smooth ? "Up to 2560 × 1600 · 60 fps · 28 Mbps" : preset == .sharp ? "Up to 3840 × 2160 · 60 fps · 50 Mbps" : "Up to 1920 × 1080 · 60 fps · 10 Mbps").font(.system(size: 11)).foregroundStyle(.secondary) }
                            Spacer(); Image(systemName: model.preset == preset ? "checkmark.circle.fill" : "circle").foregroundStyle(model.preset == preset ? accent : .gray)
                        }.padding(20).panel(selected: model.preset == preset)
                    }.buttonStyle(.plain)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                Toggle("HEVC · efficient high-quality video", isOn: $model.hevc)
                Text("Turn off to use H.264 if a Mac does not support hardware HEVC.").font(.system(size: 11)).foregroundStyle(.secondary)
                Divider()
                Toggle("Stream system audio", isOn: $model.audio)
                Text("Native stereo audio capture. The host needs screen and system audio permission.").font(.system(size: 11)).foregroundStyle(.secondary)
            }.font(.system(size: 13)).toggleStyle(.switch).tint(accent).padding(22).panel()
            Text("Changes apply on the next connection. The host display’s proportions are preserved. Actual video FPS, bitrate, and connection round-trip time appear in the viewer.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(5)
        }.disabled(model.connected || model.connecting)
    }
    private func title(_ text: String, subtitle: String) -> some View { VStack(alignment: .leading, spacing: 14) { Text(text).font(.system(size: 40, weight: .semibold)).tracking(-1.5).fixedSize(horizontal: false, vertical: true); Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4) }.padding(.bottom, 4) }
    private func field<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View { VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary); content().controlSize(.large) } }
    private func permission(_ title: String, detail: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) { Image(systemName: allowed ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(allowed ? accent : .orange); VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 13, weight: .medium)); Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }; Spacer(); Button(allowed ? "Settings" : "Allow…", action: action) }
    }
}

private extension View {
    func panel(selected: Bool = false) -> some View { background(selected ? accent.opacity(0.06) : .white.opacity(0.025), in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(selected ? accent.opacity(0.5) : .white.opacity(0.07))) }
}

struct NativeViewer: View {
    @ObservedObject var model: NativeModel
    @Environment(\.dismissWindow) var dismissWindow
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Circle().fill(model.connected ? accent : .gray).frame(width: 7, height: 7)
                Text(model.connected ? "\(model.resolution) · \(model.codec)" : "Disconnected").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(model.fps) fps").monospacedDigit()
                Text(String(format: "%.1f Mbps", model.bitrate)).monospacedDigit()
                Text(model.rtt.map { String(format: "%.0f ms RTT", $0) } ?? "— ms RTT").monospacedDigit()
                Button("Full screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                Button("Disconnect") { model.disconnect(); dismissWindow(id: "remote") }
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(12).background(ink)
            RemoteCanvas(presenter: model.presenter, input: model.send, release: model.releaseInput).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack { Text("Click the picture to control your Mac."); Spacer(); Text("⌘ ⇧ D disconnects") }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 7).background(ink)
        }.background(.black).preferredColorScheme(.dark).onDisappear { model.disconnect() }
    }
}

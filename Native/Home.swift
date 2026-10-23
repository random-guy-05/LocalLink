import SwiftUI
import AppKit

struct NativeTray: View {
    @ObservedObject var model: NativeModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text(model.connected ? "\(model.computerName) · connected" : model.status)
        Button("Open LocalLink") { openWindow(id: "workspace"); NSApp.activate(ignoringOtherApps: true) }
        if model.wantsConnection { Button("Open desktop") { openWindow(id: "remote") }; Button("Disconnect") { model.disconnect() } }
        Divider(); Text(model.hostStatus)
        if model.hosting { Button("Stop sharing this Mac") { model.stopHosting() } }
        Divider(); Button("Quit LocalLink") { NSApp.terminate(nil) }
    }
}

struct NativeHome: View {
    @ObservedObject var model: NativeModel
    @Environment(\.openWindow) var openWindow
    @State private var editing = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(.white.opacity(0.065)).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(model.page.rawValue).font(.system(size: 27, weight: .semibold)).tracking(-0.6)
                            Text(subtitle).font(.system(size: 12)).foregroundStyle(muted)
                        }
                        Spacer()
                        if model.page == .connect { Button { editing = true } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.bordered).help("Connection settings") }
                    }.padding(.bottom, 4)
                    if let error = model.error { errorBanner(error) }
                    switch model.page { case .connect: computers; case .host: sharing; case .picture: experience }
                }.padding(32)
            }
        }.frame(minWidth: 980, minHeight: 720).background(ink).preferredColorScheme(.dark).tint(accent)
        .sheet(isPresented: $editing) { editor }
        .onChange(of: model.wantsConnection) { _, wanted in if wanted { openWindow(id: "remote") } }
        .onAppear { if model.wantsConnection { openWindow(id: "remote") } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
    }
    private var subtitle: String { switch model.page { case .connect: return "Your desktop, wherever you settle in."; case .host: return "Make this Mac available to your other devices."; case .picture: return "Make the connection feel like your own desktop." } }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) { Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage()).resizable().frame(width: 35, height: 35); Text("LocalLink").font(.system(size: 18, weight: .semibold)).tracking(-0.5) }.padding(.top, 34).padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 6) {
                Text("WORKSPACE").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.tertiary).padding(.horizontal, 14).padding(.bottom, 7)
                nav(.connect, "desktopcomputer"); nav(.host, "antenna.radiowaves.left.and.right"); nav(.picture, "slider.horizontal.3")
            }
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) { Circle().fill(model.hosting ? Color.green : Color.gray).frame(width: 6, height: 6); Text(model.hosting ? "This Mac is available" : "Sharing is off").font(.system(size: 11)) }.foregroundStyle(.secondary)
                Divider()
                HStack { Text("Native for macOS"); Spacer(); Text("0.5") }.font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(13)
        }.padding(14).frame(width: 198).background(.white.opacity(0.018))
    }
    private func nav(_ page: NativePage, _ icon: String) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.15)) { model.page = page } } label: {
            HStack(spacing: 11) { Image(systemName: icon).frame(width: 19); Text(page.rawValue).font(.system(size: 12, weight: .medium)); Spacer() }.foregroundStyle(model.page == page ? Color.white : muted).padding(.horizontal, 13).padding(.vertical, 12).background(model.page == page ? accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
    private var computers: some View {
        VStack(alignment: .leading, spacing: 21) {
            VStack(spacing: 0) {
                HStack(spacing: 30) {
                    DesktopArtwork().frame(width: 245, height: 178)
                    VStack(alignment: .leading, spacing: 14) {
                        StatusPill(text: model.connected ? "Connected" : model.reconnecting ? "Reconnecting" : model.viewerKey.isEmpty ? "Set up connection" : "Saved computer", active: model.connected)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(model.computerName).font(.system(size: 27, weight: .semibold)).tracking(-0.7)
                            Text(model.host.isEmpty ? "Add your Mac’s Tailscale address" : model.host).font(.system(size: 11, design: .monospaced)).foregroundStyle(muted).textSelection(.enabled)
                        }
                        connectionButton
                    }
                    Spacer(minLength: 0)
                }.padding(27)
                Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
                HStack(spacing: 0) { detail("display", "Picture", model.preset.rawValue); detail("arrow.triangle.2.circlepath", "Connection", model.autoReconnect ? "Always reconnect" : "Manual"); detail("speaker.wave.2", "Sound", model.audio ? "Stereo audio" : "Off") }.padding(.vertical, 18).padding(.horizontal, 24)
            }.surface()
            if model.connected { connectionSummary }
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.shield").font(.system(size: 18)).foregroundStyle(accent).padding(.top, 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.viewerKey.isEmpty ? "Connect your Mac once. Keep it close." : "Ready for the next time.").font(.system(size: 13, weight: .medium))
                    Text(model.viewerKey.isEmpty ? "Install LocalLink on the other Mac, open This Mac, and copy its pairing key. Tailscale connects your two computers." : "Your key stays in Keychain. Network interruptions reconnect automatically, and an idle desktop stays connected.").font(.system(size: 12)).foregroundStyle(muted).lineSpacing(4)
                }; Spacer(minLength: 5)
            }.padding(20).surface()
            HStack(spacing: 18) { Label("Encrypted end to end", systemImage: "lock.fill"); Label("Hardware video", systemImage: "cpu"); Label("Native streaming engine", systemImage: "app.connected.to.app.below.fill") }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 3)
        }
    }
    @ViewBuilder private var connectionButton: some View {
        if model.wantsConnection {
            HStack(spacing: 12) { Button { openWindow(id: "remote") } label: { Label(model.connected ? "Open desktop" : "View connection", systemImage: "arrow.up.right").padding(.horizontal, 5).padding(.vertical, 3) }.buttonStyle(.borderedProminent); Button { model.disconnect() } label: { Image(systemName: "stop.fill") }.help("Disconnect") }
        } else {
            Button { if model.viewerKey.isEmpty { editing = true } else { model.connect() } } label: { HStack(spacing: 15) { Text(model.viewerKey.isEmpty ? "Set up Mac" : "Connect"); Image(systemName: "arrow.right") }.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 13).padding(.vertical, 5) }.buttonStyle(.borderedProminent)
        }
    }
    private func detail(_ symbol: String, _ label: String, _ value: String) -> some View { HStack(spacing: 10) { Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(muted); VStack(alignment: .leading, spacing: 4) { Text(label).font(.system(size: 10)).foregroundStyle(muted); Text(value).font(.system(size: 11, weight: .medium)) }; Spacer(minLength: 8) }.frame(maxWidth: .infinity, alignment: .leading) }
    private var connectionSummary: some View { HStack { metric("Video", "\(model.fps) fps"); metric("Resolution", model.resolution); metric("Network RTT", model.rtt.map { String(format: "%.0f ms", $0) } ?? "—"); metric("Video bitrate", String(format: "%.1f Mbps", model.bitrate)) }.padding(20).surface() }
    private func metric(_ label: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 7) { Text(label).font(.system(size: 10)).foregroundStyle(muted); Text(value).font(.system(size: 15, weight: .medium, design: .rounded)).monospacedDigit() }.frame(maxWidth: .infinity, alignment: .leading) }
    private var sharing: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) {
                Image(systemName: "macmini").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(accent).frame(width: 74)
                VStack(alignment: .leading, spacing: 7) { Text(model.hostConnected ? "You’re connected to this Mac." : model.hosting ? "Available when you need it." : "Your Mac, ready to go.").font(.system(size: 20, weight: .medium)); Text(model.hostStatus).font(.system(size: 11)).foregroundStyle(muted) }; Spacer()
                if model.hosting { Button("Stop sharing") { model.stopHosting() } } else { Button("Start sharing") { model.startHosting() }.buttonStyle(.borderedProminent) }
            }.padding(24).surface()
            VStack(alignment: .leading, spacing: 18) {
                section("ACCESS")
                permission("Screen & system audio", "Capture your desktop and sound.", "rectangle.inset.filled", model.screenAllowed, model.screenPermission)
                Divider()
                permission("Accessibility", "Control your mouse and keyboard.", "cursorarrow", model.inputAllowed, model.inputPermission)
                Text("Enable LocalLink in both panels. Quit and reopen after granting screen recording.").font(.system(size: 11)).foregroundStyle(muted)
            }.padding(22).surface()
            VStack(alignment: .leading, spacing: 16) {
                HStack { section("PAIRING KEY"); Spacer(); Text("Saved in Keychain").font(.system(size: 10)).foregroundStyle(muted) }
                if model.hostKey.isEmpty { Text("A private key is created when you start sharing.").font(.system(size: 12)).foregroundStyle(muted) }
                else { HStack { Text(model.showKey ? model.hostKey : "•••• •••• •••• •••• •••• ••••").font(.system(size: 12, design: .monospaced)).textSelection(.enabled); Spacer(); Button { model.showKey.toggle() } label: { Image(systemName: model.showKey ? "eye.slash" : "eye") }; Button("Copy key") { model.copy(model.hostKey) } } }
                HStack { Text("Disconnecting keeps this key. Only “New key” replaces it.").font(.system(size: 11)).foregroundStyle(muted); Spacer(); Button("New key") { model.rotateKey() }.disabled(model.hosting) }
            }.padding(22).surface()
            Text("Sharing resumes when LocalLink reopens. Enable Open at login in Experience to make this Mac available after you sign in.").font(.system(size: 11)).foregroundStyle(muted).lineSpacing(4)
        }
    }
    private var experience: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 15) {
                HStack { section("PICTURE QUALITY"); Spacer(); Text("60 fps target").font(.system(size: 10)).foregroundStyle(muted) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) { ForEach(PicturePreset.allCases, id: \.self) { quality($0) } }
                HStack { Text("Capture real display pixels without upscaling. Studio needs the updated host and hardware capable of the requested resolution.").font(.system(size: 11)).foregroundStyle(muted).lineSpacing(4); if model.connected { Button("Apply to session") { model.applyPicture() }.buttonStyle(.borderedProminent) } }
            }.padding(22).surface()
            VStack(spacing: 0) {
                setting("HEVC video", "More detail at the same bandwidth", "film", $model.hevc); Divider().padding(.leading, 50)
                setting("System audio", "Stream sound from your other Mac", "speaker.wave.2", $model.audio); Divider().padding(.leading, 50)
                setting("Open in full screen", "A dedicated macOS Space, edge to edge", "arrow.up.left.and.arrow.down.right", $model.autoFullscreen); Divider().padding(.leading, 50)
                setting("Reconnect automatically", "Resume after network changes and sleep", "arrow.triangle.2.circlepath", $model.autoReconnect); Divider().padding(.leading, 50)
                setting("Open at login", model.loginApprovalNeeded ? "Approval needed in Login Items" : "Restore sharing and your last active connection", "power", Binding(get: { model.loginEnabled }, set: model.setLogin))
            }.surface()
            Text("Picture changes apply on the next connection, or use Apply to session. Higher quality uses more bandwidth; available display pixels and hardware set the upper limit.").font(.system(size: 11)).foregroundStyle(muted).lineSpacing(4)
        }
    }
    private func quality(_ profile: PicturePreset) -> some View {
        Button { model.preset = profile } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: profile.symbol).font(.system(size: 18)).foregroundStyle(model.preset == profile ? accent : muted).frame(width: 24).padding(.top, 2)
                VStack(alignment: .leading, spacing: 7) { Text(profile.rawValue).font(.system(size: 13, weight: .semibold)); Text(profile.subtitle).font(.system(size: 10)).foregroundStyle(muted).lineSpacing(3).multilineTextAlignment(.leading) }
                Spacer(minLength: 0); Image(systemName: model.preset == profile ? "checkmark.circle.fill" : "circle").font(.system(size: 13)).foregroundStyle(model.preset == profile ? accent : Color.white.opacity(0.15))
            }.padding(15).frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading).background(model.preset == profile ? accent.opacity(0.085) : .white.opacity(0.015), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(model.preset == profile ? accent.opacity(0.6) : .white.opacity(0.07)))
        }.buttonStyle(.plain)
    }
    private func setting(_ title: String, _ subtitle: String, _ symbol: String, _ value: Binding<Bool>) -> some View { HStack(spacing: 14) { Image(systemName: symbol).foregroundStyle(muted).frame(width: 20); VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 12, weight: .medium)); Text(subtitle).font(.system(size: 10)).foregroundStyle(muted) }; Spacer(); Toggle("", isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small) }.padding(17) }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Connection settings").font(.system(size: 20, weight: .semibold)); Spacer(); Button("Done") { editing = false }.keyboardShortcut(.defaultAction) }
            Form { TextField("Name", text: $model.computerName); TextField("Tailscale address", text: $model.host).disabled(model.wantsConnection); SecureField("Pairing key", text: $model.viewerKey).disabled(model.wantsConnection) }.textFieldStyle(.roundedBorder)
            Text("Copy the key from LocalLink → This Mac on the host. Disconnecting never rotates it.").font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(28).frame(width: 480).preferredColorScheme(.dark)
    }
    private func permission(_ title: String, _ detail: String, _ symbol: String, _ allowed: Bool, _ action: @escaping () -> Void) -> some View { HStack(spacing: 13) { Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(muted).frame(width: 22); VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 12, weight: .medium)); Text(detail).font(.system(size: 10)).foregroundStyle(muted) }; Spacer(); if allowed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 15)) }; Button(allowed ? "Settings" : "Allow…", action: action) } }
    private func section(_ text: String) -> some View { Text(text).font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(muted) }
    private func errorBanner(_ text: String) -> some View { HStack(alignment: .top, spacing: 10) { Image(systemName: "exclamationmark.circle"); Text(text).textSelection(.enabled); Spacer(); Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.font(.system(size: 11)).foregroundStyle(.orange).padding(15).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10)) }
}

struct StatusPill: View {
    var text: String; var active = false
    var body: some View { HStack(spacing: 6) { Circle().fill(active ? .green : accent).frame(width: 5, height: 5); Text(text).font(.system(size: 10, weight: .medium)) }.foregroundStyle(active ? Color.green : accent).padding(.horizontal, 9).padding(.vertical, 5).background((active ? Color.green : accent).opacity(0.1), in: Capsule()) }
}
extension View { func surface() -> some View { background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.075))) } }
struct DesktopArtwork: View {
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.17, green: 0.16, blue: 0.24))
                LinearGradient(colors: [Color(red: 0.24, green: 0.20, blue: 0.48), Color(red: 0.46, green: 0.34, blue: 0.59), Color(red: 0.16, green: 0.34, blue: 0.43)], startPoint: .topLeading, endPoint: .bottomTrailing).padding(5).clipShape(RoundedRectangle(cornerRadius: 10))
                Circle().fill(.white.opacity(0.045)).frame(width: 155).offset(x: 70, y: 45)
                Circle().strokeBorder(.white.opacity(0.07), lineWidth: 30).frame(width: 170).offset(x: -50, y: -48)
                Image(systemName: "macmini").font(.system(size: 37, weight: .ultraLight)).foregroundStyle(.white.opacity(0.7))
            }.frame(height: 142).clipped().overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15)))
            Rectangle().fill(LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom)).frame(width: 31, height: 18)
            Capsule().fill(.white.opacity(0.10)).frame(width: 79, height: 4)
        }.shadow(color: .black.opacity(0.3), radius: 15, y: 8).accessibilityHidden(true)
    }
}

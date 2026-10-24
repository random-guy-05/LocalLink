import SwiftUI

struct NativeViewer: View {
    @ObservedObject var model: NativeModel
    @StateObject private var windowState = ViewerWindowState()
    @Environment(\.localWindowAction) var openWindow
    @State private var controls = true
    @State private var hovering = false
    @State private var hideTask: Task<Void, Never>?
    var body: some View {
        ZStack(alignment: .top) {
            RemoteCanvas(presenter: model.presenter, scale: model.scale, inputEnabled: model.connected && model.captureInput && model.remoteControlAvailable, hideCursor: !hovering && model.captureInput && model.remoteControlAvailable, input: model.send, release: model.releaseInput, releaseShortcut: model.toggleInput).frame(maxWidth: .infinity, maxHeight: .infinity)
            if controls || hovering || !model.captureInput || !model.connected { toolbar.padding(.top, 12).transition(.opacity.combined(with: .move(edge: .top))).zIndex(3) }
            if !model.connected { connectionOverlay.zIndex(2) }
            if model.connected && !model.remoteControlAvailable {
                VStack { Spacer(); Label("View only — enable LocalLink in Accessibility on the host Mac. If already enabled, remove the old entry, add the installed app again, and reopen it.", systemImage: "cursorarrow.slash").font(.system(size: 11)).foregroundStyle(.orange).padding(14).frame(maxWidth: 620).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(18) }.allowsHitTesting(false)
            }
            if model.showStats && model.connected {
                VStack { Spacer(); HStack { Text("\(model.resolution)  ·  \(model.codec)  ·  \(model.fps) fps  ·  \(String(format: "%.1f", model.bitrate)) Mbps  ·  \(model.rtt.map { String(format: "%.0f ms RTT", $0) } ?? "— ms RTT")").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.7)).padding(10).background(.ultraThinMaterial, in: Capsule()); Spacer() }.padding(16) }.allowsHitTesting(false)
            }
            VStack { Color.clear.frame(height: 10).contentShape(Rectangle()).onHover { inside in if inside { reveal() } }; Spacer() }
        }.background(.black).ignoresSafeArea().preferredColorScheme(.dark)
        .background(ViewerWindowBridge(state: windowState, model: model).frame(width: 0, height: 0))
        .onAppear { reveal() }
        .onChange(of: model.connected) { _ in reveal() }
        .onChange(of: model.captureInput) { _ in reveal() }
    }
    private var toolbar: some View {
        HStack(spacing: 13) {
            HStack(spacing: 7) { Circle().fill(model.connected ? Color.green : Color.orange).frame(width: 6, height: 6); Text(model.computerName).font(.system(size: 11, weight: .medium)); if model.connected && !model.remoteControlAvailable { Text("View only").font(.system(size: 10)).foregroundStyle(.orange) } }.padding(.leading, 4)
            Divider().frame(height: 19)
            Menu { ForEach(DesktopScale.allCases, id: \.self) { scale in Button { model.scale = scale } label: { if model.scale == scale { Label(scale.rawValue, systemImage: "checkmark") } else { Text(scale.rawValue) } } } } label: { Label(model.scale.rawValue, systemImage: "rectangle.arrowtriangle.2.outward") }.menuStyle(.borderlessButton).fixedSize().help("Desktop scaling")
            Button { model.showStats.toggle() } label: { Image(systemName: "waveform.path.ecg") }.help("Connection statistics")
            Button { model.toggleInput() } label: { Image(systemName: model.captureInput ? "cursorarrow" : "cursorarrow.slash") }.help("Release keyboard and pointer · ⌃⌥⌘ Esc")
            Button { openWindow(id: "workspace"); NSApp.activate(ignoringOtherApps: true) } label: { Image(systemName: "sidebar.left") }.help("LocalLink workspace")
            Button { windowState.toggle() } label: { Image(systemName: windowState.fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }.help("Toggle full screen · ⌃⌘ F")
            Divider().frame(height: 19)
            Button { model.disconnect() } label: { Image(systemName: "power").foregroundStyle(.red.opacity(0.9)) }.help("Disconnect · ⌘⇧ D")
        }.font(.system(size: 12)).buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.13))).shadow(color: .black.opacity(0.3), radius: 20, y: 5)
            .onHover { inside in hovering = inside; if inside { hideTask?.cancel() } else { reveal() } }
    }
    private var connectionOverlay: some View {
        VStack(spacing: 17) {
            if model.wantsConnection { ProgressView().controlSize(.large) } else { Image(systemName: "desktopcomputer").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary) }
            Text(model.error != nil && !model.wantsConnection ? "Host needs attention" : model.wantsConnection ? "Connecting to your Mac…" : "Session ended").font(.system(size: 21, weight: .medium))
            Text(model.wantsConnection ? "Your connection will resume automatically." : "Your pairing key is saved. Connect again whenever you’re ready.").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                if model.wantsConnection { Button("Try now") { model.retryNow() }.disabled(model.connecting); Button("Disconnect") { model.disconnect() } }
                else { Button("Reconnect") { model.connect() }.buttonStyle(.borderedProminent).tint(accent); Button("Open LocalLink") { openWindow(id: "workspace") } }
            }.padding(.top, 4)
            if let error = model.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled).frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true) }
            else if let reason = model.reconnectReason, model.wantsConnection { Text(reason).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true) }
        }.padding(32).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20)).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func reveal() {
        hideTask?.cancel(); withAnimation(.easeOut(duration: 0.2)) { controls = true }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled, !hovering else { return }
            withAnimation(.easeOut(duration: 0.25)) { controls = false }
        }
    }
}

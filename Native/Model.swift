import AppKit
import SwiftUI
import Network
import Security

enum SecretStore {
    private static func query(_ account: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.locallink.native", kSecAttrAccount as String: account] }
    static func read(_ account: String) -> String? {
        var query = query(account); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ value: String, account: String) throws {
        let search = query(account), data = Data(value.utf8)
        let status = SecItemUpdate(search as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = search; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw LinkError.message("Could not save the pairing key in Keychain (\(added)).") }
        } else if status != errSecSuccess { throw LinkError.message("Could not update the pairing key in Keychain (\(status)).") }
    }
}

enum NativePage: String, CaseIterable { case connect = "Connect", host = "Share this Mac", picture = "Picture & sound" }
enum PicturePreset: String, CaseIterable { case smooth = "Smooth", sharp = "Sharper", travel = "Travel" }

@MainActor final class NativeModel: ObservableObject {
    @Published var page: NativePage = .connect
    @Published var host = "" { didSet { guard !preview else { return }; UserDefaults.standard.set(host, forKey: "nativeHost"); viewerKey = SecretStore.read("viewer:\(host)") ?? "" } }
    @Published var viewerKey = ""
    @Published var hostKey = ""
    @Published var showKey = false
    @Published var preset: PicturePreset = .smooth
    @Published var hevc = true
    @Published var audio = true
    @Published var status = "Ready when you are"
    @Published var hostStatus = "Sharing is off"
    @Published var error: String?
    @Published var connected = false
    @Published var connecting = false
    @Published var hosting = false
    @Published var hostConnected = false
    @Published var screenAllowed = false
    @Published var inputAllowed = false
    @Published var fps = 0
    @Published var bitrate = 0.0
    @Published var rtt: Double?
    @Published var resolution = "—"
    @Published var codec = "—"
    let presenter = VideoPresenter()
    let port: UInt16 = 48100
    private var viewer: LinkChannel?
    private var decoder: NativeDecoder?
    private var audioPlayer: NativeAudioPlayer?
    private var listener: NWListener?
    private var hostChannels: [UUID: LinkChannel] = [:]
    private var activeHost: UUID?
    private var capture: NativeCapture?
    private let injector = InputInjector()
    private var captureStart: Task<Void, Never>?
    private var timer: Timer?
    private var frames = 0
    private var bytes = 0
    private var lastStats = ProcessInfo.processInfo.systemUptime
    private var lastFrame = ProcessInfo.processInfo.systemUptime
    private var sentPing: Data?
    private var pingTime = ProcessInfo.processInfo.systemUptime
    private var sessionID = UUID()
    private var sleepAssertion: IOPMAssertionID = 0
    private let preview: Bool

    init(preview: Bool = false) {
        self.preview = preview
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LocalLink/host")
        host = UserDefaults.standard.string(forKey: "nativeHost") ?? ((try? String(contentsOf: support, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        if !preview {
            viewerKey = SecretStore.read("viewer:\(host)") ?? ""
            hostKey = SecretStore.read("host") ?? ""
        }
        refreshPermissions()
        presenter.onPresented = { [weak self] in self?.frames += 1; self?.lastFrame = ProcessInfo.processInfo.systemUptime }
        if !preview { timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } } }
    }
    var request: StreamRequest {
        switch preset {
        case .smooth: return StreamRequest(width: 2560, height: 1600, fps: 60, mbps: 28, hevc: hevc, audio: audio)
        case .sharp: return StreamRequest(width: 3840, height: 2160, fps: 60, mbps: 50, hevc: hevc, audio: audio)
        case .travel: return StreamRequest(width: 1920, height: 1080, fps: 60, mbps: 10, hevc: hevc, audio: audio)
        }
    }
    var hostValid: Bool { !host.isEmpty && host.count < 254 && host.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:-").contains($0) } }
    func refreshPermissions() { screenAllowed = CGPreflightScreenCaptureAccess(); inputAllowed = AXIsProcessTrusted() }
    func screenPermission() { _ = CGRequestScreenCaptureAccess(); NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!); refreshPermissions() }
    func inputPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        refreshPermissions()
    }
    func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    func rotateKey() {
        stopHosting()
        do { let key = try PairingKey.generate(); try SecretStore.write(key, account: "host"); hostKey = key; showKey = true }
        catch { self.error = error.localizedDescription }
    }
    func connect() {
        guard !connected, !connecting, hostValid else { error = "Enter the host Mac’s Tailscale IP or hostname."; return }
        do {
            let key = try PairingKey.decode(viewerKey)
            try SecretStore.write(viewerKey.trimmingCharacters(in: .whitespacesAndNewlines), account: "viewer:\(host)")
            let id = UUID(); sessionID = id
            let channel = LinkChannel(host: host, port: port, key: key)
            let decoder = NativeDecoder(), player = NativeAudioPlayer()
            presenter.begin()
            self.decoder = decoder; audioPlayer = player; viewer = channel
            decoder.onPixels = { [weak presenter] pixels in presenter?.present(pixels) }
            connecting = true; status = "Authenticating securely…"; error = nil
            let request = self.request
            channel.onReady = { [weak self, weak channel] in
                channel?.sendJSON(.hello, request)
                Task { @MainActor in guard self?.sessionID == id else { return }; self?.status = "Starting the host display…" }
            }
            channel.onPacket = { [weak self, weak channel] packet in
                do {
                    switch packet.kind {
                    case .video:
                        try decoder.decode(packet.body)
                        Task { @MainActor in guard let self, self.sessionID == id else { return }; self.bytes += packet.body.count }
                    case .audio: try player.play(packet.body)
                    case .status:
                        guard let status = try? JSONDecoder().decode(HostStatus.self, from: packet.body) else { return }
                        Task { @MainActor in
                            guard let self, self.sessionID == id else { return }
                            if status.width == 0 { self.error = status.text; self.disconnect(); return }
                            self.connecting = false; self.connected = true; self.status = status.text
                            self.resolution = "\(status.width) × \(status.height)"; self.codec = status.codec
                            self.lastFrame = ProcessInfo.processInfo.systemUptime
                        }
                    case .ping: channel?.send(.pong, packet.body)
                    case .pong: Task { @MainActor in guard let self, self.sessionID == id, self.sentPing == packet.body else { return }; self.rtt = (ProcessInfo.processInfo.systemUptime - self.pingTime) * 1000; self.sentPing = nil }
                    default: break
                    }
                } catch { Task { @MainActor in guard self?.sessionID == id else { return }; self?.error = error.localizedDescription; self?.disconnect() } }
            }
            channel.onClose = { [weak self] reason in Task { @MainActor in guard self?.sessionID == id else { return }; self?.disconnect(); self?.error = reason } }
            channel.start()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard let self, self.sessionID == id, self.connecting else { return }
                self.error = "The host did not start a stream. Check LocalLink’s permissions on the host Mac."
                self.disconnect()
            }
        } catch { self.error = error.localizedDescription }
    }
    func send(_ input: RemoteInput) { guard connected else { return }; viewer?.sendJSON(.input, input) }
    func releaseInput() { viewer?.send(.releaseKeys) }
    func disconnect() {
        sessionID = UUID(); connected = false; connecting = false
        let channel = viewer
        channel?.send(.releaseKeys); channel?.cancel(); viewer = nil
        let decoder = self.decoder, player = audioPlayer
        self.decoder = nil; audioPlayer = nil
        // Teardown follows the last decode/play call on the same serial queue.
        channel?.queue.async { decoder?.stop(); player?.stop() }
        presenter.clear(); status = "Ready when you are"; frames = 0; fps = 0; bytes = 0; bitrate = 0; rtt = nil; sentPing = nil
    }
    func startHosting() {
        guard !hosting else { return }
        refreshPermissions()
        guard screenAllowed else { error = "Give LocalLink Screen Recording permission on this Mac, then quit and reopen LocalLink."; return }
        guard inputAllowed else { error = "Give LocalLink Accessibility permission on this Mac to enable remote control."; return }
        if hostKey.isEmpty { rotateKey() }
        do {
            let key = try PairingKey.decode(hostKey)
            let listener = try NWListener(using: LinkTLS.parameters(key: key), on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener; hosting = true; hostStatus = "Starting secure listener…"; error = nil
            listener.newConnectionHandler = { [weak self, weak listener] connection in Task { @MainActor in
                guard let self, self.listener === listener else { connection.cancel(); return }
                self.accept(connection)
            } }
            listener.stateUpdateHandler = { [weak self] state in Task { @MainActor in
                guard self?.listener === listener else { return }
                switch state { case .ready: self?.hostStatus = "Waiting for your other Mac · port \(self?.port ?? 48100)"; case .failed(let error): self?.error = error.localizedDescription; self?.stopHosting(); default: break }
            } }
            listener.start(queue: DispatchQueue(label: "LocalLink.host-listener"))
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "LocalLink host is available" as CFString, &sleepAssertion)
        } catch { self.error = error.localizedDescription; stopHosting() }
    }
    private func accept(_ connection: NWConnection) {
        guard hosting, hostChannels.count < 4 else { connection.cancel(); return }
        let id = UUID(), channel = LinkChannel(connection)
        hostChannels[id] = channel
        channel.onPacket = { [weak self, weak channel] packet in
            if packet.kind == .ping { channel?.send(.pong, packet.body); return }
            Task { @MainActor in
                guard let self, self.hostChannels[id] != nil else { return }
                switch packet.kind {
                case .hello:
                    guard self.activeHost == nil, let channel, let request = try? JSONDecoder().decode(StreamRequest.self, from: packet.body), request.valid else { channel?.cancel(); return }
                    self.activeHost = id; self.beginCapture(request, channel: channel, id: id)
                case .input:
                    guard self.activeHost == id, self.hostConnected, let input = try? JSONDecoder().decode(RemoteInput.self, from: packet.body) else { return }
                    self.injector.apply(input)
                case .releaseKeys: if self.activeHost == id { self.injector.releaseAll() }
                default: break
                }
            }
        }
        channel.onClose = { [weak self] _ in Task { @MainActor in self?.removeHost(id) } }
        channel.start()
        Task { @MainActor [weak self, weak channel] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if self?.activeHost != id { channel?.cancel() }
        }
    }
    private func beginCapture(_ request: StreamRequest, channel: LinkChannel, id: UUID) {
        let capture = NativeCapture(); self.capture = capture
        hostStatus = "Starting screen capture…"
        capture.onFailure = { [weak self] reason in Task { @MainActor in
            guard let self, self.activeHost == id else { return }
            self.error = reason; channel.sendJSON(.status, HostStatus(text: reason, width: 0, height: 0, codec: "")); self.removeHost(id)
        } }
        captureStart = Task { @MainActor [weak self] in
            do {
                let status = try await capture.start(request: request, channel: channel)
                guard let self, self.activeHost == id, !Task.isCancelled else { await capture.stop(); return }
                self.injector.bounds = capture.displayBounds
                self.hostConnected = true; self.hostStatus = "Your other Mac is connected · \(status.codec)"
                channel.sendJSON(.status, status)
            } catch {
                guard let self, self.activeHost == id else { await capture.stop(); return }
                self.error = error.localizedDescription
                channel.sendJSON(.status, HostStatus(text: error.localizedDescription, width: 0, height: 0, codec: ""))
                self.removeHost(id)
            }
        }
    }
    private func removeHost(_ id: UUID) {
        hostChannels.removeValue(forKey: id)?.cancel()
        guard activeHost == id else { return }
        activeHost = nil; hostConnected = false; injector.releaseAll(); captureStart?.cancel(); captureStart = nil
        if let capture { Task { await capture.stop() } }; capture = nil
        hostStatus = hosting ? "Waiting for your other Mac · port \(port)" : "Sharing is off"
    }
    func stopHosting() {
        listener?.newConnectionHandler = nil; listener?.stateUpdateHandler = nil
        listener?.cancel(); listener = nil; hosting = false
        for id in Array(hostChannels.keys) { removeHost(id) }
        injector.releaseAll(); hostConnected = false; hostStatus = "Sharing is off"
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }
    }
    private func tick() {
        refreshPermissions()
        let now = ProcessInfo.processInfo.systemUptime, elapsed = now - lastStats
        fps = Int((Double(frames) / max(0.1, elapsed)).rounded()); bitrate = Double(bytes) * 8 / max(0.1, elapsed) / 1_000_000
        frames = 0; bytes = 0; lastStats = now
        if connected {
            if sentPing == nil { let nonce = Data(UUID().uuidString.utf8); sentPing = nonce; pingTime = now; viewer?.send(.ping, nonce) }
            if now - lastFrame > 12 { error = "The host stopped delivering video. Reconnect after checking the host display and permissions."; disconnect() }
        }
    }
    func shutdown() { disconnect(); stopHosting(); timer?.invalidate() }
}

import IOKit.pwr_mgt

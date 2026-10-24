import AppKit
import SwiftUI
import Network
import Security
import ServiceManagement
import ScreenCaptureKit

enum SecretStore {
    private static func query(_ account: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.locallink.native", kSecAttrAccount as String: account] }
    static func read(_ account: String) -> String? {
        try? readChecked(account)
    }
    static func readChecked(_ account: String) throws -> String? {
        var query = query(account); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw LinkError.message("The saved pairing key could not be read from Keychain (\(status)). Unlock Keychain and try again; your key has not been replaced.") }
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

enum NativePage: String, CaseIterable { case connect = "Computers", host = "This Mac", picture = "Experience" }

@MainActor final class NativeModel: ObservableObject {
    @Published var page: NativePage = .connect
    @Published var host = "" { didSet { guard !preview else { return }; UserDefaults.standard.set(host, forKey: "nativeHost"); viewerKey = SecretStore.read("viewer:\(host)") ?? "" } }
    @Published var viewerKey = ""
    @Published var computerName = "Mac mini" { didSet { save(computerName, "computerName") } }
    @Published var hostKey = ""
    @Published var showKey = false
    @Published var preset: PicturePreset = .retina { didSet { save(preset.rawValue, "qualityPreset") } }
    @Published var hevc = true { didSet { save(hevc, "nativeHEVC") } }
    @Published var audio = true { didSet { save(audio, "nativeAudio") } }
    @Published var autoReconnect = true { didSet { save(autoReconnect, "autoReconnect"); if !autoReconnect && reconnecting { disconnect() } } }
    @Published var autoFullscreen = true { didSet { save(autoFullscreen, "autoFullscreen") } }
    @Published var scale: DesktopScale = .fit { didSet { save(scale.rawValue, "desktopScale") } }
    @Published var showStats = false { didSet { save(showStats, "viewerStats") } }
    @Published var captureInput = true
    @Published var wantsConnection = false
    @Published var reconnecting = false
    @Published var retryAttempt = 0
    @Published var retryAt: Date?
    @Published var reconnectReason: String?
    @Published var loginEnabled = false
    @Published var loginApprovalNeeded = false
    @Published var sessionStarted: Date?
    @Published var status = "Ready when you are"
    @Published var hostStatus = "Sharing is off"
    @Published var error: String?
    @Published var connected = false
    @Published var connecting = false
    @Published var hosting = false
    @Published var hostConnected = false
    @Published var screenAllowed = false
    @Published var inputAllowed = false
    @Published var screenChecking = false
    @Published var screenVerified = false
    @Published var remoteControlAvailable = true
    @Published var listeningPort: UInt16?
    @Published var fps = 0
    @Published var bitrate = 0.0
    @Published var rtt: Double?
    @Published var resolution = "—"
    @Published var codec = "—"
    let presenter = VideoPresenter()
    let port: UInt16
    private var viewer: LinkChannel?
    private var decoder: NativeDecoder?
    private var audioPlayer: NativeAudioPlayer?
    private var listener: NWListener?
    private var hostChannels: [UUID: LinkChannel] = [:]
    private var activeHost: UUID?
    private var hostVideoStatus: HostStatus?
    private var capture: NativeCapture?
    private let injector = InputInjector()
    private var captureStart: Task<Void, Never>?
    private var hostCleanup: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var hostRetry: Task<Void, Never>?
    private var connectionIntent = UUID()
    private var lastHeartbeat = ProcessInfo.processInfo.systemUptime
    private var hostHeartbeat = ProcessInfo.processInfo.systemUptime
    private var lifecycleStarted = false
    private var terminating = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var hostWanted = false
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
    private let permissionReader: () -> HostPermissions.Snapshot

    init(preview: Bool = false, port: UInt16 = 48100, permissionReader: @escaping () -> HostPermissions.Snapshot = HostPermissions.snapshot) {
        self.preview = preview
        self.port = port
        self.permissionReader = permissionReader
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LocalLink/host")
        host = UserDefaults.standard.string(forKey: "nativeHost") ?? ((try? String(contentsOf: support, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        if !preview {
            viewerKey = SecretStore.read("viewer:\(host)") ?? ""
            hostKey = SecretStore.read("host") ?? ""
        }
        if !preview {
            let defaults = UserDefaults.standard
            computerName = defaults.string(forKey: "computerName") ?? "Mac mini"
            preset = PicturePreset(rawValue: defaults.string(forKey: "qualityPreset") ?? "") ?? .retina
            hevc = defaults.object(forKey: "nativeHEVC") as? Bool ?? true
            audio = defaults.object(forKey: "nativeAudio") as? Bool ?? true
            autoReconnect = defaults.object(forKey: "autoReconnect") as? Bool ?? true
            autoFullscreen = defaults.object(forKey: "autoFullscreen") as? Bool ?? true
            scale = DesktopScale(rawValue: defaults.string(forKey: "desktopScale") ?? "") ?? .fit
            showStats = defaults.bool(forKey: "viewerStats")
            if #available(macOS 13.0, *) {
                loginEnabled = SMAppService.mainApp.status == .enabled
                loginApprovalNeeded = SMAppService.mainApp.status == .requiresApproval
            }
        }
        refreshPermissions()
        presenter.onPresented = { [weak self] in self?.frames += 1; self?.lastFrame = ProcessInfo.processInfo.systemUptime }
        if !preview {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    var request: StreamRequest { preset.request(hevc: hevc, audio: audio) }
    private func save(_ value: Any, _ key: String) { if !preview { UserDefaults.standard.set(value, forKey: key) } }
    func startLifecycle() {
        guard !preview, !lifecycleStarted else { return }; lifecycleStarted = true
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in
            guard let self else { return }
            if self.wantsConnection { self.retryTask?.cancel(); self.loseConnection("Resuming after wake…") }
            if self.hostWanted && !self.hosting { self.startHosting() }
        } })
        if UserDefaults.standard.bool(forKey: "resumeHost") { startHosting() }
        if autoReconnect && UserDefaults.standard.bool(forKey: "resumeViewer") && !viewerKey.isEmpty { connect() }
    }
    func setLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else {
            error = "On Monterey, add LocalLink in System Preferences → Users & Groups → Login Items."
            return
        }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginApprovalNeeded = SMAppService.mainApp.status == .requiresApproval
            if loginApprovalNeeded { SMAppService.openSystemSettingsLoginItems() }
        } catch { self.error = error.localizedDescription }
    }
    var hostValid: Bool { !host.isEmpty && host.count < 254 && host.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:-").contains($0) } }
    func refreshPermissions() {
        let value = permissionReader()
        let inputChanged = inputAllowed != value.input
        screenAllowed = screenVerified || value.screen; inputAllowed = value.input
        if inputChanged, hostConnected, let id = activeHost, var status = hostVideoStatus {
            status.controlAvailable = inputAllowed; hostVideoStatus = status
            hostChannels[id]?.sendJSON(.status, status)
        }
    }
    func verifyScreenAccess() {
        guard !screenChecking else { return }; screenChecking = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.screenChecking = false }
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                self.screenVerified = true; self.screenAllowed = true; self.error = nil
            } catch {
                self.screenVerified = false; self.refreshPermissions()
                self.error = HostPermissions.message(for: error)
            }
        }
    }
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
        guard !connected, !connecting, hostValid else { return }
        do {
            _ = try PairingKey.decode(viewerKey)
            if !preview { try SecretStore.write(viewerKey.trimmingCharacters(in: .whitespacesAndNewlines), account: "viewer:\(host)") }
            retryTask?.cancel(); connectionIntent = UUID(); wantsConnection = true
            retryAttempt = 0; error = nil; captureInput = true
            attemptConnection()
        } catch { self.error = error.localizedDescription }
    }
    private func attemptConnection() {
        guard wantsConnection else { return }
        do {
            let key = try PairingKey.decode(viewerKey), id = UUID(); sessionID = id
            let channel = LinkChannel(host: host, port: port, key: key)
            let decoder = NativeDecoder(), player = NativeAudioPlayer()
            presenter.begin()
            self.decoder = decoder; audioPlayer = player; viewer = channel
            decoder.onPixels = { [weak presenter] pixels in presenter?.present(pixels) }
            connecting = true; retryAt = nil
            status = retryAttempt > 0 ? "Reconnecting…" : "Connecting securely…"
            let request = self.request
            channel.onReady = { [weak self, weak channel] in
                channel?.sendJSON(.hello, request)
                Task { @MainActor in guard self?.sessionID == id else { return }; self?.status = "Opening your desktop…" }
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
                            if status.width == 0 { self.loseConnection(status.text, retryAllowed: status.retryable == true); return }
                            self.connecting = false; self.reconnecting = false; self.connected = true; self.retryAttempt = 0
                            self.status = "Connected"; self.error = nil; self.reconnectReason = nil
                            self.remoteControlAvailable = status.controlAvailable ?? true
                            self.status = self.remoteControlAvailable ? "Connected" : "Connected · view only (enable Accessibility on the host)"
                            self.resolution = "\(status.width) × \(status.height)"; self.codec = status.codec
                            self.lastHeartbeat = ProcessInfo.processInfo.systemUptime; self.pingTime = 0
                            self.sessionStarted = self.sessionStarted ?? Date()
                            self.save(self.autoReconnect, "resumeViewer")
                        }
                    case .ping: channel?.send(.pong, packet.body)
                    case .pong: Task { @MainActor in
                        guard let self, self.sessionID == id, self.sentPing == packet.body else { return }
                        self.lastHeartbeat = ProcessInfo.processInfo.systemUptime
                        self.rtt = (self.lastHeartbeat - self.pingTime) * 1000; self.sentPing = nil
                    }
                    case .goodbyeAck: channel?.cancel()
                    default: break
                    }
                } catch { Task { @MainActor in guard self?.sessionID == id else { return }; self?.loseConnection(error.localizedDescription, retryAllowed: false) } }
            }
            channel.onClose = { [weak self] reason in Task { @MainActor in
                guard let self, self.sessionID == id else { return }
                let authenticationFailure = reason.localizedCaseInsensitiveContains("PSK") || reason.localizedCaseInsensitiveContains("authentication")
                self.loseConnection(reason, retryAllowed: !authenticationFailure)
            } }
            channel.start()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard let self, self.sessionID == id, self.connecting else { return }
                self.loseConnection("The host has not started streaming yet.")
            }
        } catch { loseConnection(error.localizedDescription, retryAllowed: false) }
    }
    func send(_ input: RemoteInput) { guard connected, captureInput, remoteControlAvailable else { return }; viewer?.sendJSON(.input, input) }
    func releaseInput() { viewer?.send(.releaseKeys) }
    func toggleInput() { releaseInput(); captureInput.toggle() }
    private func teardown(graceful: Bool, keepImage: Bool) {
        sessionID = UUID(); connected = false; connecting = false
        let channel = viewer, decoder = self.decoder, player = audioPlayer
        viewer = nil; self.decoder = nil; audioPlayer = nil
        if graceful { channel?.endSession { decoder?.stop(); player?.stop() } }
        else { channel?.cancel(); channel?.queue.async { decoder?.stop(); player?.stop() } }
        presenter.clear(keepImage: keepImage); frames = 0; fps = 0; bytes = 0; bitrate = 0; rtt = nil; sentPing = nil
    }
    private func loseConnection(_ reason: String, retryAllowed: Bool = true) {
        guard wantsConnection else { return }
        reconnectReason = reason
        teardown(graceful: !retryAllowed, keepImage: true)
        guard autoReconnect, retryAllowed else {
            wantsConnection = false; reconnecting = false; retryAt = nil; save(false, "resumeViewer")
            status = "Disconnected"; error = reason; return
        }
        retryTask?.cancel(); retryAttempt += 1; reconnecting = true; status = "Reconnecting…"
        let delay = SessionHealth.retryDelay(attempt: retryAttempt), intent = connectionIntent
        retryAt = Date().addingTimeInterval(delay)
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.wantsConnection, self.connectionIntent == intent else { return }
            self.attemptConnection()
        }
    }
    func retryNow() {
        guard wantsConnection, !connected else { return }
        retryTask?.cancel(); teardown(graceful: false, keepImage: true); attemptConnection()
    }
    func applyPicture() {
        guard wantsConnection else { return }
        retryTask?.cancel(); teardown(graceful: true, keepImage: true)
        let intent = connectionIntent
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self, self.wantsConnection, self.connectionIntent == intent else { return }
            self.attemptConnection()
        }
    }
    func disconnect() {
        retryTask?.cancel(); retryTask = nil; connectionIntent = UUID()
        wantsConnection = false; reconnecting = false; retryAttempt = 0; retryAt = nil
        save(false, "resumeViewer"); teardown(graceful: true, keepImage: false)
        status = "Ready to connect"; sessionStarted = nil
    }
    func startHosting() {
        guard !hosting else { return }
        hostWanted = true
        refreshPermissions()
        // Advisory checks must never prevent a real ScreenCaptureKit attempt.
        // Accessibility controls input only; an unavailable input grant still allows viewing.
        if hostKey.isEmpty {
            do {
                if let saved = try SecretStore.readChecked("host") { hostKey = saved }
                else { rotateKey(); hostWanted = true }
            } catch { self.error = error.localizedDescription; return }
        }
        do {
            let key = try PairingKey.decode(hostKey)
            let listener = try NWListener(using: LinkTLS.parameters(key: key), on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener; hosting = true; save(true, "resumeHost"); hostStatus = "Starting secure listener…"; error = nil
            listener.newConnectionHandler = { [weak self, weak listener] connection in Task { @MainActor in
                guard let self, self.listener === listener else { connection.cancel(); return }
                self.accept(connection)
            } }
            listener.stateUpdateHandler = { [weak self] state in Task { @MainActor in
                guard self?.listener === listener else { return }
                switch state {
                case .ready: self?.listeningPort = listener.port?.rawValue; self?.hostStatus = "Waiting for your other Mac"
                case .failed(let error): self?.error = error.localizedDescription; self?.recoverHost()
                default: break
                }
            } }
            listener.start(queue: DispatchQueue(label: "LocalLink.host-listener"))
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "LocalLink host is available" as CFString, &sleepAssertion)
        } catch { self.error = error.localizedDescription; recoverHost() }
    }
    private func accept(_ connection: NWConnection) {
        guard hosting, hostChannels.count < 4 else { connection.cancel(); return }
        let id = UUID(), channel = LinkChannel(connection)
        hostChannels[id] = channel
        channel.onPacket = { [weak self, weak channel] packet in
            if packet.kind == .ping {
                channel?.send(.pong, packet.body)
                Task { @MainActor in if self?.activeHost == id { self?.hostHeartbeat = ProcessInfo.processInfo.systemUptime } }
                return
            }
            Task { @MainActor in
                guard let self, self.hostChannels[id] != nil else { return }
                switch packet.kind {
                case .hello:
                    guard let channel, let request = try? JSONDecoder().decode(StreamRequest.self, from: packet.body), request.valid else { channel?.cancel(); return }
                    guard self.activeHost == nil else {
                        self.removeHost(id, cancel: false)
                        channel.endWithStatus(HostStatus(text: "The previous session is still closing. Retrying shortly…", width: 0, height: 0, codec: "", retryable: true))
                        return
                    }
                    self.hostHeartbeat = ProcessInfo.processInfo.systemUptime
                    self.activeHost = id; self.beginCapture(request, channel: channel, id: id)
                case .input:
                    guard self.activeHost == id, self.hostConnected, let input = try? JSONDecoder().decode(RemoteInput.self, from: packet.body) else { return }
                    self.injector.apply(input)
                case .releaseKeys: if self.activeHost == id { self.injector.releaseAll() }
                case .goodbye:
                    self.removeHost(id, cancel: false)
                    channel?.send(.goodbyeAck) { channel?.cancel() }
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
            self.failHost(id, message: reason)
        } }
        captureStart = Task { @MainActor [weak self] in
            do {
                await self?.hostCleanup?.value
                try Task.checkCancellation()
                var status = try await capture.start(request: request, channel: channel)
                guard let self, self.activeHost == id, !Task.isCancelled else { await capture.stop(); return }
                self.injector.bounds = capture.displayBounds
                self.screenVerified = true; self.screenAllowed = true
                self.refreshPermissions(); status.controlAvailable = self.inputAllowed
                self.hostVideoStatus = status
                self.hostConnected = true; self.hostStatus = "Your other Mac is connected · \(status.codec)"
                channel.sendJSON(.status, status)
            } catch {
                guard let self, self.activeHost == id else { await capture.stop(); return }
                if error is CancellationError { self.removeHost(id); return }
                self.screenVerified = false
                self.failHost(id, message: HostPermissions.message(for: error))
            }
        }
    }
    private func failHost(_ id: UUID, message: String) {
        guard let channel = hostChannels[id] else { return }
        removeHost(id, cancel: false)
        error = message; hostStatus = "Capture needs attention — see the message above"
        channel.endWithStatus(HostStatus(text: message, width: 0, height: 0, codec: "", retryable: false))
    }
    private func removeHost(_ id: UUID, cancel: Bool = true) {
        let channel = hostChannels.removeValue(forKey: id)
        if cancel { channel?.cancel() }
        guard activeHost == id else { return }
        activeHost = nil; hostConnected = false; hostVideoStatus = nil; injector.releaseAll(); captureStart?.cancel(); captureStart = nil
        if let capture {
            let previous = hostCleanup
            hostCleanup = Task { @MainActor in await previous?.value; await capture.stop() }
        }; capture = nil
        hostStatus = hosting ? "Waiting for your other Mac · port \(port)" : "Sharing is off"
    }
    private func recoverHost() {
        guard hostWanted else { return }
        stopHosting(remember: false)
        hostRetry?.cancel()
        hostRetry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, self?.hostWanted == true else { return }
            self?.startHosting()
        }
    }
    func stopHosting(remember: Bool = true) {
        if remember { hostWanted = false; hostRetry?.cancel(); save(false, "resumeHost") }
        listener?.newConnectionHandler = nil; listener?.stateUpdateHandler = nil
        listener?.cancel(); listener = nil; hosting = false
        listeningPort = nil
        for id in Array(hostChannels.keys) { removeHost(id) }
        injector.releaseAll(); hostConnected = false; hostStatus = "Sharing is off"
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }
    }
    func tick() {
        refreshPermissions()
        let now = ProcessInfo.processInfo.systemUptime, elapsed = now - lastStats
        fps = Int((Double(frames) / max(0.1, elapsed)).rounded()); bitrate = Double(bytes) * 8 / max(0.1, elapsed) / 1_000_000
        frames = 0; bytes = 0; lastStats = now
        if connected {
            if SessionHealth.timedOut(now: now, lastResponse: lastHeartbeat) { loseConnection("Waiting for the network to return…"); return }
            if sentPing == nil && now - pingTime >= SessionHealth.heartbeatInterval { let nonce = Data(UUID().uuidString.utf8); sentPing = nonce; pingTime = now; viewer?.send(.ping, nonce) }
        }
        if let activeHost, now - hostHeartbeat > 25 { removeHost(activeHost) }
    }
    func prepareForTermination() { terminating = true }
    func closeViewerWindow() { if !terminating { disconnect() } }
    func shutdown() {
        terminating = true
        save(wantsConnection && autoReconnect, "resumeViewer"); save(hostWanted, "resumeHost")
        retryTask?.cancel(); hostRetry?.cancel(); teardown(graceful: true, keepImage: false)
        stopHosting(remember: false); timer?.invalidate()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

import IOKit.pwr_mgt

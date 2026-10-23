import Foundation
import AppKit
import SwiftUI

enum AppPage: String, CaseIterable, Identifiable {
    case connect, picture, diagnostics, setup
    var id: String { rawValue }
    var title: String { switch self { case .connect: return "Connect"; case .picture: return "Picture & response"; case .diagnostics: return "Connection health"; case .setup: return "Setup" } }
    var icon: String { switch self { case .connect: return "rectangle.connected.to.line.below"; case .picture: return "slider.horizontal.3"; case .diagnostics: return "waveform.path.ecg"; case .setup: return "checklist" } }
}
enum ViewerPhase: Equatable { case idle, pairing, session, installing }

private final class ServerXML: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    private var name = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) { name = elementName }
    func parser(_ parser: XMLParser, foundCharacters string: String) { values[name, default: ""] += string }
}

struct HostProbe {
    let ready: Bool
    let name: String?
    let failure: String?
    static func fetch(_ url: URL) async -> HostProbe {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard data.count < 2_000_000, (response as? HTTPURLResponse)?.statusCode == 200 else {
                return HostProbe(ready: false, name: nil, failure: "The streaming endpoint returned an unexpected response.")
            }
            let parser = XMLParser(data: data), delegate = ServerXML()
            parser.shouldResolveExternalEntities = false; parser.delegate = delegate
            let ready = parser.parse() && !(delegate.values["appversion"] ?? "").isEmpty
            return HostProbe(ready: ready, name: delegate.values["hostname"], failure: ready ? nil : "No compatible streaming host was found on port 47989.")
        } catch {
            return HostProbe(ready: false, name: nil, failure: "The streaming host did not respond on port 47989.")
        }
    }
}

@MainActor final class SessionModel: ObservableObject {
    @Published var page: AppPage = .connect
    @Published var settings: StreamSettings {
        didSet {
            guard !preview else { return }
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "streamSettings") }
            if oldValue.cleanHost != settings.cleanHost {
                generation = UUID(); reachability = .unchecked; route = .unknown; samples = []; lastCheck = nil
                sshAuthenticated = false; paired = false
                LocalPaths.saveConfiguredHost(settings.cleanHost)
            }
        }
    }
    @Published var reachability: Reachability = .unchecked
    @Published var tailnetRunning = false
    @Published var peerOnline: Bool?
    @Published var route: NetworkRoute = .unknown
    @Published var samples: [PingSample] = []
    @Published var checking = false
    @Published var measuring = false
    @Published var lastCheck: Date?
    @Published var phase: ViewerPhase = .idle
    @Published var pin = ""
    @Published var notification: String?
    @Published var log = ""
    @Published var sshAuthenticated = false
    @Published var paired = false
    @Published var history: [SessionRecord] = []
    @Published var sessionStarted: Date?
    @Published var hostName = "Mac mini"
    let hardware: ViewerHardware
    let preview: Bool
    private let viewer = ViewerProcess()
    private var monitorTask: Task<Void, Never>?
    private var pairingTimeout: Task<Void, Never>?
    private var generation = UUID()
    private var sessionConfiguration = ""

    init(preview: Bool = false) {
        self.preview = preview; hardware = .current()
        if !preview, let data = UserDefaults.standard.data(forKey: "streamSettings"),
           let decoded = try? JSONDecoder().decode(StreamSettings.self, from: data) { settings = decoded }
        else { var value = StreamSettings(); value.apply(.smooth, hardware: hardware); if preview { value.host = "" }; settings = value }
        if !preview, let data = UserDefaults.standard.data(forKey: "viewerHistory"),
           let decoded = try? JSONDecoder().decode([SessionRecord].self, from: data) { history = Array(decoded.prefix(12)) }
        paired = !preview && UserDefaults.standard.stringArray(forKey: "pairedHosts")?.contains(settings.cleanHost) == true
        if !preview && settings.cleanHost.isEmpty { page = .setup }
    }
    var busy: Bool { phase != .idle }
    var canConnect: Bool { reachability == .ready && !busy && LocalPaths.moonlight != nil }
    var rtt: Double? { samples.last?.milliseconds }
    var median: Double? {
        let values = samples.suffix(10).map(\.milliseconds).sorted()
        guard !values.isEmpty else { return nil }
        return values[values.count / 2]
    }
    var variation: Double? {
        let values = samples.suffix(10).map(\.milliseconds)
        guard values.count >= 3 else { return nil }
        return zip(values.dropFirst(), values).map { abs($0 - $1) }.reduce(0, +) / Double(values.count - 1)
    }
    var displayStatus: String {
        if phase == .session { return "Viewer open" }
        if phase == .pairing { return "Pairing" }
        if phase == .installing { return "Installing host" }
        if checking { return "Checking connection" }
        return reachability == .ready ? "Ready to connect" : reachability == .offline ? "Mac mini offline" : reachability == .hostMissing ? "Host setup needed" : "Not connected"
    }
    var profileIsCustom: Bool {
        var expected = StreamSettings(); expected.apply(settings.profile, hardware: hardware)
        return expected.resolution != settings.resolution || expected.fps != settings.fps || expected.bitrate != settings.bitrate || settings.pacing != .smooth || !settings.hardwareOnly || settings.chroma444 || settings.codec != "auto"
    }
    var recommendation: String {
        if reachability == .offline { return "The mini must be awake and connected before picture quality can be measured." }
        if route == .relay { return "This path uses a relay. Try Travel first; a direct path generally leaves more room for high-quality streaming." }
        if settings.fps > hardware.refresh { return "This display refreshes at \(hardware.refresh) Hz. Higher stream FPS increases decoding work without displaying every frame." }
        if settings.chroma444 { return "Full color detail needs compatible encoding and decoding. Turn it off first if a session fails to start." }
        if settings.resolution == "3840x2160" && hardware.width < 3840 { return "4K is downscaled on this display. Match the viewer’s resolution for a lighter decoding workload." }
        return "Start with Smooth, then use the in-stream overlay to check dropped frames and decode time before increasing quality."
    }

    func startMonitoring() {
        guard !preview, monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if NSApplication.shared.isActive && !self.busy { await self.refresh() }
            }
        }
    }
    func foregrounded() {
        guard !preview, !busy else { return }
        Task {
            await checkSSH()
            if lastCheck == nil || Date().timeIntervalSince(lastCheck!) > 15 { await refresh() }
        }
    }

    func refresh(measure: Bool = false, allowPreview: Bool = false) async {
        guard (!preview || allowPreview), !checking, !busy else { return }
        guard let url = settings.serverURL else { reachability = .invalidAddress; return }
        checking = true; measuring = measure
        let host = settings.cleanHost, token = generation
        defer { checking = false; measuring = false }
        async let probe = HostProbe.fetch(url)
        var running = false, online: Bool?, newSamples: [PingSample] = []
        if let executable = LocalPaths.tailscale {
            let status = await Command.run(executable, ["status", "--json"], timeout: 5)
            if let data = status.output.data(using: .utf8), let decoded = try? JSONDecoder().decode(TailnetStatus.self, from: data) {
                running = decoded.backendState == "Running"
                online = decoded.peer(for: host)?.online
            }
            // Warm-up samples can use a relay before NAT traversal finds a direct route.
            if running && online != false {
                let ping = await Command.run(executable, ["ping", "--c", measure ? "5" : "2", "--until-direct=false", "--timeout", "2s", host], timeout: measure ? 16 : 8)
                newSamples = PingParser.parse(ping.output)
            }
        }
        let hostProbe = await probe
        guard token == generation, host == settings.cleanHost else { return }
        tailnetRunning = running; peerOnline = online
        reachability = Reachability.classify(valid: true, running: running, peerOnline: online,
                                            routeResponded: !newSamples.isEmpty, hostResponded: hostProbe.ready)
        if let name = hostProbe.name, !name.isEmpty { hostName = name }
        if !newSamples.isEmpty { samples = Array((samples + newSamples).suffix(40)); route = newSamples.last!.route }
        else if reachability == .offline || reachability == .networkDisconnected { samples = []; route = .offline }
        else { route = .unknown; samples = [] }
        lastCheck = Date()
        paired = UserDefaults.standard.stringArray(forKey: "pairedHosts")?.contains(host) == true
        await checkSSH()
    }

    func apply(_ profile: Profile) { settings.apply(profile, hardware: hardware) }
    func matchDisplay() { settings.resolution = hardware.resolution; settings.fps = min(60, hardware.refresh) }
    func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    func appendLog(_ text: String) { log = String((log + text).suffix(22_000)) }

    private func engineAvailable() -> String? {
        guard let executable = LocalPaths.moonlight else { notification = "Install Moonlight in Applications before connecting."; page = .setup; return nil }
        if NSWorkspace.shared.runningApplications.contains(where: { $0.executableURL?.path == executable }) {
            notification = "Moonlight is already open. Close its window and quit it before starting a managed session here."
            return nil
        }
        return executable
    }
    func pair() {
        guard canConnect, let executable = engineAvailable() else { return }
        let host = settings.cleanHost
        pin = String(format: "%04d", Int.random(in: 0...9999)); phase = .pairing; log = ""
        notification = "Enter this PIN in Sunshine → PIN on the mini. Keep this window open while pairing."
        do {
            try viewer.start(executable: executable, arguments: ["pair", host, "--pin", pin], output: { [weak self] in self?.appendLog($0) }, completion: { [weak self] status, stopped in
                guard let self else { return }
                self.pairingTimeout?.cancel(); self.pairingTimeout = nil; self.phase = .idle
                if status == 0 && !stopped {
                    self.paired = true
                    var hosts = UserDefaults.standard.stringArray(forKey: "pairedHosts") ?? []
                    if !hosts.contains(host) { hosts.append(host) }
                    UserDefaults.standard.set(hosts, forKey: "pairedHosts")
                    self.notification = "Pairing completed. Your Mac mini is ready to open."
                } else { self.notification = stopped ? "Pairing stopped. You can try again when ready." : "Pairing didn’t complete. Check the PIN page on the mini. Details are in Connection health." }
            })
            pairingTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 125_000_000_000)
                guard !Task.isCancelled, self?.phase == .pairing else { return }
                self?.viewer.stop()
            }
        } catch { phase = .idle; notification = error.localizedDescription }
    }
    func connect() {
        guard canConnect, let executable = engineAvailable() else { return }
        guard !settings.application.isEmpty, !settings.application.hasPrefix("-") else { notification = "Choose a Sunshine application name, normally Desktop."; return }
        phase = .session; log = ""; sessionStarted = Date(); sessionConfiguration = settings.summary
        notification = nil
        do {
            try viewer.start(executable: executable, arguments: settings.arguments, output: { [weak self] in self?.appendLog($0) }, completion: { [weak self] status, stopped in
                guard let self else { return }
                let duration = Int(Date().timeIntervalSince(self.sessionStarted ?? Date()))
                self.history.insert(SessionRecord(date: self.sessionStarted ?? Date(), seconds: duration, configuration: self.sessionConfiguration, outcome: stopped ? "Disconnected" : status == 0 ? "Viewer closed" : "Viewer exited with an error"), at: 0)
                self.history = Array(self.history.prefix(12))
                if let data = try? JSONEncoder().encode(self.history) { UserDefaults.standard.set(data, forKey: "viewerHistory") }
                self.phase = .idle; self.sessionStarted = nil
                self.notification = stopped || status == 0 ? "Viewer closed. Your Mac mini’s desktop is still running." : "The viewer exited. Check Connection health for the engine’s message, then reconnect or try Travel."
            })
        } catch { phase = .idle; sessionStarted = nil; notification = error.localizedDescription }
    }
    func disconnect() { viewer.stop() }
    func showViewer() { viewer.activate() }

    func checkSSH() async {
        guard FileManager.default.fileExists(atPath: LocalPaths.socket), LocalPaths.authenticatedHost == settings.cleanHost,
              let username = LocalPaths.authenticatedUser else { sshAuthenticated = false; return }
        let result = await Command.run("/usr/bin/ssh", ["-S", LocalPaths.socket, "-O", "check", "\(username)@\(settings.cleanHost)"], timeout: 3)
        sshAuthenticated = result.status == 0
    }
    func authenticateSSH() {
        guard let script = Bundle.main.url(forResource: "Authenticate Mac mini", withExtension: "command") else { return }
        guard settings.validHost else { notification = "Enter your host’s Tailscale IP or hostname first."; page = .setup; return }
        do {
            try FileManager.default.createDirectory(at: LocalPaths.sshDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try settings.cleanHost.write(to: LocalPaths.sshDirectory.appendingPathComponent("target"), atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(script)
            notification = "Enter the mini’s short username and password in Terminal. The password is not saved. Return here after it says Authenticated."
        } catch { notification = error.localizedDescription }
    }
    func installHost() async {
        guard !busy, sshAuthenticated, LocalPaths.authenticatedHost == settings.cleanHost,
              let username = LocalPaths.authenticatedUser,
              let script = Bundle.main.url(forResource: "Set up Mac mini", withExtension: "command") else { return }
        phase = .installing; log = ""; notification = "Installing Sunshine on the mini through the authenticated SSH connection…"
        defer { phase = .idle }
        let host = "\(username)@\(settings.cleanHost)"
        let scpHost = settings.cleanHost.contains(":") ? "\(username)@[\(settings.cleanHost)]" : host
        let options = ["-o", "ControlPath=\(LocalPaths.sshConfigValue(LocalPaths.socket))", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\(LocalPaths.sshConfigValue(LocalPaths.knownHosts))"]
        let temporary = await Command.run("/usr/bin/ssh", options + [host, "umask 077; mktemp -d /tmp/locallink-install.XXXXXX"], timeout: 8)
        let directory = temporary.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard temporary.status == 0, directory.range(of: "^/tmp/locallink-install\\.[A-Za-z0-9]+$", options: .regularExpression) != nil else {
            notification = "SSH setup access expired or failed. Authenticate again in Terminal."; appendLog(temporary.output); return
        }
        let transfer = await Command.run("/usr/bin/scp", options + [script.path, "\(scpHost):\(directory)/setup.command"], timeout: 20)
        appendLog(transfer.output)
        guard transfer.status == 0 else { notification = "Could not transfer the host setup file."; return }
        // SSH_CONNECTION identifies the host's endpoint, including when a DNS name was used.
        let result = await Command.run("/usr/bin/ssh", options + [host, "set -- $SSH_CONNECTION; /bin/bash '\(directory)/setup.command' --expected-ip \"$3\"; task_result=$?; /bin/rm -rf '\(directory)'; exit $task_result"], timeout: 180)
        appendLog(result.output)
        notification = result.status == 0 ? "Host installed. Grant Sunshine screen recording and Accessibility on the mini, then reopen Sunshine and check the connection." : "Host setup needs attention. Open Connection health to see the installer’s message."
    }
    func openDashboard() async {
        guard sshAuthenticated, LocalPaths.authenticatedHost == settings.cleanHost,
              let username = LocalPaths.authenticatedUser else { notification = "Authenticate SSH first to open the mini’s private dashboard here."; return }
        let target = "\(username)@\(settings.cleanHost)", forwarding = "127.0.0.1:44990:127.0.0.1:47990"
        _ = await Command.run("/usr/bin/ssh", ["-S", LocalPaths.socket, "-O", "cancel", "-L", forwarding, target], timeout: 3)
        let result = await Command.run("/usr/bin/ssh", ["-S", LocalPaths.socket, "-O", "forward", "-L", forwarding, target], timeout: 5)
        if result.status == 0, let url = URL(string: "https://localhost:44990") {
            NSWorkspace.shared.open(url)
            notification = "Opened Sunshine through your SSH tunnel. Its local dashboard uses a self-signed certificate."
        } else { notification = "Could not open the dashboard tunnel. Reauthenticate SSH and try again."; appendLog(result.output) }
    }
    func openGuide() {
        if let file = Bundle.main.url(forResource: "Start Here", withExtension: "html") { NSWorkspace.shared.open(file) }
    }
    func openTailscale() { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tailscale.app")) }
    func exportReport() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "LocalLink connection report.txt"; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let report = """
        LocalLink 0.3 — connection report
        Generated: \(Date().formatted())
        Host: \(settings.cleanHost)
        Availability: \(reachability.title)
        Tailscale running: \(tailnetRunning)
        Network route: \(route.title)
        Latest network RTT: \(rtt.map { String(format: "%.1f ms", $0) } ?? "Not measured")
        RTT sample variation: \(variation.map { String(format: "%.1f ms", $0) } ?? "Not measured")
        Viewer canvas: \(hardware.caption)
        Hardware decode: H.264 \(hardware.h264), HEVC \(hardware.hevc)
        Requested stream: \(settings.summary)
        Presentation: \(settings.pacing.title)
        Codec setting: \(settings.codec)
        Hardware decoder required: \(settings.hardwareOnly)
        4:4:4 requested: \(settings.chroma444)
        These RTT measurements do not include video encoding, decoding, or input delay.

        Engine / setup output:
        \(log)
        """
        do { try report.write(to: url, atomically: true, encoding: .utf8); notification = "Connection report saved." }
        catch { notification = error.localizedDescription }
    }
}

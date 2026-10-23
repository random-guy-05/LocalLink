import Foundation
import AppKit
import VideoToolbox
import Darwin

enum Profile: String, Codable, CaseIterable, Identifiable {
    case smooth, sharp, travel
    var id: String { rawValue }
    var title: String { switch self { case .smooth: return "Smooth"; case .sharp: return "Sharper"; case .travel: return "Travel" } }
    var symbol: String { switch self { case .smooth: return "water.waves"; case .sharp: return "viewfinder"; case .travel: return "wifi" } }
    var subtitle: String { switch self {
        case .smooth: return "Everyday, beautifully fluid."
        case .sharp: return "More detail. More bandwidth."
        case .travel: return "Lighter on your connection."
    } }
}

enum Pacing: String, Codable, CaseIterable {
    case smooth, responsive
    var title: String { self == .smooth ? "Smooth motion" : "Fastest response" }
    var detail: String { self == .smooth ? "V-Sync and frame pacing on. Prioritizes consistent presentation." : "V-Sync and frame pacing off. May show tearing or uneven motion." }
}

struct ViewerHardware {
    let width: Int
    let height: Int
    let refresh: Int
    let h264: Bool
    let hevc: Bool
    var resolution: String { "\(width)x\(height)" }
    var caption: String { "\(width) × \(height) · \(refresh) Hz" }
    static func current() -> ViewerHardware {
        let mode = CGDisplayCopyDisplayMode(CGMainDisplayID())
        let refresh = Int((mode?.refreshRate ?? 60).rounded())
        return ViewerHardware(width: mode?.pixelWidth ?? 2560, height: mode?.pixelHeight ?? 1600,
                              refresh: refresh > 0 ? refresh : 60,
                              h264: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
                              hevc: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))
    }
}

struct StreamSettings: Codable, Equatable {
    var host = ""
    var resolution = "2560x1600"
    var fps = 60
    var bitrate = 28
    var codec = "auto"
    var fullscreen = true
    var overlay = false
    var application = "Desktop"
    var profile: Profile = .smooth
    var pacing: Pacing = .smooth
    var hardwareOnly = true
    var chroma444 = false
    var relativeMouse = false

    init() { host = LocalPaths.configuredHost ?? "" }
    private enum CodingKeys: String, CodingKey { case host, resolution, fps, bitrate, codec, fullscreen, overlay, application, profile, pacing, hardwareOnly, chroma444, relativeMouse }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? LocalPaths.configuredHost ?? ""
        resolution = try values.decodeIfPresent(String.self, forKey: .resolution) ?? "2560x1600"
        fps = try values.decodeIfPresent(Int.self, forKey: .fps) ?? 60
        bitrate = try values.decodeIfPresent(Int.self, forKey: .bitrate) ?? 28
        codec = try values.decodeIfPresent(String.self, forKey: .codec) ?? "auto"
        fullscreen = try values.decodeIfPresent(Bool.self, forKey: .fullscreen) ?? true
        overlay = try values.decodeIfPresent(Bool.self, forKey: .overlay) ?? false
        application = try values.decodeIfPresent(String.self, forKey: .application) ?? "Desktop"
        profile = try values.decodeIfPresent(Profile.self, forKey: .profile) ?? .smooth
        pacing = try values.decodeIfPresent(Pacing.self, forKey: .pacing) ?? .smooth
        hardwareOnly = try values.decodeIfPresent(Bool.self, forKey: .hardwareOnly) ?? true
        chroma444 = try values.decodeIfPresent(Bool.self, forKey: .chroma444) ?? false
        relativeMouse = try values.decodeIfPresent(Bool.self, forKey: .relativeMouse) ?? false
        normalize()
    }
    mutating func normalize() {
        bitrate = min(120, max(5, bitrate))
        if ![30, 60, 90, 120].contains(fps) { fps = 60 }
        if !["auto", "HEVC", "H.264"].contains(codec) { codec = "auto" }
        if resolution.range(of: "^[1-9][0-9]{2,4}x[1-9][0-9]{2,4}$", options: .regularExpression) == nil { resolution = "2560x1600" }
        if application.isEmpty || application.hasPrefix("-") { application = "Desktop" }
    }
    var cleanHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    var validHost: Bool { HostAddress.valid(cleanHost) }
    var serverURL: URL? { HostAddress.url(cleanHost, port: 47989, path: "/serverinfo") }
    var arguments: [String] {
        ["stream", cleanHost, application, "--resolution", resolution,
         "--fps", String(fps), "--bitrate", String(bitrate * 1000),
         "--video-codec", codec, "--video-decoder", hardwareOnly ? "hardware" : "auto",
         "--display-mode", fullscreen ? "fullscreen" : "windowed", "--audio-config", "stereo",
         "--packet-size", "1200", relativeMouse ? "--no-absolute-mouse" : "--absolute-mouse",
         "--keep-awake", "--no-hdr", "--no-quit-after", "--capture-system-keys", "fullscreen",
         pacing == .smooth ? "--vsync" : "--no-vsync",
         pacing == .smooth ? "--frame-pacing" : "--no-frame-pacing",
         chroma444 ? "--yuv444" : "--no-yuv444",
         overlay ? "--performance-overlay" : "--no-performance-overlay"]
    }
    mutating func apply(_ profile: Profile, hardware: ViewerHardware) {
        self.profile = profile
        resolution = profile == .travel ? "1920x1080" : hardware.resolution
        fps = min(60, hardware.refresh)
        if fps < 30 { fps = 60 }
        bitrate = profile == .travel ? 12 : profile == .sharp ? 45 : 28
        codec = "auto"; pacing = .smooth; hardwareOnly = true; chroma444 = false
    }
    var summary: String { "\(resolution.replacingOccurrences(of: "x", with: " × ")) · \(fps) fps · \(bitrate) Mbps" }
}

enum HostAddress {
    static func valid(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 253, !text.hasPrefix("-"), !text.contains("/") else { return false }
        if text.contains(":") {
            var address = in6_addr()
            return text.withCString { inet_pton(AF_INET6, $0, &address) } == 1
        }
        return text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" &&
            $0.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil
        }
    }
    static func url(_ host: String, port: Int, path: String) -> URL? {
        guard valid(host) else { return nil }
        var value = URLComponents()
        value.scheme = "http"; value.host = host.contains(":") ? "[\(host)]" : host
        value.port = port; value.path = path
        return value.url
    }
}

enum NetworkRoute: String, Codable {
    case unknown, direct, relay, peerRelay, offline
    var title: String {
        switch self { case .unknown: return "Not checked"; case .direct: return "Direct"; case .relay: return "Relayed"; case .peerRelay: return "Peer relay"; case .offline: return "Unavailable" }
    }
}

struct PingSample: Identifiable {
    let id = UUID()
    let date = Date()
    let milliseconds: Double
    let route: NetworkRoute
}

enum PingParser {
    static func parse(_ output: String) -> [PingSample] {
        output.components(separatedBy: .newlines).compactMap { line in
            guard line.contains("pong from"), let range = line.range(of: " in ", options: .backwards) else { return nil }
            let timing = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            let number = Double(timing.replacingOccurrences(of: "ms", with: "").replacingOccurrences(of: "s", with: ""))
            guard let number, number >= 0 else { return nil }
            let milliseconds = timing.hasSuffix("ms") ? number : number * 1000
            let lower = line.lowercased()
            let route: NetworkRoute = lower.contains("via derp") ? .relay : lower.contains("peer-relay") || lower.contains("peer relay") ? .peerRelay : lower.contains(" via ") ? .direct : .unknown
            return PingSample(milliseconds: milliseconds, route: route)
        }
    }
}

struct TailnetPeer: Decodable {
    var hostName: String?
    var dnsName: String?
    var ips: [String]?
    var online: Bool?
    var lastSeen: Date?
    enum CodingKeys: String, CodingKey { case hostName = "HostName", dnsName = "DNSName", ips = "TailscaleIPs", online = "Online", lastSeen = "LastSeen" }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hostName = try values.decodeIfPresent(String.self, forKey: .hostName)
        dnsName = try values.decodeIfPresent(String.self, forKey: .dnsName)
        ips = try values.decodeIfPresent([String].self, forKey: .ips)
        online = try values.decodeIfPresent(Bool.self, forKey: .online)
        if let date = try values.decodeIfPresent(String.self, forKey: .lastSeen) {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            lastSeen = formatter.date(from: date) ?? ISO8601DateFormatter().date(from: date)
        }
    }
}

struct TailnetStatus: Decodable {
    var backendState: String?
    var peers: [String: TailnetPeer]?
    enum CodingKeys: String, CodingKey { case backendState = "BackendState", peers = "Peer" }
    func peer(for host: String) -> TailnetPeer? {
        peers?.values.first { peer in
            peer.ips?.contains(host) == true || peer.dnsName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == host.lowercased() || peer.hostName?.lowercased() == host.lowercased()
        }
    }
}

enum Reachability: Equatable {
    case unchecked, invalidAddress, networkDisconnected, offline, hostMissing, ready
    var title: String {
        switch self {
        case .unchecked: return "Let’s find your Mac"
        case .invalidAddress: return "Check the address"
        case .networkDisconnected: return "Connect your private network"
        case .offline: return "Your Mac mini is offline"
        case .hostMissing: return "Your Mac is online. One more step."
        case .ready: return "Your Mac is ready"
        }
    }
    var detail: String {
        switch self {
        case .unchecked: return "Run a connection check to see the route, availability, and streaming host."
        case .invalidAddress: return "Use an IP address or a hostname, without a URL, username, or port."
        case .networkDisconnected: return "Open Tailscale on this Mac and connect to the same private network as the mini."
        case .offline: return "Wake the mini and check its internet and Tailscale connection. Your saved picture settings will be ready when it returns."
        case .hostMissing: return "Sunshine isn’t responding. Open it on the mini and check its permissions and firewall."
        case .ready: return "Choose your picture profile and connect. The first connection needs a one-time pairing."
        }
    }
    static func classify(valid: Bool, running: Bool, peerOnline: Bool?, routeResponded: Bool, hostResponded: Bool) -> Reachability {
        if !valid { return .invalidAddress }
        // An authenticated streaming endpoint can respond while stale tailnet state says offline.
        if hostResponded { return .ready }
        if !running { return .networkDisconnected }
        if routeResponded || peerOnline == true { return .hostMissing }
        return .offline
    }
}

struct SessionRecord: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let seconds: Int
    let configuration: String
    let outcome: String
}

enum LocalPaths {
    static func sshConfigValue(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalLink") }
    static var sshDirectory: URL { support.appendingPathComponent("SSH") }
    static var socket: String { sshDirectory.appendingPathComponent("mini.sock").path }
    static var sshUser: URL { sshDirectory.appendingPathComponent("username") }
    static var knownHosts: String { sshDirectory.appendingPathComponent("known_hosts").path }
    static var configuredHost: String? {
        guard let value = try? String(contentsOf: support.appendingPathComponent("host"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), HostAddress.valid(value) else { return nil }
        return value
    }
    static var authenticatedHost: String? {
        guard let value = try? String(contentsOf: sshDirectory.appendingPathComponent("connected-host"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), HostAddress.valid(value) else { return nil }
        return value
    }
    static func saveConfiguredHost(_ value: String) {
        let file = support.appendingPathComponent("host")
        if value.isEmpty { try? FileManager.default.removeItem(at: file); return }
        guard HostAddress.valid(value) else { return }
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? value.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static var moonlight: String? { ["/Applications/Moonlight.app/Contents/MacOS/Moonlight", NSHomeDirectory() + "/Applications/Moonlight.app/Contents/MacOS/Moonlight"].first { FileManager.default.isExecutableFile(atPath: $0) } }
    static var tailscale: String? { ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"].first { FileManager.default.isExecutableFile(atPath: $0) } }
    static var authenticatedUser: String? {
        guard let value = try? String(contentsOf: sshUser, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(of: "^[A-Za-z_][A-Za-z0-9_-]*$", options: .regularExpression) != nil else { return nil }
        return value
    }
}

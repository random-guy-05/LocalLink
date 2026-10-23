import Foundation
import Network
import Security
import CryptoKit

enum LinkError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum PairingKey {
    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw LinkError.message("Could not generate a secure pairing key.") }
        return Data(bytes).base64EncodedString()
    }
    static func decode(_ text: String) throws -> Data {
        guard let value = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), value.count == 32 else { throw LinkError.message("Paste the full pairing key from the host Mac (32 random bytes).") }
        return value
    }
}

enum LinkTLS {
    static func parameters(key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let identity = Data(("LocalLink-native-v1:" + Data(SHA256.hash(data: key)).base64EncodedString()).utf8)
        key.withUnsafeBytes { keyBytes in
            identity.withUnsafeBytes { identityBytes in
                let secret = DispatchData(bytes: keyBytes) as AnyObject as! dispatch_data_t
                let label = DispatchData(bytes: identityBytes) as AnyObject as! dispatch_data_t
                sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, secret, label)
            }
        }
        // Network.framework's external-PSK API uses the TLS 1.2 PSK suites.
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        // A changed or revoked key must never inherit an earlier authenticated session.
        sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
        sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
    }
}

enum PacketKind: UInt8 { case hello = 1, video = 2, input = 3, status = 4, ping = 5, pong = 6, audio = 7, releaseKeys = 8 }

struct WirePacket {
    static let limit = 8 * 1024 * 1024
    let kind: PacketKind
    let body: Data
    var framed: Data {
        var result = Data()
        result.appendInteger(UInt32(body.count + 1))
        result.append(kind.rawValue)
        result.append(body)
        return result
    }
}

extension Data {
    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) { var big = value.bigEndian; Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) } }
    func integer<T: FixedWidthInteger>(at offset: Int, as: T.Type = T.self) -> T? {
        guard offset >= 0, offset + MemoryLayout<T>.size <= count else { return nil }
        var value: T = 0
        for byte in self[index(startIndex, offsetBy: offset)..<index(startIndex, offsetBy: offset + MemoryLayout<T>.size)] { value = (value << 8) | T(byte) }
        return value
    }
}

/// One authenticated, encrypted stream. Reads are bounded before allocating a payload.
/// All callbacks run on this channel's serial queue; the UI explicitly hops to main.
final class LinkChannel {
    let connection: NWConnection
    let queue = DispatchQueue(label: "LocalLink.secure-channel", qos: .userInteractive)
    var onReady: (() -> Void)?
    var onPacket: ((WirePacket) -> Void)?
    var onClose: ((String) -> Void)?
    private var closed = false
    private var ready = false
    init(_ connection: NWConnection) { self.connection = connection }
    convenience init(host: String, port: UInt16, key: Data) { self.init(NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: LinkTLS.parameters(key: key))) }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready: self.ready = true; self.onReady?(); self.receiveHeader()
            case .failed(let error): self.finish("Connection failed: \(error.localizedDescription)")
            case .cancelled: self.finish("Disconnected")
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, !self.ready, !self.closed else { return }
            self.finish("Connection timed out. Check the host address, pairing key, and Tailscale connection.")
        }
    }
    func send(_ kind: PacketKind, _ data: Data = Data(), completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self, !self.closed, data.count < WirePacket.limit else { completion?(); return }
            self.connection.send(content: WirePacket(kind: kind, body: data).framed, completion: .contentProcessed { [weak self] error in
                completion?()
                if let error { self?.finish(error.localizedDescription) }
            })
        }
    }
    func sendJSON<T: Encodable>(_ kind: PacketKind, _ value: T) { if let data = try? JSONEncoder().encode(value) { send(kind, data) } }
    func cancel() { queue.async { [weak self] in self?.finish("Disconnected") } }
    private func finish(_ reason: String) {
        guard !closed else { return }; closed = true
        connection.cancel(); onClose?(reason)
        onReady = nil; onPacket = nil; onClose = nil
    }
    private func receiveHeader() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            guard error == nil, let data, data.count == 4, let length: UInt32 = data.integer(at: 0), length >= 1, length <= WirePacket.limit else { self.finish("Connection ended or invalid packet length."); return }
            self.receiveBody(Int(length))
        }
    }
    private func receiveBody(_ count: Int) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            guard error == nil, let data, data.count == count, let first = data.first, let kind = PacketKind(rawValue: first) else { self.finish("Connection ended or unsupported packet."); return }
            self.onPacket?(WirePacket(kind: kind, body: Data(data.dropFirst())))
            self.receiveHeader()
        }
    }
}

struct StreamRequest: Codable {
    var version = 1
    var width = 2560
    var height = 1440
    var fps = 60
    var mbps = 28
    var hevc = true
    var audio = true
    var valid: Bool { version == 1 && (640...3840).contains(width) && (360...2160).contains(height) && (15...60).contains(fps) && (4...80).contains(mbps) }
}
struct HostStatus: Codable { var text: String; var width: Int; var height: Int; var codec: String }
struct RemoteInput: Codable {
    var kind: String
    var x: Double = 0
    var y: Double = 0
    var code: UInt16 = 0
    var button: Int = 0
    var flags: UInt64 = 0
}

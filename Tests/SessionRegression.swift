import Foundation
import Network

@main enum ExperienceTests {
    @MainActor static func eventually(_ predicate: () -> Bool, timeout: TimeInterval = 15) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < end else { throw LinkError.message("Session regression timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        precondition(DisplayGeometry.capture(source: CGSize(width: 1920, height: 1080), maximum: CGSize(width: 3840, height: 2160)) == CGSize(width: 1920, height: 1080))
        precondition(DisplayGeometry.capture(source: CGSize(width: 5120, height: 2880), maximum: CGSize(width: 3840, height: 2160)) == CGSize(width: 3840, height: 2160))
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        precondition(DisplayGeometry.viewport(source: CGSize(width: 2000, height: 1000), bounds: bounds, scale: .fit, backing: 2) == CGRect(x: 0, y: 250, width: 1000, height: 500))
        precondition(DisplayGeometry.viewport(source: CGSize(width: 2000, height: 1000), bounds: bounds, scale: .fill, backing: 2) == CGRect(x: -500, y: 0, width: 2000, height: 1000))
        precondition(SessionHealth.retryDelay(attempt: 1) == 1 && SessionHealth.retryDelay(attempt: 99) == 15)
        precondition(!SessionHealth.timedOut(now: 1000, lastResponse: 999))
        print("PASS: native pixel fitting, fill/fit geometry, heartbeat and retry bounds")

        let keyText = try PairingKey.generate(), key = try PairingKey.decode(keyText)
        let listener = try NWListener(using: LinkTLS.parameters(key: key), on: .any)
        let fixture = SessionHostFixture()
        let queue = DispatchQueue(label: "experience.fake-host")
        listener.newConnectionHandler = { fixture.accept($0) }
        listener.start(queue: queue)
        try await eventually { (listener.port?.rawValue ?? 0) > 0 }
        let model = NativeModel(preview: true, port: listener.port!.rawValue); model.host = "127.0.0.1"; model.viewerKey = keyText; model.hevc = false
        for cycle in 0..<4 {
            print("Connecting cycle \(cycle + 1) to \(model.host):\(model.port)")
            model.connect()
            do { try await eventually { model.connected } }
            catch { print("Viewer status:", model.status, "Error:", model.error ?? "none", "Reason:", model.reconnectReason ?? "none", "Retry:", model.retryAttempt); throw error }
            model.disconnect(); precondition(!model.wantsConnection && model.viewerKey == keyText)
        }
        model.connect(); try await eventually { model.connected }
        print("PASS: native viewer connects/disconnects/reconnects four times with the same key")
        // No video frames are delivered. Pongs keep an unchanged desktop alive.
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 1_000_000_000); model.tick()
            precondition(model.connected && model.wantsConnection, "Idle desktop disconnected")
        }
        print("PASS: static desktop stays connected beyond the old 12-second video timeout")
        fixture.interrupt()
        try await eventually { model.reconnecting }
        try await eventually({ model.connected }, timeout: 8)
        precondition(model.viewerKey == keyText)
        print("PASS: interrupted native viewer automatically reconnects using its existing key")
        model.disconnect()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        precondition(!model.connected && !model.wantsConnection && !model.reconnecting)
        fixture.close(); listener.cancel()
        model.shutdown()
        print("PASS: explicit disconnect cancels reconnection; no Keychain writes, capture or input injection")
    }
}

final class SessionHostFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [LinkChannel] = []
    private var active: LinkChannel?
    func accept(_ connection: NWConnection) {
        let channel = LinkChannel(connection)
        lock.withLock { channels.append(channel) }
        channel.onPacket = { [weak self] packet in
            guard let self else { return }
            switch packet.kind {
            case .hello:
                let free = self.lock.withLock { () -> Bool in
                    guard self.active == nil else { return false }; self.active = channel; return true
                }
                if free { channel.sendJSON(.status, HostStatus(text: "Streaming", width: 1280, height: 720, codec: "H.264")) }
                else { channel.sendJSON(.status, HostStatus(text: "Previous session closing", width: 0, height: 0, codec: "", retryable: true)) { channel.cancel() } }
            case .ping: channel.send(.pong, packet.body)
            case .goodbye:
                self.lock.withLock { if self.active === channel { self.active = nil } }
                channel.send(.goodbyeAck) { channel.cancel() }
            default: break
            }
        }
        channel.onClose = { [weak self, weak channel] _ in guard let self else { return }; self.lock.withLock { if self.active === channel { self.active = nil } } }
        channel.start()
    }
    func interrupt() { lock.withLock { active }?.cancel() }
    func close() { let values = lock.withLock { channels }; values.forEach { $0.cancel() } }
}

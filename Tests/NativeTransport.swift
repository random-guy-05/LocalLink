import Foundation
import Network

@main enum NativeTransportTests {
    static func main() throws {
        setbuf(stdout, nil)
        let text = try PairingKey.generate(), key = try PairingKey.decode(text)
        precondition(key.count == 32)
        precondition((try? PairingKey.decode("1234")) == nil)
        var binary = Data(); binary.appendInteger(UInt32(0xdeadbeef))
        precondition(binary.integer(at: 0, as: UInt32.self) == 0xdeadbeef)
        precondition(binary.integer(at: 1, as: UInt32.self) == nil)
        var request = StreamRequest(); precondition(request.valid); request.width = 99999; precondition(!request.valid)
        let queue = DispatchQueue(label: "test.listener")
        let listener = try NWListener(using: LinkTLS.parameters(key: key), on: .any)
        let done = DispatchSemaphore(value: 0)
        let ready = DispatchSemaphore(value: 0)
        var accepted: [LinkChannel] = []
        listener.newConnectionHandler = { connection in
            let server = LinkChannel(connection)
            server.onClose = { reason in print("Server closed: \(reason)") }
            server.onPacket = { packet in server.send(packet.kind, packet.body) }
            accepted.append(server); server.start()
        }
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.start(queue: queue)
        precondition(ready.wait(timeout: .now() + 5) == .success, "Listener failed")
        let client = LinkChannel(host: "127.0.0.1", port: listener.port!.rawValue, key: key)
        client.onReady = { client.send(.ping, Data("native encrypted echo".utf8)) }
        client.onPacket = { packet in
            precondition(packet.kind == .ping && packet.body == Data("native encrypted echo".utf8))
            done.signal()
        }
        client.onClose = { reason in print("Client closed: \(reason)") }
        client.start()
        precondition(done.wait(timeout: .now() + 15) == .success, "TLS PSK round trip failed")
        print("PASS: TLS 1.2 AES-GCM PSK encrypted round trip")
        let rejected = DispatchSemaphore(value: 0)
        let invalid = LinkChannel(host: "127.0.0.1", port: listener.port!.rawValue, key: Data(repeating: 42, count: 32))
        invalid.onReady = { fatalError("Wrong key was accepted") }
        invalid.onClose = { _ in rejected.signal() }
        invalid.start()
        precondition(rejected.wait(timeout: .now() + 15) == .success, "Wrong key not rejected")
        print("PASS: wrong pairing key rejected before application data")
        client.cancel(); invalid.cancel(); listener.cancel()
        print("Native transport regressions passed.")
    }
}

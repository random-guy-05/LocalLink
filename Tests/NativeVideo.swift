import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox
import AVFoundation
import Network

@main enum NativeVideoTests {
    static func main() throws {
        for (hevc, width, height) in [(false, 1280, 720), (true, 2560, 1440), (true, 3840, 2160)] {
            var request = StreamRequest(); request.hevc = hevc
            let encoder = try NativeEncoder(width: width, height: height, request: request)
            let decoder = NativeDecoder()
            let received = DispatchSemaphore(value: 0)
            let listening = DispatchSemaphore(value: 0), authenticated = DispatchSemaphore(value: 0), serverReady = DispatchSemaphore(value: 0)
            let secret = try PairingKey.decode(PairingKey.generate())
            let listener = try NWListener(using: LinkTLS.parameters(key: secret), on: .any)
            var sender: LinkChannel?
            listener.newConnectionHandler = { connection in
                let channel = LinkChannel(connection); sender = channel
                channel.onReady = { serverReady.signal() }; channel.start()
            }
            listener.stateUpdateHandler = { state in if case .ready = state { listening.signal() } }
            listener.start(queue: DispatchQueue(label: "video-test.listener"))
            precondition(listening.wait(timeout: .now() + 5) == .success)
            let receiver = LinkChannel(host: "127.0.0.1", port: listener.port!.rawValue, key: secret)
            receiver.onReady = { authenticated.signal() }
            receiver.onPacket = { packet in
                precondition(packet.kind == .video)
                do { try decoder.decode(packet.body) } catch { fatalError(error.localizedDescription) }
            }
            receiver.start()
            precondition(authenticated.wait(timeout: .now() + 10) == .success)
            precondition(serverReady.wait(timeout: .now() + 10) == .success)
            var count = 0
            decoder.onPixels = { pixels in
                precondition(CVPixelBufferGetWidth(pixels) == width && CVPixelBufferGetHeight(pixels) == height)
                count += 1; received.signal()
            }
            encoder.onFrame = { data in
                sender?.send(.video, data)
            }
            encoder.onFailure = { reason in fatalError(reason) }
            for index in 0..<12 {
                var pixels: CVPixelBuffer?
                let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
                precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &pixels) == kCVReturnSuccess)
                let buffer = pixels!
                CVPixelBufferLockBaseAddress(buffer, [])
                memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 0), Int32(32 + index * 12), CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * height)
                memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * (height / 2))
                CVPixelBufferUnlockBaseAddress(buffer, [])
                encoder.encode(buffer, timestamp: CMTime(value: Int64(index), timescale: 60))
                precondition(received.wait(timeout: .now() + 5) == .success, "Hardware codec round trip timed out")
            }
            encoder.stop(); receiver.cancel(); sender?.cancel(); listener.cancel()
            receiver.queue.sync { decoder.stop() }
            precondition(count == 12)
            print("PASS: 12 synthetic \(width)×\(height) frames hardware encoded, sent through TLS, parsed and hardware decoded using \(hevc ? "HEVC" : "H.264")")
        }
        precondition((try? VideoFrame.decode(Data([1, 0, 0]))) == nil)
        var invalid = Data([0]); invalid.appendInteger(UInt16(65535)); invalid.appendInteger(UInt16(720)); invalid.append(2)
        precondition((try? VideoFrame.decode(invalid)) == nil)
        print("PASS: truncated and oversized video formats rejected")
        print("Native video regressions passed. No screen was captured.")
    }
}

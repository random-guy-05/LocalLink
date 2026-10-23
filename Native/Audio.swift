import AVFoundation

enum AudioPacket {
    /// Native 48 kHz stereo float PCM, bounded to 4096 frames per message.
    static func encode(_ sample: CMSampleBuffer) -> Data? {
        guard let format = sample.formatDescription, let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM, description.mBitsPerChannel == 32,
              description.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              description.mSampleRate == 48000, description.mChannelsPerFrame == 2 else { return nil }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= 4096 else { return nil }
        let buffers = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(buffers.unsafeMutablePointer) }
        var retained: CMBlockBuffer?
        let result = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil, bufferListOut: buffers.unsafeMutablePointer, bufferListSize: MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, blockBufferOut: &retained)
        guard result == noErr else { return nil }
        let planar = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard buffers.count == (planar ? 2 : 1) else { return nil }
        var data = Data(); data.appendInteger(UInt32(frames)); data.append(planar ? 1 : 0)
        for buffer in buffers {
            let expected = frames * 4 * (planar ? 1 : 2)
            guard let pointer = buffer.mData, Int(buffer.mDataByteSize) >= expected else { return nil }
            data.append(Data(bytes: pointer, count: expected))
        }
        return data
    }
}

// Audio engine calls and teardown belong to one channel queue; its completion count is locked.
final class NativeAudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
    private var started = false
    private let lock = NSLock()
    private var queued = 0
    init() { engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format) }
    func play(_ data: Data) throws {
        guard data.count >= 5, let raw: UInt32 = data.integer(at: 0), raw > 0, raw <= 4096, data[4] <= 1, data.count == 5 + Int(raw) * 8 else { throw LinkError.message("Invalid audio frame.") }
        if !started { try engine.start(); player.play(); started = true }
        lock.lock(); let full = queued >= 5; if !full { queued += 1 }; lock.unlock()
        guard !full else { return }
        let frames = Int(raw), planar = data[4] == 1
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: raw), let channels = buffer.floatChannelData else { lock.lock(); queued -= 1; lock.unlock(); return }
        buffer.frameLength = raw
        data.withUnsafeBytes { bytes in
            for frame in 0..<frames {
                for channel in 0..<2 {
                    let offset = 5 + (planar ? channel * frames + frame : frame * 2 + channel) * 4
                    channels[channel][frame] = bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)
                }
            }
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }; self.lock.lock(); self.queued -= 1; self.lock.unlock()
        }
    }
    func stop() { player.stop(); engine.stop(); started = false }
}

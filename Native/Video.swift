import Foundation
import ScreenCaptureKit
import VideoToolbox
import AVFoundation
import AppKit

struct VideoFrame {
    var hevc: Bool
    var width: Int
    var height: Int
    var parameters: [Data]
    var bytes: Data
    func encode() -> Data {
        var data = Data([hevc ? 1 : 0])
        data.appendInteger(UInt16(width)); data.appendInteger(UInt16(height))
        data.append(UInt8(parameters.count))
        for parameter in parameters { data.appendInteger(UInt16(parameter.count)); data.append(parameter) }
        data.append(bytes); return data
    }
    static func decode(_ data: Data) throws -> VideoFrame {
        guard data.count > 6, data[0] <= 1, let width: UInt16 = data.integer(at: 1), let height: UInt16 = data.integer(at: 3), width >= 16, width <= 5120, height >= 16, height <= 3200 else { throw LinkError.message("Invalid video dimensions.") }
        let count = Int(data[5]), hevc = data[0] == 1
        guard count == (hevc ? 3 : 2) else { throw LinkError.message("Invalid video format.") }
        var offset = 6, parameters: [Data] = []
        for _ in 0..<count {
            guard let length: UInt16 = data.integer(at: offset), length > 0, length <= 4096 else { throw LinkError.message("Invalid video parameter.") }
            offset += 2
            guard offset + Int(length) <= data.count else { throw LinkError.message("Incomplete video parameter.") }
            parameters.append(data.subdata(in: offset..<offset + Int(length))); offset += Int(length)
        }
        guard data.count > offset, data.count - offset <= WirePacket.limit else { throw LinkError.message("Invalid video frame.") }
        return VideoFrame(hevc: hevc, width: Int(width), height: Int(height), parameters: parameters, bytes: data.subdata(in: offset..<data.count))
    }
    func format() throws -> CMVideoFormatDescription {
        let allocations = parameters.map { parameter -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: parameter.count)
            parameter.copyBytes(to: pointer, count: parameter.count); return pointer
        }
        defer { allocations.forEach { $0.deallocate() } }
        let pointers = allocations.map { UnsafePointer($0) }
        let sizes = parameters.map(\.count)
        var result: CMFormatDescription?
        let status: OSStatus = pointers.withUnsafeBufferPointer { pp in sizes.withUnsafeBufferPointer { sp in
            if hevc { return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: pointers.count, parameterSetPointers: pp.baseAddress!, parameterSetSizes: sp.baseAddress!, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &result) }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: pointers.count, parameterSetPointers: pp.baseAddress!, parameterSetSizes: sp.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &result)
        } }
        guard status == noErr, let result else { throw LinkError.message("Could not read the video format (\(status)).") }
        return result
    }
}

func compressedSample(_ data: Data, format: CMFormatDescription) throws -> CMSampleBuffer {
    var block: CMBlockBuffer?
    let status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block)
    guard status == noErr, let block else { throw LinkError.message("Could not allocate a video frame.") }
    let copied = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
    guard copied == noErr else { throw LinkError.message("Could not copy video data.") }
    var sample: CMSampleBuffer?, size = data.count
    let made = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
    guard made == noErr, let sample else { throw LinkError.message("Could not prepare a video frame.") }; return sample
}

final class NativeEncoder {
    private var session: VTCompressionSession?
    let width: Int, height: Int, hevc: Bool
    var onFrame: ((Data) -> Void)?
    var onDrop: (() -> Void)?
    var onFailure: ((String) -> Void)?
    init(width: Int, height: Int, request: StreamRequest) throws {
        self.width = width; self.height = height; self.hevc = request.hevc
        let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264, encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: { ref, _, status, flags, sample in
            guard let ref else { return }
            let encoder = Unmanaged<NativeEncoder>.fromOpaque(ref).takeUnretainedValue()
            if status == noErr, flags.contains(.frameDropped) { encoder.onDrop?(); return }
            guard status == noErr, let sample else { encoder.onFailure?("Hardware encoding failed (\(status))."); return }
            encoder.output(sample)
        }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session)
        guard status == noErr, let session else { throw LinkError.message("Hardware \(hevc ? "HEVC" : "H.264") encoder is unavailable (\(status)). Try H.264.") }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ExpectedFrameRate: request.fps,
            kVTCompressionPropertyKey_AverageBitRate: request.mbps * 1_000_000,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: request.fps,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1,
            kVTCompressionPropertyKey_ProfileLevel: hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel
        ]
        for (key, value) in properties {
            let result = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            guard result == noErr else { stop(); throw LinkError.message("Hardware encoder rejected a required setting (\(result)).") }
        }
        // Optional quality hints: unsupported hints must not reject an otherwise
        // compatible hardware encoder. Real-time and no frame reordering stay required.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: NSNumber(value: 0.9))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanFalse)
        let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepared == noErr else { stop(); throw LinkError.message("Hardware encoder could not start (\(prepared)).") }
    }
    func encode(_ pixels: CVPixelBuffer, timestamp: CMTime) {
        guard let session else { onFailure?("Encoder stopped."); return }
        let result = VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: timestamp, duration: .invalid, frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
        if result != noErr { onFailure?("Video encoding failed (\(result)).") }
    }
    private func output(_ sample: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { onFailure?("Incomplete encoded frame."); return }
        var parameters: [Data] = []
        for index in 0..<(hevc ? 3 : 2) {
            var pointer: UnsafePointer<UInt8>?, length = 0, count = 0, header: Int32 = 0
            let result: OSStatus
            if hevc { result = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &length, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &header) }
            else { result = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &length, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &header) }
            guard result == noErr, let pointer, length > 0, length <= 4096, header == 4 else { onFailure?("Unsupported encoder format."); return }
            parameters.append(Data(bytes: pointer, count: length))
        }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length < WirePacket.limit - 16384 else { onFailure?("Encoded frame exceeded the transport limit."); return }
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard copied == noErr else { onFailure?("Could not read encoded frame."); return }
        onFrame?(VideoFrame(hevc: hevc, width: width, height: height, parameters: parameters, bytes: data).encode())
    }
    func stop() { if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(session) }; session = nil }
    deinit { stop() }
}

// Owned by exactly one LinkChannel queue, including teardown.
final class NativeDecoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameters: [Data] = []
    private var hevc = false
    var onPixels: ((CVPixelBuffer) -> Void)?
    func decode(_ bytes: Data) throws {
        let frame = try VideoFrame.decode(bytes)
        if parameters != frame.parameters || hevc != frame.hevc || session == nil {
            stop(); format = try frame.format(); parameters = frame.parameters; hevc = frame.hevc
            var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref, _, status, _, pixels, _, _ in
                guard status == noErr, let ref, let pixels else { return }
                Unmanaged<NativeDecoder>.fromOpaque(ref).takeUnretainedValue().onPixels?(pixels)
            }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
            let specification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
            let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format!, decoderSpecification: specification, imageBufferAttributes: attributes, outputCallback: &callback, decompressionSessionOut: &session)
            guard status == noErr else { throw LinkError.message("Hardware video decoding is unavailable (\(status)). Try H.264.") }
            VTSessionSetProperty(session!, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        }
        let sample = try compressedSample(frame.bytes, format: format!)
        let result = VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
        guard result == noErr else { throw LinkError.message("Video decoding failed (\(result)). Reconnect to reset the stream.") }
    }
    func stop() {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil; parameters = []
    }
    deinit { stop() }
}

// Lifecycle runs on main; all sample/encoder access after startup runs on sampleQueue.
final class NativeCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let sampleQueue = DispatchQueue(label: "LocalLink.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var encoder: NativeEncoder?
    private let permits = DispatchSemaphore(value: 2)
    private var channel: LinkChannel?
    var onFailure: ((String) -> Void)?
    var displayBounds = CGRect.zero
    private var stopping = false
    private var audioPending = 0
    @MainActor private var stopTask: Task<Void, Never>?
    @MainActor func start(request: StreamRequest, channel: LinkChannel) async throws -> HostStatus {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard stopTask == nil else { throw CancellationError() }
        guard let display = content.displays.first else { throw LinkError.message("No display is attached to the host Mac.") }
        displayBounds = CGDisplayBounds(display.displayID)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let source = CGSize(width: filter.contentRect.width * CGFloat(filter.pointPixelScale), height: filter.contentRect.height * CGFloat(filter.pointPixelScale))
        let size = DisplayGeometry.capture(source: source, maximum: CGSize(width: request.width, height: request.height))
        guard size.width >= 16, size.height >= 16 else { throw LinkError.message("The display reported an invalid capture size.") }
        let width = Int(size.width), height = Int(size.height)
        let encoder = try NativeEncoder(width: width, height: height, request: request)
        self.encoder = encoder; self.channel = channel
        encoder.onFrame = { [weak self, weak channel] frame in
            guard let self else { return }
            guard let channel else { self.permits.signal(); return }
            channel.send(.video, frame) { self.permits.signal() }
        }
        encoder.onFailure = { [weak self] reason in self?.permits.signal(); self?.onFailure?(reason) }
        encoder.onDrop = { [weak self] in self?.permits.signal() }
        let configuration = SCStreamConfiguration()
        configuration.captureResolution = .best
        configuration.width = width; configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(request.fps))
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = true
        configuration.capturesAudio = request.audio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000; configuration.channelCount = 2
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if request.audio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue) }
        do {
            try await stream.startCapture()
            try Task.checkCancellation()
            guard stopTask == nil else { throw CancellationError() }
        } catch {
            try? await stream.stopCapture()
            throw error
        }
        return HostStatus(text: "Streaming", width: width, height: height, codec: request.hevc ? "HEVC" : "H.264")
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure?(error.localizedDescription) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopping, sampleBuffer.isValid else { return }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]], let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete, let pixels = sampleBuffer.imageBuffer, permits.wait(timeout: .now()) == .success else { return }
            encoder?.encode(pixels, timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        } else if type == .audio, audioPending < 3, let packet = AudioPacket.encode(sampleBuffer) {
            audioPending += 1
            channel?.send(.audio, packet) { [weak self] in self?.sampleQueue.async { self?.audioPending -= 1 } }
        }
    }
    @MainActor func stop() async {
        if let stopTask { await stopTask.value; return }
        let task = Task { @MainActor in
            if let stream { try? await stream.stopCapture() }
            await withCheckedContinuation { continuation in sampleQueue.async { self.stopping = true; self.encoder?.stop(); self.encoder = nil; self.channel = nil; continuation.resume() } }
            self.stream = nil
        }
        stopTask = task; await task.value
    }
}

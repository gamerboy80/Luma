import AppKit
import AVFoundation
import VideoToolbox
import CoreVideo

// Owns the writer used by VideoToolbox's compressed-sample callback. All status
// checks are bounded; a failed writer cannot leave conversion spinning forever.
final class CompressedMovieWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let transform: CGAffineTransform
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private(set) var failure: Error?
    private(set) var count = 0
    init(url: URL, transform: CGAffineTransform) { self.url = url; self.transform = transform }
    func append(_ sample: CMSampleBuffer, status: OSStatus) {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil else { return }
        do {
            guard status == noErr, CMSampleBufferDataIsReady(sample) else { throw LumaError("HEVC encoder returned status \(status).") }
            if writer == nil {
                guard let format = CMSampleBufferGetFormatDescription(sample) else { throw LumaError("The encoder did not return a video format.") }
                let w = try AVAssetWriter(outputURL: url, fileType: .mov)
                let i = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
                i.expectsMediaDataInRealTime = false; i.transform = transform
                guard w.canAdd(i) else { throw LumaError("Cannot write this HEVC format to MOV.") }
                w.add(i); guard w.startWriting() else { throw w.error ?? LumaError("Could not start the MOV writer.") }
                w.startSession(atSourceTime: .zero); writer = w; input = i
            }
            guard let writer, let input else { throw LumaError("The video writer was not created.") }
            let deadline = Date().addingTimeInterval(15)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else { throw writer.error ?? LumaError("The MOV writer stopped accepting frames.") }
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard input.append(sample) else { throw writer.error ?? LumaError("Could not append an encoded video frame.") }
            count += 1
        } catch { failure = error; writer?.cancelWriting() }
    }
    func finish() async throws {
        if let failure { throw failure }
        guard let writer, let input, count > 0 else { throw LumaError("No video frames were encoded.") }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? LumaError("Finishing the movie failed.") }
    }
    func cancel() { writer?.cancelWriting() }
}

struct TemporalEncoder {
    static func encode(source: URL, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw LumaError("No video track was found.") }
        let size = try await track.load(.naturalSize); let nominalFPS = try await track.load(.nominalFrameRate)
        let transform = try await track.load(.preferredTransform); let duration = try await track.load(.timeRange).duration.seconds
        let fps = max(1, min(240, nominalFPS.isFinite && nominalFPS > 0 ? Int(nominalFPS.rounded()) : 30))
        let width = Int32(size.width); let height = Int32(size.height)
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { throw LumaError("Video dimensions are invalid or exceed 8192 pixels.") }
        let sink = CompressedMovieWriter(url: output, transform: transform)
        var session: VTCompressionSession?
        let callback: VTCompressionOutputCallback = { pointer, _, status, _, sample in
            guard let pointer, let sample else { return }
            Unmanaged<CompressedMovieWriter>.fromOpaque(pointer).takeUnretainedValue().append(sample, status: status)
        }
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: width, height: height, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: callback,
            refcon: Unmanaged.passUnretained(sink).toOpaque(), compressionSessionOut: &session)
        guard status == noErr, let session else { throw LumaError("Could not create the HEVC encoder (\(status)). HEVC Main10 support is required.") }
        defer { VTCompressionSessionInvalidate(session) }
        func set(_ key: CFString, _ value: CFTypeRef, required: Bool = true) throws {
            let result = VTSessionSetProperty(session, key: key, value: value)
            if required && result != noErr { throw LumaError("This Mac's encoder cannot set \(key) (\(result)). A generic HEVC file would be unreliable on the lock screen.") }
        }
        try set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main10_AutoLevel)
        try set(kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_AllowTemporalCompression, kCFBooleanTrue)
        try set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        try set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: max(8_000_000, Int(width) * Int(height) * fps / 8)))
        try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps * 2))
        try set("HEVCTemporalSubLayerAccess" as CFString, kCFBooleanTrue, required: false)
        try set("NumberOfTemporalLayers" as CFString, NSNumber(value: 2), required: false)
        try set(kVTCompressionPropertyKey_BaseLayerFrameRate, NSNumber(value: Double(fps) / 2))
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else { throw LumaError("The temporal HEVC encoder could not prepare.") }
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw LumaError("The source cannot be decoded to 10-bit frames.") }
        reader.add(readerOutput); guard reader.startReading() else { throw reader.error ?? LumaError("Could not read the video.") }
        guard duration.isFinite, duration > 0 else { throw LumaError("The video track has no finite duration.") }
        let totalFrames = max(1, Int64((duration * Double(fps)).rounded()))
        var index: Int64 = 0
        var firstPTS: CMTime?
        var previousBuffer: CVPixelBuffer?
        func encodeFrame(_ buffer: CVPixelBuffer) throws {
            try Task.checkCancellation()
            if let failure = sink.failure { throw failure }
            let result = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: index, timescale: Int32(fps)), duration: CMTime(value: 1, timescale: Int32(fps)), frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
            guard result == noErr else { throw LumaError("HEVC frame encoding failed (\(result)).") }
            index += 1
            if index % 15 == 0 { progress(min(0.98, Double(index) / Double(totalFrames))) }
        }
        do {
            while let sample = readerOutput.copyNextSampleBuffer() {
                try Task.checkCancellation()
                if let failure = sink.failure { throw failure }
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw LumaError("A decoded frame had no image buffer.") }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if firstPTS == nil { firstPTS = pts }
                let normalized = CMTimeSubtract(pts, firstPTS!).seconds
                if let previousBuffer, normalized.isFinite {
                    let boundary = min(totalFrames, max(0, Int64((normalized * Double(fps)).rounded())))
                    while index < boundary { try encodeFrame(previousBuffer) }
                }
                previousBuffer = buffer
            }
            guard reader.status == .completed else { throw reader.error ?? LumaError("Video decoding was interrupted.") }
            if let previousBuffer { while index < totalFrames { try encodeFrame(previousBuffer) } }
            let completion = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            guard completion == noErr else { throw LumaError("The encoder could not finish its pending frames.") }
            try await sink.finish(); try Task.checkCancellation()
            // Never install an ordinary encode if the required temporal groups are absent.
            let data = try Data(contentsOf: output, options: .mappedIfSafe)
            guard MovieMetadata.temporalGroups(in: data).isSuperset(of: ["tscl", "tsas"]) else { throw LumaError("The encoder did not produce Apple's temporal sample groups. The movie was not installed.") }
            progress(1)
        } catch { reader.cancelReading(); sink.cancel(); try? FileManager.default.removeItem(at: output); throw error }
    }
}

@MainActor final class SceneMovieExporter {
    static func export(host: SceneHost, output: URL, seconds: Int, fps: Int, width: Int, height: Int, progress: (Double) -> Void) async throws {
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey:width, AVVideoHeightKey:height])
        guard writer.canAdd(input) else { throw LumaError("The scene video encoder is unavailable.") }
        host.setPlaying(false)
        do {
            if #available(macOS 27.0, *) {
                let attributes = CVPixelBufferCreationAttributes(
                    pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
                    size: CVImageSize(width: width, height: height)
                )
                let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
                try writer.start()
                writer.startSession(atSourceTime: .zero)
                let poolAttributes: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferCGImageCompatibilityKey as String: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
                ]
                var pool: CVPixelBufferPool?
                guard CVPixelBufferPoolCreate(nil, nil, poolAttributes as CFDictionary, &pool) == kCVReturnSuccess,
                      let pool else { throw LumaError("This wallpaper cannot allocate export frames.") }
                for frame in 0..<(seconds * fps) {
                    try Task.checkCancellation()
                    let data = try await host.capture(time: Double(frame) / Double(fps), width: width, height: height)
                    let pixel = try makePixelBuffer(from: data, pool: pool, width: width, height: height)
                    let readOnlyPixel = CVReadOnlyPixelBuffer(unsafeBuffer: pixel)
                    try await receiver.append(readOnlyPixel, with: CMTime(value: Int64(frame), timescale: Int32(fps)))
                    progress(Double(frame + 1) / Double(seconds * fps))
                }
                receiver.finish()
            } else {
                input.expectsMediaDataInRealTime = false
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: input,
                    sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true]
                )
                writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? LumaError("Could not start recording.") }
                writer.startSession(atSourceTime: .zero)
                guard let pool = adaptor.pixelBufferPool else { throw LumaError("This wallpaper cannot export frames.") }
                for frame in 0..<(seconds * fps) {
                    try Task.checkCancellation()
                    let data = try await host.capture(time: Double(frame) / Double(fps), width: width, height: height)
                    let pixel = try makePixelBuffer(from: data, pool: pool, width: width, height: height)
                    let deadline = Date().addingTimeInterval(15)
                    while !input.isReadyForMoreMediaData {
                        try Task.checkCancellation()
                        guard writer.status == .writing, Date() < deadline else { throw writer.error ?? LumaError("Video recording stalled.") }
                        try await Task.sleep(for: .milliseconds(3))
                    }
                    guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))) else { throw writer.error ?? LumaError("Could not encode this scene frame.") }
                    progress(Double(frame + 1) / Double(seconds * fps))
                }
                input.markAsFinished()
            }
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? LumaError("The scene video could not be completed.") }
        } catch { writer.cancelWriting(); try? FileManager.default.removeItem(at: output); throw error }
    }

    private static func makePixelBuffer(from data: Data, pool: CVPixelBufferPool, width: Int, height: Int) throws -> CVPixelBuffer {
        guard let image = NSBitmapImageRep(data: data)?.cgImage else { throw LumaError("This wallpaper cannot export frames.") }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else { throw LumaError("Could not allocate a video frame.") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw LumaError("Could not draw a scene frame.") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }
}

// Parse grouping records inside the sample table; strings in compressed frame data
// cannot masquerade as temporal metadata.
enum MovieMetadata {
    static func temporalGroups(in data: Data) -> Set<String> {
        var groups = Set<String>()
        func number(_ start: Int, _ count: Int) -> UInt64 {
            guard start >= 0, start + count <= data.count else { return 0 }
            return data[start..<(start + count)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        func walk(_ start: Int, _ end: Int, _ depth: Int) {
            guard depth < 12 else { return }
            var position = start
            while position <= end - 8 {
                let basic = number(position, 4)
                let header = basic == 1 ? 16 : 8
                let length = basic == 1 ? number(position + 8, 8) : (basic == 0 ? UInt64(end - position) : basic)
                guard length >= UInt64(header), length <= UInt64(end - position) else { return }
                let type = String(decoding: data[(position + 4)..<(position + 8)], as: UTF8.self)
                let payload = position + header, boxEnd = position + Int(length)
                if ["moov", "trak", "mdia", "minf", "stbl"].contains(type) { walk(payload, boxEnd, depth + 1) }
                else if ["sgpd", "csgm"].contains(type), payload + 8 <= boxEnd {
                    groups.insert(String(decoding: data[(payload + 4)..<(payload + 8)], as: UTF8.self))
                }
                position = boxEnd
            }
        }
        walk(0, data.count, 0)
        return groups
    }
}

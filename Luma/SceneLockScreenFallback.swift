import Foundation
import AppKit
import AVFoundation

enum SceneLockScreenMode: String, CaseIterable, Identifiable {
    case automatic, sourceMedia, snapshot
    var id: Self { self }
    var title: String { switch self { case .automatic: "Render loop with fallback"; case .sourceMedia: "Use scene video or image"; case .snapshot: "Capture a still frame" } }
}

/// Builds a still image for the standard System Settings wallpaper picker.
/// macOS does not expose a public API to select a lock-screen-only photo, so this
/// type only creates a preview file and never calls NSWorkspace's desktop setter.
@MainActor enum SceneStaticFallback {
    static func image(wallpaper: Wallpaper, folder: URL, mediaURL: URL, assets: URL?, preferences: AppPreferences) async throws -> (Data, String) {
        switch wallpaper.kind {
        case .image:
            return (try normalizedImage(Data(contentsOf: mediaURL)), "Source image")
        case .video:
            let (png, _) = try await videoFrame(mediaURL)
            return (png, "Video frame")
        case .scene:
            return try await sceneImage(wallpaper: wallpaper, folder: folder, assets: assets, preferences: preferences)
        case .web:
            throw LumaError("A web wallpaper has no offline static fallback. Export or import an image first.")
        }
    }

    private static func sceneImage(wallpaper: Wallpaper, folder: URL, assets: URL?, preferences: AppPreferences) async throws -> (Data, String) {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Luma-static-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var host: SceneHost?
        var window: NSWindow?
        var hostFailure: String?
        defer { host?.stop(); window?.orderOut(nil); window?.close() }

        func makeHost() -> SceneHost {
            if let host { return host }
            let scene = SceneHost(folder: folder, assets: assets, wallpaper: wallpaper,
                                  configuration: DisplayConfiguration(), preferences: preferences)
            host = scene
            let renderWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 720), styleMask: .borderless, backing: .buffered, defer: false)
            renderWindow.isReleasedWhenClosed = false
            renderWindow.ignoresMouseEvents = true
            renderWindow.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            renderWindow.contentView = scene.webView
            renderWindow.alphaValue = 0
            renderWindow.orderFront(nil)
            window = renderWindow
            scene.setPlaying(false)
            scene.failed = { hostFailure = $0 }
            return scene
        }

        func readyHost() async throws -> SceneHost {
            let scene = makeHost()
            let deadline = Date().addingTimeInterval(45)
            while !scene.didBecomeReady {
                try Task.checkCancellation()
                if let hostFailure { throw LumaError(hostFailure) }
                guard Date() < deadline else { throw LumaError("The scene renderer did not finish loading for the static fallback.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            return scene
        }

        let candidates = try SceneMediaDiscovery.candidates(folder: folder, entry: wallpaper.entry, preview: wallpaper.preview)
        var textureVideos: [URL] = []

        // Prefer a source image. A texture can be a still image or an embedded video.
        for (index, candidate) in candidates.enumerated() where !candidate.isPreview && !candidate.isVideo {
            try Task.checkCancellation()
            do {
                let bytes = try candidate.bytes()
                if candidate.ext == "tex" {
                    let scene = try await readyHost()
                    let decoded = try await scene.decodeTextureMedia(bytes)
                    if decoded.isVideo {
                        let url = work.appendingPathComponent("texture-\(index).mp4")
                        try decoded.data.write(to: url, options: .atomic)
                        textureVideos.append(url)
                    } else {
                        return (try normalizedImage(decoded.data), "Scene source image: \(candidate.name)")
                    }
                } else {
                    return (try normalizedImage(bytes), "Scene source image: \(candidate.name)")
                }
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }

        // If there is no usable still image, use a representative frame from a scene video.
        for (index, candidate) in candidates.enumerated() where candidate.isVideo && !candidate.isPreview {
            try Task.checkCancellation()
            do {
                let url: URL
                if let file = candidate.file { url = file }
                else { url = work.appendingPathComponent("source-\(index).\(candidate.ext)"); try candidate.bytes().write(to: url, options: .atomic) }
                let (png, _) = try await videoFrame(url)
                return (png, "Scene video frame: \(candidate.name)")
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        for url in textureVideos {
            do { let (png, _) = try await videoFrame(url); return (png, "Scene texture video frame") }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
        }

        // A live scene capture preserves effects and layered composition when its
        // package contains no source still or video.
        do {
            let scene = try await readyHost()
            let capture = try await scene.capture(time: 0, width: 1920, height: 1080)
            return (try normalizedImage(capture), "Captured rendered scene")
        } catch is CancellationError { throw CancellationError() }
        catch { hostFailure = error.localizedDescription }

        // A project preview is the last available image if rendering cannot start.
        for candidate in candidates where candidate.isPreview && !candidate.isVideo {
            do {
                let bytes = try candidate.bytes()
                if candidate.ext == "tex" {
                    let scene = try await readyHost()
                    let decoded = try await scene.decodeTextureMedia(bytes)
                    if !decoded.isVideo { return (try normalizedImage(decoded.data), "Scene preview: \(candidate.name)") }
                } else { return (try normalizedImage(bytes), "Scene preview: \(candidate.name)") }
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        throw LumaError("No source image, video frame, rendered frame, or usable preview was available. \(hostFailure ?? "")")
    }

    private static func normalizedImage(_ bytes: Data) throws -> Data {
        guard let bitmap = NSBitmapImageRep(data: bytes), let png = bitmap.representation(using: .png, properties: [:]) else {
            throw LumaError("This wallpaper image could not be decoded as a still image.")
        }
        return png
    }

    private static func videoFrame(_ url: URL) async throws -> (Data, String) {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else { throw LumaError("The scene video is not playable on this Mac.") }
        let duration = try await asset.load(.duration).seconds
        let seconds = duration.isFinite && duration > 0 ? min(max(duration * 0.2, 0.1), max(duration - 0.1, 0.1)) : 0.5
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 3840, height: 2160)
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw LumaError("macOS could not extract a representative frame from the scene video.")
        }
        return (data, "Video frame")
    }
}

// Archive names are never used as extraction destinations. Loose files go through
// the same containment/symlink checks as the desktop resource server.
struct SceneMediaCandidate {
    let name: String
    let file: URL?
    let archive: Data?
    let range: Range<Int>?
    let isPreview: Bool
    var ext: String { (name as NSString).pathExtension.lowercased() }
    var isVideo: Bool { ["mp4", "mov", "m4v", "webm"].contains(ext) }
    var priority: Int {
        let lower = name.lowercased()
        if isPreview { return -100 }
        var score = isVideo ? 100 : 0
        if ["background", "wallpaper", "/bg.", "main."].contains(where: { lower.contains($0) }) { score += 30 }
        if ["mask", "normal", "depth", "noise", "icon", "thumbnail"].contains(where: { lower.contains($0) }) { score -= 80 }
        return score
    }
    func bytes() throws -> Data {
        if let file { return try Data(contentsOf: file, options: .mappedIfSafe) }
        guard let archive, let range else { throw LumaError("The scene media is missing.") }
        return archive.subdata(in: range)
    }
}

enum SceneMediaDiscovery {
    static let extensions = Set(["mp4", "mov", "m4v", "webm", "png", "jpg", "jpeg", "heic", "webp", "gif", "bmp", "tex"])
    static func candidates(folder: URL, entry: String, preview: String?) throws -> [SceneMediaCandidate] {
        var results: [SceneMediaCandidate] = []
        if let enumerator = FileManager.default.enumerator(atPath: folder.path) {
            for case let relative as String in enumerator {
                try Task.checkCancellation()
                if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { enumerator.skipDescendants(); continue }
                guard let safe = try? Safety.child(relative, under: folder), (try? safe.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                if extensions.contains(safe.pathExtension.lowercased()) {
                    results.append(SceneMediaCandidate(name: relative, file: safe, archive: nil, range: nil, isPreview: isPreview(relative, declared: preview)))
                }
            }
        }
        var packages = [entry, "scene.pkg", "scenes/scene.pkg", "gifscene.pkg"].filter { $0.lowercased().hasSuffix(".pkg") }
        packages = Array(Set(packages)).sorted()
        for package in packages {
            guard let url = try? Safety.child(package, under: folder), FileManager.default.fileExists(atPath: url.path) else { continue }
            // A bad package must not prevent a loose image/preview from being used.
            if let bytes = try? Data(contentsOf: url, options: .mappedIfSafe), let embedded = try? archiveCandidates(bytes) { results += embedded }
        }
        return results.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            let aSize = a.range?.count ?? ((try? a.file?.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let bSize = b.range?.count ?? ((try? b.file?.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return aSize != bSize ? aSize > bSize : a.name < b.name
        }
    }
    static func isPreview(_ name: String, declared: String?) -> Bool {
        name == declared || (name as NSString).lastPathComponent.lowercased().hasPrefix("preview.")
    }
    static func archiveCandidates(_ data: Data) throws -> [SceneMediaCandidate] {
        try archiveEntries(data).filter { extensions.contains($0.ext) }
    }
    static func archiveEntries(_ data: Data) throws -> [SceneMediaCandidate] {
        var cursor = 0
        func uint32() throws -> Int {
            guard cursor <= data.count - 4 else { throw LumaError("The scene package header is truncated.") }
            let value = data[cursor..<(cursor + 4)].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            cursor += 4; return Int(value)
        }
        func string(_ length: Int) throws -> String {
            guard length > 0, length <= 4096, cursor <= data.count - length else { throw LumaError("The scene package has an invalid filename.") }
            defer { cursor += length }
            return String(decoding: data[cursor..<(cursor + length)], as: UTF8.self)
        }
        let magic = try string(uint32())
        guard magic.count == 8, magic.hasPrefix("PKGV") else { throw LumaError("Unknown scene package format.") }
        let count = try uint32()
        guard count <= 100_000 else { throw LumaError("The scene package has too many entries.") }
        var entries: [(String, Int, Int)] = []
        for _ in 0..<count {
            let name = try string(uint32()); let offset = try uint32(); let size = try uint32()
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"), !name.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { throw LumaError("The scene package contains an unsafe path.") }
            entries.append((name, offset, size))
        }
        let start = cursor
        return try entries.map { name, offset, size in
            guard offset <= data.count - start, size <= data.count - start - offset else { throw LumaError("A scene package entry extends beyond its data.") }
            return SceneMediaCandidate(name: name, file: nil, archive: data, range: (start + offset)..<(start + offset + size), isPreview: isPreview(name, declared: nil))
        }
    }
}

enum StillMovieExporter {
    // A constant image in a short movie uses the existing native Aerials path.
    // It remains visually still, including during macOS lock/unlock transitions.
    static func export(imageData: Data, output: URL) async throws {
        guard let bitmap = NSBitmapImageRep(data: imageData), let image = bitmap.cgImage else { throw LumaError("This image cannot be decoded.") }
        let scale = min(1, 3840 / Double(max(image.width, image.height)))
        let width = max(2, Int(Double(image.width) * scale) / 2 * 2)
        let height = max(2, Int(Double(image.height) * scale) / 2 * 2)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        guard writer.canAdd(input) else { throw LumaError("Cannot prepare a still wallpaper movie.") }
        writer.add(input); guard writer.startWriting() else { throw writer.error ?? LumaError("Cannot start the still wallpaper writer.") }; writer.startSession(atSourceTime: .zero)
        do {
            guard let pool = adaptor.pixelBufferPool else { throw LumaError("Cannot allocate the still wallpaper frame.") }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { throw LumaError("Cannot allocate the still wallpaper frame.") }
            CVPixelBufferLockBaseAddress(pixel, []); defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw LumaError("Cannot draw the still wallpaper frame.") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            for frame in 0..<60 {
                try Task.checkCancellation()
                let deadline = Date().addingTimeInterval(15)
                while !input.isReadyForMoreMediaData { try Task.checkCancellation(); guard writer.status == .writing, Date() < deadline else { throw writer.error ?? LumaError("The still wallpaper writer stalled.") }; try await Task.sleep(for: .milliseconds(3)) }
                guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error ?? LumaError("Cannot write a still wallpaper frame.") }
            }
            input.markAsFinished(); await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? LumaError("Cannot finish the still wallpaper movie.") }
        } catch { writer.cancelWriting(); try? FileManager.default.removeItem(at: output); throw error }
    }
}

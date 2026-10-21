import AppKit
import Combine
import WebKit
import UniformTypeIdentifiers
import ImageIO
import CryptoKit
import Darwin

private final class WallpaperSchemeRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

private final class WallpaperResourceQueue: @unchecked Sendable {
    static let shared = WallpaperResourceQueue()
    private let queue: OperationQueue
    private init() {
        queue = OperationQueue()
        queue.name = "dev.patrick.Luma.wallpaper-resources"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 4
    }
    func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

private struct PreparedWallpaperResource: @unchecked Sendable {
    enum Body: Sendable { case data(Data); case fileDescriptor(Int32) }
    let mime: String
    let size: Int
    let body: Body
}

// A per-instance resource origin. Only this wallpaper, the renderer, and explicitly
// selected shared engine assets are exposed. No filesystem bridge is injected.
@MainActor final class WallpaperScheme: NSObject, WKURLSchemeHandler {
    nonisolated private static let maxResourceBytes = 2 * 1024 * 1024 * 1024
    nonisolated private static let streamThreshold = 4 * 1024 * 1024
    nonisolated private static let streamChunkBytes = 1024 * 1024
    let project: URL
    let assets: URL?
    let resources: URL?
    var resourceFailure: ((String) -> Void)?
    private var approvedScriptResources: [String: String]?
    private var activeRequests: [ObjectIdentifier: WallpaperSchemeRequest] = [:]
    init(project: URL, assets: URL?, resources: URL? = nil) { self.project = project; self.assets = assets; self.resources = resources }
    func setApprovedScriptResources(_ value: [String: String]?) { approvedScriptResources = value }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask as AnyObject)
        let request = WallpaperSchemeRequest()
        activeRequests[key]?.cancel()
        activeRequests[key] = request
        let url = urlSchemeTask.request.url
        let project = self.project, assets = self.assets, resources = self.resources
        let approved = approvedScriptResources
        Task { @MainActor [weak self] in
            guard let self else { request.cancel(); return }
            await self.serve(url, task: urlSchemeTask, key: key, request: request,
                             project: project, assets: assets, resources: resources, approved: approved)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask as AnyObject)
        activeRequests.removeValue(forKey: key)?.cancel()
    }

    private func serve(_ url: URL?, task: WKURLSchemeTask, key: ObjectIdentifier,
                       request: WallpaperSchemeRequest, project: URL, assets: URL?, resources: URL?,
                       approved: [String: String]?) async {
        do {
            let prepared = try await WallpaperResourceQueue.shared.run {
                try Self.prepare(url, project: project, assets: assets, resources: resources,
                                 approved: approved, request: request)
            }
            guard isActive(key, request), let url else {
                if case .fileDescriptor(let descriptor) = prepared.body { Darwin.close(descriptor) }
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": prepared.mime,
                "Content-Length": String(prepared.size),
                "Access-Control-Allow-Origin": "*",
            ])!
            task.didReceive(response)
            switch prepared.body {
            case .data(let data):
                if !data.isEmpty, isActive(key, request) { task.didReceive(data) }
            case .fileDescriptor(let descriptor):
                defer { Darwin.close(descriptor) }
                var offset = 0
                while offset < prepared.size {
                    guard isActive(key, request) else { return }
                    let count = min(Self.streamChunkBytes, prepared.size - offset)
                    let chunkOffset = offset
                    let chunk = try await WallpaperResourceQueue.shared.run {
                        try Self.readChunk(descriptor, offset: chunkOffset, count: count, request: request)
                    }
                    guard isActive(key, request) else { return }
                    guard !chunk.isEmpty else { throw LumaError("Wallpaper resource ended before its advertised size.") }
                    task.didReceive(chunk)
                    offset += chunk.count
                }
            }
            guard isActive(key, request) else { return }
            task.didFinish()
            activeRequests.removeValue(forKey: key)
        } catch {
            guard isActive(key, request) else { return }
            resourceFailure?(error.localizedDescription)
            task.didFailWithError(error)
            activeRequests.removeValue(forKey: key)
        }
    }

    private func isActive(_ key: ObjectIdentifier, _ request: WallpaperSchemeRequest) -> Bool {
        activeRequests[key] === request && !request.isCancelled
    }

    nonisolated private static func prepare(_ url: URL?, project: URL, assets: URL?, resources: URL?,
                                            approved: [String: String]?, request: WallpaperSchemeRequest) throws -> PreparedWallpaperResource {
        guard !request.isCancelled else { throw CancellationError() }
        guard let url, url.host == "wallpaper" else { throw LumaError("Unknown wallpaper origin.") }
        try Safety.validateDirectoryIfPresent(project)
        let path = url.path
        if path == "/api/local-assets" {
            let info: [String: Any] = assets == nil ? ["ok": false] : ["ok": true, "roots": [["id":"owned","dir":"assets"]]]
            return prepared(Data(Safety.json(info).utf8), mime: "application/json")
        }
        if path == "/api/local-assets/owned/materials/index.json", let assets {
            let materialRoot = assets.appendingPathComponent("materials")
            var names: [String] = []
            if let items = FileManager.default.enumerator(at: materialRoot, includingPropertiesForKeys: nil) {
                for case let file as URL in items where file.pathExtension == "tex" {
                    guard !request.isCancelled else { throw CancellationError() }
                    names.append(String(file.deletingPathExtension().path.dropFirst(materialRoot.path.count + 1)))
                }
            }
            return prepared(Data(Safety.json(["names": names]).utf8), mime: "application/json")
        }

        let file: URL
        let root: URL
        if path.hasPrefix("/app/") {
            let name = String(path.dropFirst(5))
            guard ["renderer.html", "webwallgl.js"].contains(name),
                  let bundled = resources?.appendingPathComponent(name) ?? Bundle.main.url(forResource: name, withExtension: nil) else {
                throw LumaError("Renderer resources are missing.")
            }
            file = bundled; root = bundled.deletingLastPathComponent()
        } else if path.hasPrefix("/project/") {
            root = project; file = try Safety.child(String(path.dropFirst(9)), under: project)
        } else if path.hasPrefix("/api/local-assets/owned/"), let assets {
            root = assets; file = try Safety.child(String(path.dropFirst(24)), under: assets)
        } else { throw LumaError("Resource not available.") }

        let opened = try openRegularResource(file, under: root)
        let ext = file.pathExtension.lowercased()
        let relative = path.hasPrefix("/project/") ? String(path.dropFirst(9)) : nil
        let needsFingerprint = relative != nil && approved != nil && ["pkg", "json", "js", "mjs", "cjs", "scenescript"].contains(ext)
        if needsFingerprint {
            guard let relative, let expected = approved?[relative] else {
                Darwin.close(opened.fd)
                throw LumaError("SceneScript was disabled because \(relative ?? file.lastPathComponent) was not present during review.")
            }
            if opened.size > streamThreshold {
                do {
                    // Hash and copy the exact reviewed bytes into an anonymous
                    // file descriptor so large packages do not need a second
                    // full-size in-memory copy before they can be streamed.
                    let snapshot = try verifiedResourceSnapshot(opened.fd, size: opened.size,
                                                                 expected: expected, relative: relative, request: request)
                    Darwin.close(opened.fd)
                    return PreparedWallpaperResource(mime: mimeType(file), size: opened.size, body: .fileDescriptor(snapshot))
                } catch {
                    Darwin.close(opened.fd)
                    throw error
                }
            }
            let data: Data
            do { data = try readResource(opened.fd, size: opened.size, request: request) }
            catch { Darwin.close(opened.fd); throw error }
            Darwin.close(opened.fd)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                throw LumaError("SceneScript was disabled because \(relative) changed after review. Review the current scene source before enabling scripts again.")
            }
            return prepared(data, mime: mimeType(file))
        }
        if opened.size > streamThreshold {
            return PreparedWallpaperResource(mime: mimeType(file), size: opened.size, body: .fileDescriptor(opened.fd))
        }
        do {
            let data = try readResource(opened.fd, size: opened.size, request: request)
            Darwin.close(opened.fd)
            return prepared(data, mime: mimeType(file))
        } catch {
            Darwin.close(opened.fd)
            throw error
        }
    }

    nonisolated private static func prepared(_ data: Data, mime: String) -> PreparedWallpaperResource {
        PreparedWallpaperResource(mime: mime, size: data.count, body: .data(data))
    }

    nonisolated private static func mimeType(_ file: URL) -> String {
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return file.pathExtension.lowercased() == "js" ? "text/javascript" : type
    }

    nonisolated private static func openRegularResource(_ url: URL, under root: URL) throws -> (fd: Int32, size: Int) {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard urlPath.hasPrefix(prefix) else { throw LumaError("Wallpaper resource \(url.lastPathComponent) is outside its approved folder.") }
        let relative = String(urlPath.dropFirst(prefix.count))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LumaError("Wallpaper resource \(url.lastPathComponent) has an unsafe path.")
        }
        // Open the root once, then resolve every child relative to that held
        // descriptor. Replacing a checked parent with a symlink cannot redirect
        // this read outside the wallpaper or selected assets folder.
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedRoot.path.hasPrefix("/") else { throw LumaError("The wallpaper resource root is invalid.") }
        var directoryFD = resolvedRoot.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard directoryFD >= 0 else { throw LumaError("Could not open the wallpaper resource root safely: \(String(cString: strerror(Darwin.errno))).") }
        defer { Darwin.close(directoryFD) }
        for component in components.dropLast() {
            let next = component.withCString { Darwin.openat(directoryFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
            guard next >= 0 else { throw LumaError("Could not open wallpaper resource folder \(component) safely: \(String(cString: strerror(Darwin.errno))).") }
            Darwin.close(directoryFD)
            directoryFD = next
        }
        let descriptor = components.last!.withCString { Darwin.openat(directoryFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw LumaError("Could not open wallpaper resource \(url.lastPathComponent) safely: \(String(cString: strerror(Darwin.errno))).") }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            Darwin.close(descriptor)
            throw LumaError("Wallpaper resource \(url.lastPathComponent) is not a regular file.")
        }
        guard metadata.st_size >= 0, metadata.st_size <= off_t(maxResourceBytes), metadata.st_size <= off_t(Int.max) else {
            Darwin.close(descriptor)
            throw LumaError("Wallpaper resource \(url.lastPathComponent) exceeds Luma's 2 GiB renderer limit.")
        }
        return (descriptor, Int(metadata.st_size))
    }

    nonisolated private static func readResource(_ descriptor: Int32, size: Int, request: WallpaperSchemeRequest) throws -> Data {
        var result = Data(capacity: size)
        var offset = 0
        while offset < size {
            guard !request.isCancelled else { throw CancellationError() }
            let chunk = try readChunk(descriptor, offset: offset, count: min(streamChunkBytes, size - offset), request: request)
            guard !chunk.isEmpty else { throw LumaError("Wallpaper resource ended before its advertised size.") }
            result.append(chunk)
            offset += chunk.count
        }
        return result
    }

    nonisolated private static func verifiedResourceSnapshot(_ source: Int32, size: Int, expected: String,
                                                             relative: String, request: WallpaperSchemeRequest) throws -> Int32 {
        let temporaryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("luma-reviewed-resource-XXXXXX")
        var template = Array(temporaryURL.path.utf8CString)
        let snapshot = template.withUnsafeMutableBufferPointer { Darwin.mkstemp($0.baseAddress!) }
        guard snapshot >= 0 else {
            throw LumaError("Could not create a temporary scene resource snapshot: \(String(cString: strerror(Darwin.errno))).")
        }
        var path = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        defer {
            if !path.isEmpty { path.withCString { _ = Darwin.unlink($0) } }
        }
        guard path.withCString({ Darwin.unlink($0) }) == 0 else {
            let error = LumaError("Could not safely unlink the temporary scene resource snapshot: \(String(cString: strerror(Darwin.errno))).")
            Darwin.close(snapshot)
            throw error
        }
        path = ""
        let descriptorFlags = Darwin.fcntl(snapshot, F_GETFD)
        guard descriptorFlags >= 0, Darwin.fcntl(snapshot, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            let message = String(cString: strerror(Darwin.errno))
            Darwin.close(snapshot)
            throw LumaError("Could not secure the temporary scene resource snapshot: \(message).")
        }
        var keepSnapshot = false
        defer { if !keepSnapshot { Darwin.close(snapshot) } }

        var hasher = SHA256()
        var offset = 0
        while offset < size {
            guard !request.isCancelled else { throw CancellationError() }
            let chunk = try readChunk(source, offset: offset, count: min(streamChunkBytes, size - offset), request: request)
            guard !chunk.isEmpty else { throw LumaError("Wallpaper resource ended before its advertised size.") }
            hasher.update(data: chunk)
            try chunk.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { throw LumaError("Could not copy the reviewed scene resource.") }
                var written = 0
                while written < buffer.count {
                    guard !request.isCancelled else { throw CancellationError() }
                    let result = Darwin.write(snapshot, base.advanced(by: written), buffer.count - written)
                    if result < 0 && Darwin.errno == EINTR { continue }
                    guard result > 0 else {
                        throw LumaError("Could not snapshot the reviewed scene resource: \(String(cString: strerror(Darwin.errno))).")
                    }
                    written += result
                }
            }
            offset += chunk.count
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw LumaError("SceneScript was disabled because \(relative) changed after review. Review the current scene source before enabling scripts again.")
        }
        keepSnapshot = true
        return snapshot
    }

    nonisolated private static func readChunk(_ descriptor: Int32, offset: Int, count: Int,
                                              request: WallpaperSchemeRequest) throws -> Data {
        guard !request.isCancelled else { throw CancellationError() }
        var data = Data(count: count)
        while true {
            let bytesRead = data.withUnsafeMutableBytes { buffer in
                Darwin.pread(descriptor, buffer.baseAddress, buffer.count, off_t(offset))
            }
            if bytesRead < 0 && Darwin.errno == EINTR { continue }
            guard bytesRead >= 0 else { throw LumaError("Could not read wallpaper resource: \(String(cString: strerror(Darwin.errno))).") }
            guard bytesRead > 0 else { return Data() }
            data.count = bytesRead
            return data
        }
    }
}

@MainActor final class SceneHost: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private struct PointerPosition: Equatable {
        let x: Double
        let y: Double
    }

    private static let maxCapturePNGBytes = 96 * 1024 * 1024
    private static let maxCaptureBase64Characters = ((maxCapturePNGBytes + 2) / 3) * 4
    let webView: WKWebView
    private let scheme: WallpaperScheme
    var ready: (() -> Void)?
    var failed: ((String) -> Void)?
    var diagnostic: ((String) -> Void)?
    var didBecomeReady = false
    private(set) var pageLoaded = false
    private var options: [String: Any]
    private var desiredPlaying = true
    private var submittedPlaying: Bool?
    private struct RendererSettings: Equatable {
        var fps: Int
        var volume: Double
        var fit: String
    }
    private var rendererSettings: RendererSettings
    private var submittedRendererSettings: RendererSettings?
    private var lastResourceWarning = ""
    private let projectFolder: URL
    private let scriptApproval: String?
    private var mountStarted = false
    private var stopped = false
    private var capturing = false
    private var mediaSubscription: AnyCancellable?
    private var lastRequestedPointer: PointerPosition?
    private var lastDeliveredPointer: PointerPosition?
    private var pendingPointer: PointerPosition?
    private var pointerEvaluationInFlight = false
    init(folder: URL, assets: URL?, wallpaper: Wallpaper, configuration: DisplayConfiguration, preferences: AppPreferences, resources: URL? = nil) {
        projectFolder = folder
        rendererSettings = RendererSettings(fps: preferences.sceneFPS, volume: configuration.volume, fit: configuration.fit.rendererValue)
        scriptApproval = wallpaper.kind == .scene && wallpaper.runsSceneScript ? wallpaper.scriptApprovalFingerprint : nil
        scheme = WallpaperScheme(project: folder, assets: assets, resources: resources)
        options = ["fps": preferences.sceneFPS, "renderDpr": preferences.retina ? 0 : 1, "volume": configuration.volume,
                   "fit": configuration.fit.rendererValue, "scripts": wallpaper.kind == .scene ? false : wallpaper.runsSceneScript,
                   "properties": (try? JSONSerialization.jsonObject(with: Data(wallpaper.propertiesJSON.utf8))) as? [String: Any] ?? [:],
                   "mountTimeoutMs": 45000, "audio": NSNull(), "media": NSNull()]
        let config = WKWebViewConfiguration(); config.setURLSchemeHandler(scheme, forURLScheme: "luma")
        config.websiteDataStore = .nonPersistent(); config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        scheme.resourceFailure = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.lastResourceWarning = message
                self.diagnostic?(message)
            }
        }
        mediaSubscription = SceneMediaProvider.shared.$snapshot.sink { [weak self] snapshot in
            Task { @MainActor in self?.updateMedia(snapshot) }
        }
        webView.navigationDelegate = self
        config.userContentController.add(self, name: "luma")
        webView.setValue(false, forKey: "drawsBackground")
        // Documents cannot navigate to arbitrary files or create native bridge objects.
        webView.load(URLRequest(url: URL(string: "luma://wallpaper/app/renderer.html?localAssets=1")!))
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !stopped, message.frameInfo.isMainFrame, let origin = message.frameInfo.request.url, origin.scheme == "luma", origin.host == "wallpaper", origin.path == "/app/renderer.html", let body = message.body as? [String: String] else { return }
        switch body["event"] {
        case "ready":
            guard !didBecomeReady else { return }
            didBecomeReady = true; applyRendererSettings(); setPlaying(desiredPlaying); updateMedia(SceneMediaProvider.shared.snapshot); ready?()
        case "error": failed?((body["message"] ?? "The scene renderer stopped.") + (lastResourceWarning.isEmpty ? "" : "\n" + lastResourceWarning))
        case "diagnostic": lastResourceWarning = body["message"] ?? ""; diagnostic?(lastResourceWarning)
        default: break
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !mountStarted, !stopped, webView.url?.path == "/app/renderer.html" else { return }
        mountStarted = true
        pageLoaded = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let expected = self.scriptApproval {
                let folder = self.projectFolder
                let review = try? await Task.detached(priority: .userInitiated) { try SceneScriptReview.inspect(folder: folder) }.value
                guard !self.stopped else { return }
                if let review, review.canApprove, review.fingerprint == expected {
                    self.scheme.setApprovedScriptResources(review.resourceFingerprints)
                    self.options["scripts"] = true
                }
                else {
                    self.lastResourceWarning = "SceneScript was kept off because its source changed or could not be inspected. Open Review Scripts to approve the current source."
                    self.diagnostic?(self.lastResourceWarning)
                }
            }
            guard !self.stopped else { return }
            do {
                self.submittedRendererSettings = self.rendererSettings
                _ = try await self.webView.callAsyncJavaScript("window.lumaMount(\(Safety.json(self.options)));void 0", arguments: [:], in: nil, contentWorld: .page)
            } catch { self.failed?(error.localizedDescription) }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame != false {
            decisionHandler(url.scheme == "luma" && url.host == "wallpaper" && url.path == "/app/renderer.html" ? .allow : .cancel)
        } else {
            decisionHandler(["luma", "blob", "about", "data"].contains(url.scheme ?? "") ? .allow : .cancel)
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed?(error.localizedDescription) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed?("The scene renderer exited. Retry this wallpaper to rebuild its graphics context.") }
    func setPlaying(_ playing: Bool) {
        desiredPlaying = playing
        guard didBecomeReady, !stopped, submittedPlaying != playing else { return }
        submittedPlaying = playing
        webView.evaluateJavaScript("window.wallpaper?.\(playing ? "resume" : "pause")();void 0") { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                if self?.submittedPlaying == playing { self?.submittedPlaying = nil }
            }
        }
    }
    private func updateMedia(_ snapshot: SceneMediaProvider.TrackSnapshot) {
        guard didBecomeReady, !stopped, options["scripts"] as? Bool == true else { return }
        webView.evaluateJavaScript("window.lumaSetMedia(\(Safety.json(snapshot.json)));void 0", completionHandler: nil)
    }
    func configure(_ config: DisplayConfiguration, preferences: AppPreferences) {
        options["fps"] = preferences.sceneFPS; options["volume"] = config.volume; options["fit"] = config.fit.rendererValue
        rendererSettings = RendererSettings(fps: preferences.sceneFPS, volume: config.volume, fit: config.fit.rendererValue)
        applyRendererSettings()
    }
    private func applyRendererSettings() {
        guard didBecomeReady, !stopped, submittedRendererSettings != rendererSettings else { return }
        let next = rendererSettings, previous = submittedRendererSettings
        var commands: [String] = []
        if previous?.fps != next.fps { commands.append("window.wallpaper?.setFps(\(next.fps))") }
        if previous?.volume != next.volume { commands.append("window.wallpaper?.setVolume(\(next.volume))") }
        if previous?.fit != next.fit { commands.append("window.wallpaper?.setFit(\(Safety.json(next.fit)))") }
        submittedRendererSettings = next
        webView.evaluateJavaScript(commands.joined(separator: ";") + ";void 0") { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                if self?.submittedRendererSettings == next { self?.submittedRendererSettings = nil }
            }
        }
    }
    func pointer(x: Double, y: Double) {
        guard didBecomeReady, !stopped, x.isFinite, y.isFinite else { return }
        let position = PointerPosition(x: x, y: y)
        guard position != lastRequestedPointer else { return }
        lastRequestedPointer = position
        pendingPointer = position
        sendPendingPointer()
    }
    private func sendPendingPointer() {
        guard didBecomeReady, !stopped, !pointerEvaluationInFlight, let position = pendingPointer else { return }
        pendingPointer = nil
        guard position != lastDeliveredPointer else { return }
        pointerEvaluationInFlight = true
        webView.evaluateJavaScript("window.wallpaper?.pushPointer(\(position.x),\(position.y),0)") { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pointerEvaluationInFlight = false
                if error == nil { self.lastDeliveredPointer = position }
                else if self.lastRequestedPointer == position { self.lastRequestedPointer = nil }
                self.sendPendingPointer()
            }
        }
    }
    func capture(time: Double, width: Int, height: Int) async throws -> Data {
        guard didBecomeReady, !stopped else { throw LumaError("Wait for the scene to finish loading before exporting.") }
        guard !capturing else { throw LumaError("Another scene capture is still in progress.") }
        capturing = true
        defer { capturing = false }
        guard time.isFinite, time >= 0 else { throw LumaError("Scene capture time must be a finite, nonnegative number of seconds.") }
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width.multipliedReportingOverflow(by: height).overflow == false,
              width * height <= 16_777_216 else {
            throw LumaError("Scene capture dimensions must be between 1 and 8192 pixels, with no more than 16 megapixels.")
        }
        let value = try await webView.callAsyncJavaScript("return await window.lumaCaptureBridge(time,width,height)", arguments: ["time":time,"width":width,"height":height], in: nil, contentWorld: .page)
        guard let serialized = value as? String,
              serialized.utf8.count <= Self.maxCaptureBase64Characters + 16_384,
              let resultData = serialized.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
            let resultType = value.map { String(reflecting: type(of: $0)) } ?? "nil"
            throw LumaError("The renderer returned an unreadable scene capture response (\(resultType)).")
        }
        if result["snapshot"] as? Bool == true {
            do {
                try Task.checkCancellation()
                guard !stopped else { throw LumaError("Scene capture stopped before its native snapshot.") }
                let bounds = webView.bounds
                guard bounds.width > 0, bounds.height > 0 else { throw LumaError("The scene has no visible surface for a native capture.") }
                let aspect = bounds.height / bounds.width
                let snapshotWidth = min(CGFloat(width), 2048, sqrt(16_777_216 / aspect), 8192 / aspect)
                guard snapshotWidth >= 1 else { throw LumaError("The scene surface has an unsupported aspect ratio for native capture.") }
                let config = WKSnapshotConfiguration()
                config.rect = bounds; config.snapshotWidth = NSNumber(value: Double(snapshotWidth)); config.afterScreenUpdates = true
                let image = try await webView.takeSnapshot(configuration: config)
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
                    throw LumaError("WebKit could not encode the scene's native snapshot.")
                }
                _ = try await webView.callAsyncJavaScript("window.lumaFinishCapture();return true", arguments: [:], in: nil, contentWorld: .page)
                try Task.checkCancellation()
                guard !stopped else { throw LumaError("Scene capture stopped before its native snapshot completed.") }
                diagnostic?("Canvas PNG encoding was unavailable; captured the renderer's exact frame through WebKit's native snapshot.")
                return try Self.png(png, withPixelSize: CGSize(width: width, height: height))
            } catch {
                _ = try? await webView.callAsyncJavaScript("window.lumaFinishCapture();return true", arguments: [:], in: nil, contentWorld: .page)
                throw LumaError("Native scene capture failed: \(error.localizedDescription) Canvas diagnostic: \((result["error"] as? String ?? "unavailable").prefix(600))")
            }
        }
        guard result["ok"] as? Bool == true,
              let string = result["data"] as? String, string.hasPrefix("data:image/png;base64,"),
              let comma = string.firstIndex(of: ",") else {
            let detail = result["error"] as? String
            let payload = result["data"] as? String
            throw LumaError(detail.map { "The scene renderer could not capture this frame: \($0.prefix(1_500))" } ?? "The renderer returned an invalid scene capture payload (ok=\(String(describing: result["ok"])), data type=\(result["data"].map { String(reflecting: type(of: $0)) } ?? "missing"), prefix=\(payload.map { String($0.prefix(80)) } ?? "missing")).")
        }
        let base64 = string[string.index(after: comma)...]
        guard base64.utf8.count <= Self.maxCaptureBase64Characters else { throw LumaError("The scene capture exceeds Luma's 96 MiB image limit.") }
        guard let data = Data(base64Encoded: String(base64)), data.count <= Self.maxCapturePNGBytes else { throw LumaError("The renderer returned an invalid or oversized scene capture.") }
        return try Self.png(data, withPixelSize: CGSize(width: width, height: height))
    }
    private static func png(_ data: Data, withPixelSize size: CGSize) throws -> Data {
        guard data.count <= maxCapturePNGBytes else { throw LumaError("The scene capture exceeds Luma's 96 MiB image limit.") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let sourceHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw LumaError("The scene renderer returned an unreadable PNG frame.")
        }
        guard sourceWidth > 0, sourceHeight > 0, sourceWidth <= 8192, sourceHeight <= 8192,
              sourceWidth.multipliedReportingOverflow(by: sourceHeight).overflow == false,
              sourceWidth * sourceHeight <= 16_777_216 else {
            throw LumaError("The renderer's PNG dimensions exceed Luma's 8192-pixel or 16-megapixel capture limit.")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw LumaError("The scene renderer returned an unreadable PNG frame.") }
        let width = Int(size.width), height = Int(size.height)
        guard image.width != width || image.height != height else { return data }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw LumaError("Luma could not normalize the scene capture to the requested pixel size.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let normalized = context.makeImage() else { throw LumaError("Luma could not encode the normalized scene frame.") }
        let representation = NSBitmapImageRep(cgImage: normalized)
        guard let result = representation.representation(using: .png, properties: [:]) else {
            throw LumaError("Luma could not encode the normalized scene frame as PNG.")
        }
        return result
    }
    struct EditorSnapshot {
        let available: Bool
        let time: Double
        let layers: [[String: Any]]?
        let diagnostics: [String]?
        let skippedScripts: Int?
    }
    func editorSnapshot(includeLayers: Bool = false, includeDiagnostics: Bool = false) async throws -> EditorSnapshot {
        guard didBecomeReady, !stopped else { throw LumaError("Wait for the scene preview to finish loading.") }
        let result = try await webView.callAsyncJavaScript("return window.lumaEditorSnapshot(includeLayers,includeDiagnostics)",
            arguments: ["includeLayers": includeLayers, "includeDiagnostics": includeDiagnostics], in: nil, contentWorld: .page)
        guard !stopped, let value = result as? [String: Any], let available = value["available"] as? Bool,
              let time = value["time"] as? NSNumber, time.doubleValue.isFinite, time.doubleValue >= 0 else {
            throw LumaError("The renderer returned an unsupported editor status snapshot.")
        }
        var layers: [[String: Any]]?
        var diagnostics: [String]?
        var skipped: Int?
        if includeLayers {
            guard let rows = value["layers"] as? [[String: Any]], rows.count <= 5000 else {
                throw LumaError("The renderer returned an unsupported layer snapshot.")
            }
            layers = rows
        }
        if includeDiagnostics {
            guard let issues = value["issues"] as? [Any], issues.count <= 64,
                  let count = value["skipped"] as? NSNumber, count.doubleValue.isFinite, count.doubleValue >= 0 else {
                throw LumaError("The renderer returned unsupported script diagnostics.")
            }
            diagnostics = Self.formatScriptDiagnostics(issues)
            skipped = Int(min(100_000, count.doubleValue))
        }
        return EditorSnapshot(available: available, time: time.doubleValue, layers: layers, diagnostics: diagnostics, skippedScripts: skipped)
    }
    func editorAvailable() async -> Bool {
        guard didBecomeReady, !stopped else { return false }
        return (try? await webView.callAsyncJavaScript("return window.lumaEditorAvailable()", arguments: [:], in: nil, contentWorld: .page) as? Bool) ?? false
    }
    func editorLayers() async throws -> [[String: Any]] {
        guard didBecomeReady, !stopped else { throw LumaError("Wait for the scene preview to finish loading.") }
        let value = try await webView.callAsyncJavaScript("return window.lumaEditorLayers()", arguments: [:], in: nil, contentWorld: .page)
        guard let layers = value as? [[String: Any]], layers.count <= 5000 else { throw LumaError("The renderer returned an unsupported layer snapshot.") }
        return layers
    }
    func editorLayerProperties(id: String) async throws -> [String: Any]? {
        guard didBecomeReady, !stopped else { return nil }
        let value = try await webView.callAsyncJavaScript("return window.lumaEditorLayerProps(id)", arguments: ["id": id], in: nil, contentWorld: .page)
        return value as? [String: Any]
    }
    func editorScriptDiagnostics() async -> [String] {
        guard didBecomeReady, !stopped,
              let values = try? await webView.callAsyncJavaScript("return window.lumaEditorScriptIssues()", arguments: [:], in: nil, contentWorld: .page) as? [Any] else { return [] }
        return Self.formatScriptDiagnostics(values)
    }
    private static func formatScriptDiagnostics(_ values: [Any]) -> [String] {
        values.prefix(64).compactMap { value in
            if let string = value as? String { return String(string.prefix(1_000)) }
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let string = String(data: data, encoding: .utf8) else { return nil }
            return String(string.prefix(1_000))
        }
    }
    func editorSkippedScriptCount() async -> Int {
        guard didBecomeReady, !stopped,
              let value = try? await webView.callAsyncJavaScript("return window.lumaEditorSkippedScripts()", arguments: [:], in: nil, contentWorld: .page) as? NSNumber else { return 0 }
        return max(0, min(100_000, value.intValue))
    }
    func editorHitTest(x: Double, y: Double) async throws -> [String] {
        guard didBecomeReady, !stopped, x.isFinite, y.isFinite else { return [] }
        let value = try await webView.callAsyncJavaScript("return window.lumaEditorHitTest(x, y)", arguments: ["x": x, "y": y], in: nil, contentWorld: .page)
        if let ids = value as? [String] { return Array(ids.prefix(64)) }
        if let ids = value as? [NSNumber] { return ids.prefix(64).map(\.stringValue) }
        if let rows = value as? [[String: Any]] { return rows.prefix(64).compactMap { $0["id"].map(String.init(describing:)) } }
        return []
    }
    func editorTime() async -> Double {
        guard didBecomeReady, !stopped,
              let value = try? await webView.callAsyncJavaScript("return window.lumaEditorTime()", arguments: [:], in: nil, contentWorld: .page) as? NSNumber else { return 0 }
        let time = value.doubleValue; return time.isFinite ? max(0, time) : 0
    }
    func editorSeek(_ time: Double) async {
        guard didBecomeReady, !stopped, time.isFinite else { return }
        do { _ = try await webView.callAsyncJavaScript("window.lumaEditorSeek(time)", arguments: ["time": max(0, min(86_400, time))], in: nil, contentWorld: .page) }
        catch { diagnostic?(error.localizedDescription) }
    }
    func editorStep(_ amount: Int, fps: Int) {
        guard didBecomeReady, !stopped, (-1000...1000).contains(amount), (1...240).contains(fps) else { return }
        Task { do { _ = try await webView.callAsyncJavaScript("window.lumaEditorStep(amount, fps)", arguments: ["amount": amount, "fps": fps], in: nil, contentWorld: .page) } catch { diagnostic?(error.localizedDescription) } }
    }
    func editorSetTimeScale(_ value: Double) {
        guard didBecomeReady, !stopped, value.isFinite, (0...4).contains(value) else { return }
        Task { do { _ = try await webView.callAsyncJavaScript("window.lumaEditorSetTimeScale(value)", arguments: ["value": value], in: nil, contentWorld: .page) } catch { diagnostic?(error.localizedDescription) } }
    }
    func editorSetPreviewQuality(antiAliasing: String, particles: String, postProcessing: String) {
        guard didBecomeReady, !stopped,
              ["off", "fxaa", "msaa2", "msaa4"].contains(antiAliasing),
              ["off", "low", "medium", "high"].contains(particles),
              ["off", "low", "medium", "high"].contains(postProcessing) else { return }
        let quality = ["antiAliasing": antiAliasing, "particles": particles, "postProcessing": postProcessing]
        Task { do { _ = try await webView.callAsyncJavaScript("window.wallpaper?.setQuality(quality)", arguments: ["quality": quality], in: nil, contentWorld: .page) } catch { diagnostic?(error.localizedDescription) } }
    }
    func editorCanHotAdd(spec: [String: Any]) async -> (Bool, String) {
        guard didBecomeReady, !stopped, JSONSerialization.isValidJSONObject(spec),
              let data = try? JSONSerialization.data(withJSONObject: spec), data.count <= 64 * 1024,
              let result = try? await webView.callAsyncJavaScript("return window.lumaEditorCanAdd(spec)", arguments: ["spec": spec], in: nil, contentWorld: .page) as? [String: Any] else { return (false, "No scene editor is available") }
        return (result["ok"] as? Bool ?? false, result["reason"] as? String ?? "The renderer does not support adding this layer type")
    }
    func editorSetLayerProperties(id: String, properties: [String: Any]) async throws {
        guard didBecomeReady, !stopped, id.utf8.count <= 128,
              JSONSerialization.isValidJSONObject(properties), (try JSONSerialization.data(withJSONObject: properties)).count <= 64 * 1024 else { throw LumaError("The renderer layer update is invalid or too large.") }
        _ = try await webView.callAsyncJavaScript("return window.lumaEditorLayerPatch(id, patch)", arguments: ["id": id, "patch": properties], in: nil, contentWorld: .page)
    }
    func editorReorderLayer(id: String, index: Int) async throws {
        guard didBecomeReady, !stopped, id.utf8.count <= 128, (0..<5000).contains(index) else { throw LumaError("The renderer layer order request is invalid.") }
        _ = try await webView.callAsyncJavaScript("return window.lumaEditorLayerOrder(id, index)", arguments: ["id": id, "index": index], in: nil, contentWorld: .page)
    }
    func decodeTexture(_ bytes: Data) async throws -> Data {
        let decoded = try await decodeTextureMedia(bytes)
        guard !decoded.isVideo else { throw LumaError("This scene texture contains a video.") }
        return decoded.data
    }
    func decodeTextureMedia(_ bytes: Data) async throws -> (data: Data, isVideo: Bool) {
        guard bytes.count <= 64 * 1024 * 1024 else { throw LumaError("The texture is too large for an image fallback.") }
        let deadline = Date().addingTimeInterval(15)
        while !pageLoaded { try Task.checkCancellation(); guard Date() < deadline else { throw LumaError("The texture decoder did not load.") }; try await Task.sleep(for: .milliseconds(50)) }
        let value = try await webView.callAsyncJavaScript("return await window.lumaDecodeTexture(bytes)", arguments: ["bytes": bytes.base64EncodedString()], in: nil, contentWorld: .page)
        try Task.checkCancellation()
        guard !stopped, let result = value as? [String: Any], let kind = result["kind"] as? String,
              ["rgba", "image", "video"].contains(kind), let base64 = result["data"] as? String else {
            throw LumaError("The texture decoder returned an unsupported payload.")
        }
        let limit = (kind == "rgba" ? 128 : 64) * 1024 * 1024
        guard !base64.isEmpty, base64.utf8.count <= ((limit + 2) / 3) * 4,
              let data = Data(base64Encoded: base64), !data.isEmpty, data.count <= limit else {
            throw LumaError("The texture decoder returned an empty, invalid, or oversized payload.")
        }
        if kind == "video" { return (data, true) }
        let image: CGImage
        if kind == "rgba" {
            guard let width = result["width"] as? NSNumber, let height = result["height"] as? NSNumber,
                  width.doubleValue.isFinite, height.doubleValue.isFinite,
                  width.doubleValue >= 1, height.doubleValue >= 1,
                  width.doubleValue.rounded(.towardZero) == width.doubleValue,
                  height.doubleValue.rounded(.towardZero) == height.doubleValue,
                  width.doubleValue * height.doubleValue <= 33_554_432 else {
                throw LumaError("The texture decoder returned invalid RGBA dimensions.")
            }
            let w = width.intValue, h = height.intValue
            guard data.count == w * h * 4, let provider = CGDataProvider(data: data as CFData),
                  let decoded = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                throw LumaError("The texture decoder returned inconsistent RGBA pixels.")
            }
            image = decoded
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue >= 1, height.doubleValue >= 1, width.doubleValue * height.doubleValue <= 33_554_432,
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw LumaError("The texture decoder returned an unreadable or oversized image.")
            }
            image = decoded
        }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), png.count <= Self.maxCapturePNGBytes else {
            throw LumaError("Luma could not encode the decoded texture within its 96 MiB PNG limit.")
        }
        return (png, false)
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        mediaSubscription = nil
        pendingPointer = nil
        didBecomeReady = false
        webView.evaluateJavaScript("window.wallpaper?.destroy({releasePkgCache:true})", completionHandler: nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "luma")
        webView.stopLoading(); ready = nil; failed = nil; diagnostic = nil
    }
}

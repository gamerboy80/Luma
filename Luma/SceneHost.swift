import AppKit
import Combine
import WebKit
import UniformTypeIdentifiers
import ImageIO
import CryptoKit
import Darwin

// A per-instance resource origin. Only this wallpaper, the renderer, and explicitly
// selected shared engine assets are exposed. No filesystem bridge is injected.
final class WallpaperScheme: NSObject, WKURLSchemeHandler {
    let project: URL
    let assets: URL?
    let resources: URL?
    var resourceFailure: ((String) -> Void)?
    private var approvedScriptResources: [String: String]?
    init(project: URL, assets: URL?, resources: URL? = nil) { self.project = project; self.assets = assets; self.resources = resources }
    func setApprovedScriptResources(_ value: [String: String]?) { approvedScriptResources = value }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        do {
            guard let url = urlSchemeTask.request.url, url.host == "wallpaper" else { throw LumaError("Unknown wallpaper origin.") }
            try Safety.validateDirectoryIfPresent(project)
            let path = url.path
            var data: Data
            var mime = "application/octet-stream"
            if path == "/api/local-assets" {
                let info: [String: Any] = assets == nil ? ["ok": false] : ["ok": true, "roots": [["id":"owned","dir":"assets"]]]
                data = Data(Safety.json(info).utf8); mime = "application/json"
            } else if path == "/api/local-assets/owned/materials/index.json", let assets {
                let materialRoot = assets.appendingPathComponent("materials")
                var names: [String] = []
                if let items = FileManager.default.enumerator(at: materialRoot, includingPropertiesForKeys: nil) {
                    for case let file as URL in items where file.pathExtension == "tex" {
                        names.append(String(file.deletingPathExtension().path.dropFirst(materialRoot.path.count + 1)))
                    }
                }
                data = Data(Safety.json(["names": names]).utf8); mime = "application/json"
            } else {
                let file: URL
                let root: URL
                if path.hasPrefix("/app/") {
                    let name = String(path.dropFirst(5))
                    guard ["renderer.html","webwallgl.js"].contains(name), let bundled = resources?.appendingPathComponent(name) ?? Bundle.main.url(forResource: name, withExtension: nil) else { throw LumaError("Renderer resources are missing.") }
                    file = bundled; root = bundled.deletingLastPathComponent()
                } else if path.hasPrefix("/project/") { root = project; file = try Safety.child(String(path.dropFirst(9)), under: project) }
                else if path.hasPrefix("/api/local-assets/owned/"), let assets { root = assets; file = try Safety.child(String(path.dropFirst(24)), under: assets) }
                else { throw LumaError("Resource not available.") }
                data = try Self.readRegularResource(file, under: root)
                if path.hasPrefix("/project/"), let expected = approvedScriptResources {
                    let relative = String(path.dropFirst(9))
                    let ext = file.pathExtension.lowercased()
                    if ["pkg", "json", "js", "mjs", "cjs", "scenescript"].contains(ext) {
                        guard let digest = expected[relative] else { throw LumaError("SceneScript was disabled because \(relative) was not present during review.") }
                        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        guard actual == digest else { throw LumaError("SceneScript was disabled because \(relative) changed after review. Review the current scene source before enabling scripts again.") }
                    }
                }
                mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                if file.pathExtension == "js" { mime = "text/javascript" }
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*"])!
            urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
        } catch {
            resourceFailure?(error.localizedDescription)
            urlSchemeTask.didFailWithError(error)
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private static func readRegularResource(_ url: URL, under root: URL) throws -> Data {
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
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            try? handle.close()
            throw LumaError("Wallpaper resource \(url.lastPathComponent) is not a regular file.")
        }
        let limit = 2 * 1024 * 1024 * 1024
        guard metadata.st_size >= 0, metadata.st_size <= off_t(limit) else {
            try? handle.close()
            throw LumaError("Wallpaper resource \(url.lastPathComponent) exceeds Luma's 2 GiB renderer limit.")
        }
        var result = Data(capacity: Int(metadata.st_size))
        do {
            while result.count <= limit {
                let amount = min(1024 * 1024, limit + 1 - result.count)
                guard let chunk = try handle.read(upToCount: amount), !chunk.isEmpty else { break }
                result.append(chunk)
            }
            guard result.count <= limit else { throw LumaError("Wallpaper resource \(url.lastPathComponent) grew beyond Luma's 2 GiB renderer limit.") }
            return result
        } catch {
            try? handle.close()
            throw error
        }
    }
}

@MainActor final class SceneHost: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
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
    private var lastResourceWarning = ""
    private let projectFolder: URL
    private let scriptApproval: String?
    private var mountStarted = false
    private var stopped = false
    private var mediaSubscription: AnyCancellable?
    init(folder: URL, assets: URL?, wallpaper: Wallpaper, configuration: DisplayConfiguration, preferences: AppPreferences, resources: URL? = nil) {
        projectFolder = folder
        scriptApproval = wallpaper.kind == .scene && wallpaper.runsSceneScript ? wallpaper.scriptApprovalFingerprint : nil
        scheme = WallpaperScheme(project: folder, assets: assets, resources: resources)
        options = ["fps": preferences.sceneFPS, "renderDpr": preferences.retina ? 0 : 1, "volume": configuration.volume,
                   "fit": configuration.fit.rawValue, "scripts": wallpaper.kind == .scene ? false : wallpaper.runsSceneScript,
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
            didBecomeReady = true; setPlaying(desiredPlaying); updateMedia(SceneMediaProvider.shared.snapshot); ready?()
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
    func setPlaying(_ playing: Bool) { desiredPlaying = playing; if didBecomeReady { webView.evaluateJavaScript("window.wallpaper?.\(playing ? "resume" : "pause")()", completionHandler: nil) } }
    private func updateMedia(_ snapshot: SceneMediaProvider.TrackSnapshot) {
        guard didBecomeReady, !stopped, options["scripts"] as? Bool == true else { return }
        webView.evaluateJavaScript("window.lumaSetMedia(\(Safety.json(snapshot.json)));void 0", completionHandler: nil)
    }
    func configure(_ config: DisplayConfiguration, preferences: AppPreferences) {
        options["fps"] = preferences.sceneFPS; options["volume"] = config.volume
        if didBecomeReady {
            webView.evaluateJavaScript("window.wallpaper?.setFps(\(preferences.sceneFPS));window.wallpaper?.setVolume(\(config.volume));window.wallpaper?.setFit(\(Safety.json(config.fit.rawValue)));", completionHandler: nil)
        }
    }
    func pointer(x: Double, y: Double) { guard didBecomeReady else { return }; webView.evaluateJavaScript("window.wallpaper?.pushPointer(\(x),\(y),0)", completionHandler: nil) }
    func capture(time: Double, width: Int, height: Int) async throws -> Data {
        guard didBecomeReady else { throw LumaError("Wait for the scene to finish loading before exporting.") }
        guard time.isFinite, time >= 0 else { throw LumaError("Scene capture time must be a finite, nonnegative number of seconds.") }
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width.multipliedReportingOverflow(by: height).overflow == false,
              width * height <= 16_777_216 else {
            throw LumaError("Scene capture dimensions must be between 1 and 8192 pixels, with no more than 16 megapixels.")
        }
        let value = try await webView.callAsyncJavaScript("try { return {ok:true, data:await window.lumaCapture(time,width,height)} } catch (error) { const message=String(error?.message || error); const stack=typeof error?.stack==='string' ? error.stack : ''; return {ok:false, error:stack ? message+'\\n'+stack : message} }", arguments: ["time":time,"width":width,"height":height], in: nil, contentWorld: .page)
        guard let result = value as? [String: Any], result["ok"] as? Bool == true,
              let string = result["data"] as? String, string.hasPrefix("data:image/png;base64,"),
              let comma = string.firstIndex(of: ",") else {
            let detail = (value as? [String: Any])?["error"] as? String
            throw LumaError(detail.map { "The scene renderer could not capture this frame: \($0.prefix(1_500))" } ?? "The renderer returned an invalid scene capture.")
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
        return values.prefix(64).compactMap { value in
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
        guard let string = value as? String, let comma = string.firstIndex(of: ","), let data = Data(base64Encoded: String(string[string.index(after: comma)...])) else { throw LumaError("This scene texture could not be decoded.") }
        return (data, string.hasPrefix("data:video/"))
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        mediaSubscription = nil
        didBecomeReady = false
        webView.evaluateJavaScript("window.wallpaper?.destroy({releasePkgCache:true})", completionHandler: nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "luma")
        webView.stopLoading(); ready = nil; failed = nil; diagnostic = nil
    }
}

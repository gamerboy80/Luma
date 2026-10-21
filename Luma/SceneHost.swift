import AppKit
import WebKit
import UniformTypeIdentifiers

// A per-instance resource origin. Only this wallpaper, the renderer, and explicitly
// selected shared engine assets are exposed. No filesystem bridge is injected.
final class WallpaperScheme: NSObject, WKURLSchemeHandler {
    let project: URL
    let assets: URL?
    let resources: URL?
    init(project: URL, assets: URL?, resources: URL? = nil) { self.project = project; self.assets = assets; self.resources = resources }
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
                if path.hasPrefix("/app/") {
                    let name = String(path.dropFirst(5))
                    guard ["renderer.html","webwallgl.js"].contains(name), let bundled = resources?.appendingPathComponent(name) ?? Bundle.main.url(forResource: name, withExtension: nil) else { throw LumaError("Renderer resources are missing.") }
                    file = bundled
                } else if path.hasPrefix("/project/") { file = try Safety.child(String(path.dropFirst(9)), under: project) }
                else if path.hasPrefix("/api/local-assets/owned/"), let assets { file = try Safety.child(String(path.dropFirst(24)), under: assets) }
                else { throw LumaError("Resource not available.") }
                data = try Data(contentsOf: file, options: .mappedIfSafe)
                mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                if file.pathExtension == "js" { mime = "text/javascript" }
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*"])!
            urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

@MainActor final class SceneHost: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
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
            didBecomeReady = true; setPlaying(desiredPlaying); ready?()
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
                if let review, review.canApprove, review.fingerprint == expected { self.options["scripts"] = true }
                else {
                    self.lastResourceWarning = "SceneScript was kept off because its source changed or could not be inspected. Open Review Scripts to approve the current source."
                    self.diagnostic?(self.lastResourceWarning)
                }
            }
            guard !self.stopped else { return }
            self.webView.evaluateJavaScript("window.lumaMount(\(Safety.json(self.options)));void 0") { [weak self] _, error in if let error { self?.failed?(error.localizedDescription) } }
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
    func configure(_ config: DisplayConfiguration, preferences: AppPreferences) {
        options["fps"] = preferences.sceneFPS; options["volume"] = config.volume
        if didBecomeReady {
            webView.evaluateJavaScript("window.wallpaper?.setFps(\(preferences.sceneFPS));window.wallpaper?.setVolume(\(config.volume));window.wallpaper?.setFit(\(Safety.json(config.fit.rawValue)));", completionHandler: nil)
        }
    }
    func pointer(x: Double, y: Double) { guard didBecomeReady else { return }; webView.evaluateJavaScript("window.wallpaper?.pushPointer(\(x),\(y),0)", completionHandler: nil) }
    func capture(time: Double, width: Int, height: Int) async throws -> Data {
        guard didBecomeReady else { throw LumaError("Wait for the scene to finish loading before exporting.") }
        let value = try await webView.callAsyncJavaScript("return await window.lumaCapture(time, width, height)", arguments: ["time":time,"width":width,"height":height], in: nil, contentWorld: .page)
        guard let string = value as? String, let comma = string.firstIndex(of: ","), let data = Data(base64Encoded: String(string[string.index(after: comma)...])) else { throw LumaError("The renderer could not capture this scene.") }
        return data
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
        didBecomeReady = false
        webView.evaluateJavaScript("window.wallpaper?.destroy({releasePkgCache:true})", completionHandler: nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "luma")
        webView.stopLoading(); ready = nil; failed = nil; diagnostic = nil
    }
}

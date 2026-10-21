import Foundation
import AppKit
import AVFoundation
import CryptoKit
import WebKit

private final class WallpaperSchemeTaskFixture: NSObject, WKURLSchemeTask, @unchecked Sendable {
    let request: URLRequest
    private let lock = NSLock()
    private var storedResponse: URLResponse?
    private var storedChunks: [Data] = []
    private var storedError: Error?
    private var storedFinished = false
    var onData: (() -> Void)?
    var response: URLResponse? { lock.lock(); defer { lock.unlock() }; return storedResponse }
    var chunks: [Data] { lock.lock(); defer { lock.unlock() }; return storedChunks }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return storedError }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return storedFinished }
    init(url: URL) { request = URLRequest(url: url) }
    func didReceive(_ response: URLResponse) { lock.lock(); storedResponse = response; lock.unlock() }
    func didReceive(_ data: Data) {
        lock.lock(); storedChunks.append(data); let callback = onData; lock.unlock()
        callback?()
    }
    func didFinish() { lock.lock(); storedFinished = true; lock.unlock() }
    func didFailWithError(_ error: Error) { lock.lock(); storedError = error; lock.unlock() }
}

@main struct SceneTests {
    @MainActor static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {try await verify();print("PASS: packed scene load, WebGL editor bridge, timeline sync, hit testing, quality control, frame capture, texture decoding, and scene export");exit(0)}
            catch {FileHandle.standardError.write(Data("SCENE TEST FAILED: \(error.localizedDescription)\n".utf8));exit(1)}
        }
        app.run()
    }
    @MainActor static func verify() async throws {
        try LockOverlayTests.verify()
        if CommandLine.arguments.contains("--live-lock-overlay") { try LockOverlayTests.verifyWindowServer() }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("LumaSceneTests-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        try await verifyWallpaperResourceHandler(root: root)
        let object:[String:Any] = ["general":["clearcolor":"0.015 0.035 0.06","orthogonalprojection":["width":1920,"height":1080],"bloom":false],"objects":[["id":1,"name":"Text fixture","text":"LUMA SCENE","font":"systemfont_arial","pointsize":32,"origin":"960 540 0","scale":"1 1 1","angles":"0 0 0","size":"1600 250","color":"0.43 0.88 0.75","horizontalalign":"center","verticalalign":"center","anchor":"none","padding":32,"opaquebackground":false,"maxrows":1,"maxwidth":1600]]]
        let bytes=try JSONSerialization.data(withJSONObject:object)
        let name=Data("scene.json".utf8)
        var pkg=Data()
        func u32(_ n:Int) {var little=UInt32(n).littleEndian;withUnsafeBytes(of:&little){pkg.append(contentsOf:$0)}}
        u32(8);pkg.append(Data("PKGV0012".utf8));u32(1);u32(name.count);pkg.append(name);u32(0);u32(bytes.count);pkg.append(bytes)
        try pkg.write(to:root.appendingPathComponent("scene.pkg"))
        try Data("{\"title\":\"Luma Scene Fixture\",\"type\":\"scene\",\"file\":\"scene.pkg\"}".utf8).write(to:root.appendingPathComponent("project.json"))
        let wallpaper=Wallpaper(title:"Fixture",kind:.scene,folder:"fixture",entry:"scene.pkg")
        let resources=URL(fileURLWithPath:CommandLine.arguments[1])
        let host=SceneHost(folder:root,assets:nil,wallpaper:wallpaper,configuration:DisplayConfiguration(),preferences:AppPreferences(),resources:resources)
        let window=NSWindow(contentRect:CGRect(x:0,y:0,width:320,height:180),styleMask:.borderless,backing:.buffered,defer:false)
        // Keep WebKit's rendering surface visible for the full regression run.
        // A window ordered behind the desktop can have its web content process
        // reclaimed while capture/export is exercising the scene renderer.
        window.isReleasedWhenClosed=false;window.ignoresMouseEvents=true;window.contentView=host.webView;window.orderFrontRegardless()
        defer {host.stop();window.close()}
        var error:String?
        host.failed={error=$0};host.diagnostic={print("Scene diagnostic:",$0)}
        let deadline=Date().addingTimeInterval(40)
        while !host.didBecomeReady {if let error{throw LumaError(error)};guard Date()<deadline else {throw LumaError("No scene frame arrived (pageLoaded=\(host.pageLoaded), webViewLoading=\(host.webView.isLoading), url=\(host.webView.url?.absoluteString ?? "none"), rendererError=\(error ?? "none")).")};try await Task.sleep(for:.milliseconds(100))}
        guard await host.editorAvailable() else { throw LumaError("The bundled WebWallGL editor API did not attach to a scene preview.") }
        let editorLayers = try await host.editorLayers()
        guard editorLayers.count == 1 else { throw LumaError("The editor API did not return the fixture layer.") }
        print("Editor layer snapshot:", Safety.json(editorLayers))
        let selectedLayerID = editorLayers.first?["id"].map(String.init(describing:)) ?? "1"
        let layerProperties = try await host.editorLayerProperties(id: selectedLayerID)
        guard layerProperties != nil else { throw LumaError("The editor API could not read the selected layer properties.") }
        do {
            _ = try await host.webView.callAsyncJavaScript("window.__lumaOriginalRAF=window.requestAnimationFrame.bind(window);window.__lumaRAFRequests=0;window.__lumaRAFStart=performance.now();window.requestAnimationFrame=callback=>{window.__lumaRAFRequests++;return window.__lumaOriginalRAF(callback)};return true", arguments: [:], in: nil, contentWorld: .page)
        } catch { throw LumaError("Could not instrument render scheduling: \(error.localizedDescription)") }
        try await Task.sleep(for: .milliseconds(1_200))
        let scheduler: [String: Any]?
        do {
            scheduler = try await host.webView.callAsyncJavaScript("return {requests:window.__lumaRAFRequests,elapsed:performance.now()-window.__lumaRAFStart,fps:window.wallpaper.stats.fps}", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        } catch { throw LumaError("Could not read render scheduler metrics: \(error.localizedDescription)") }
        let schedulerFPS = (scheduler?["fps"] as? NSNumber)?.doubleValue ?? 0
        let schedulerRate = Double((scheduler?["requests"] as? NSNumber)?.intValue ?? 0) / max(0.001, ((scheduler?["elapsed"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        let expectedFPS = Double(AppPreferences().sceneFPS)
        guard schedulerFPS >= expectedFPS * 0.7, schedulerFPS <= expectedFPS * 1.2, schedulerRate < 90 else {
            throw LumaError("The scene render scheduler exceeded its target (\(schedulerFPS.rounded()) rendered fps for a \(expectedFPS.rounded()) fps target, \(schedulerRate.rounded()) rAF requests/s).")
        }
        print("PASS: target-rate render scheduling (\(schedulerRate.rounded()) rAF requests/s, \(schedulerFPS.rounded()) rendered fps)")
        _ = try await host.webView.callAsyncJavaScript("window.requestAnimationFrame=window.__lumaOriginalRAF;delete window.__lumaOriginalRAF;delete window.__lumaRAFRequests;delete window.__lumaRAFStart;return true", arguments: [:], in: nil, contentWorld: .page)
        let textHotAdd = await host.editorCanHotAdd(spec: ["duplicateOf": 1])
        guard !textHotAdd.0, !textHotAdd.1.isEmpty else { throw LumaError("The renderer's hot-add capability check did not reject an unsupported text-layer insert.") }
        host.setPlaying(false)
        await host.editorSeek(0.5)
        let seekTime = await host.editorTime()
        guard abs(seekTime - 0.5) < 0.1 else { throw LumaError("The editor timeline did not synchronize its seek with the preview clock.") }
        try await verifyControlBridge(host)
        let hitLayers = try await host.editorHitTest(x: 160, y: 90)
        print("Editor center hit test:", Safety.json(hitLayers))
        guard hitLayers.contains(selectedLayerID) else { throw LumaError("The editor hit test did not select the visible fixture layer.") }
        _ = try await host.webView.callAsyncJavaScript("window.__lumaPointerOriginal=window.wallpaper.pushPointer;window.__lumaPointerCalls=[];window.wallpaper.pushPointer=function(x,y,b,m){window.__lumaPointerCalls.push([x,y]);return window.__lumaPointerOriginal.call(this,x,y,b,m)};return true", arguments: [:], in: nil, contentWorld: .page)
        for index in 0..<64 { host.pointer(x: Double(index) / 100, y: 0.5) }
        host.pointer(x: 0.92, y: 0.73)
        try await Task.sleep(for: .milliseconds(250))
        for _ in 0..<64 { host.pointer(x: 0.92, y: 0.73) }
        try await Task.sleep(for: .milliseconds(100))
        let pointerJSON = try await host.webView.callAsyncJavaScript("return JSON.stringify(window.__lumaPointerCalls)", arguments: [:], in: nil, contentWorld: .page) as? String
        _ = try await host.webView.callAsyncJavaScript("window.wallpaper.pushPointer=window.__lumaPointerOriginal;delete window.__lumaPointerOriginal;delete window.__lumaPointerCalls;return true", arguments: [:], in: nil, contentWorld: .page)
        guard let pointerJSON, let pointerData = pointerJSON.data(using: .utf8),
              let pointerCalls = try? JSONSerialization.jsonObject(with: pointerData) as? [[NSNumber]],
              pointerCalls.count <= 2,
              pointerCalls.last?.count == 2,
              abs((pointerCalls.last?[0].doubleValue ?? 0) - 0.92) < 0.001,
              abs((pointerCalls.last?[1].doubleValue ?? 0) - 0.73) < 0.001 else {
            throw LumaError("Cursor updates were queued individually instead of coalescing to the latest position.")
        }
        print("PASS: scene cursor updates coalesce bursts and skip repeated positions")
        host.editorSetPreviewQuality(antiAliasing: "fxaa", particles: "medium", postProcessing: "low")
        try await Task.sleep(for: .milliseconds(100))
        let frame=try await host.capture(time:0,width:320,height:180)
        guard let bitmap=NSBitmapImageRep(data:frame) else { throw LumaError("Scene capture did not return a decodable image (\(frame.count) bytes).") }
        guard bitmap.pixelsWide == 320,bitmap.pixelsHigh == 180 else {throw LumaError("Scene frame dimensions are wrong: got \(bitmap.pixelsWide)×\(bitmap.pixelsHigh), expected 320×180 (\(frame.count) PNG bytes).")}
        do {
            _ = try await host.capture(time: 0, width: 0, height: 180)
            throw LumaError("Scene capture accepted a zero-width frame.")
        } catch let error as LumaError {
            guard error.message.contains("dimensions") else { throw error }
        }
        do {
            _ = try await host.capture(time: .infinity, width: 320, height: 180)
            throw LumaError("Scene capture accepted a nonfinite timestamp.")
        } catch let error as LumaError {
            guard error.message.contains("capture time") else { throw error }
        }
        _ = try await host.webView.callAsyncJavaScript("window.__lumaOriginalCapture=window.lumaCapture;const c=document.createElement('canvas');c.width=64;c.height=36;const ctx=c.getContext('2d');ctx.fillStyle='#e02020';ctx.fillRect(0,0,64,18);ctx.fillStyle='#2040e0';ctx.fillRect(0,18,64,18);window.__lumaPatternCapture=c.toDataURL('image/png');window.lumaCapture=async()=>window.__lumaPatternCapture;return true", arguments: [:], in: nil, contentWorld: .page)
        let normalizedFrame = try await host.capture(time: 0, width: 320, height: 180)
        guard let normalizedBitmap = NSBitmapImageRep(data: normalizedFrame), normalizedBitmap.pixelsWide == 320, normalizedBitmap.pixelsHigh == 180 else {
            let actual = NSBitmapImageRep(data: normalizedFrame).map { "\($0.pixelsWide)×\($0.pixelsHigh)" } ?? "unreadable"
            throw LumaError("Host capture normalization returned \(actual), expected 320×180.")
        }
        let sourcePatternValue = try await host.webView.callAsyncJavaScript("return window.__lumaPatternCapture", arguments: [:], in: nil, contentWorld: .page)
        guard let sourcePatternURL = sourcePatternValue as? String,
              let patternComma = sourcePatternURL.firstIndex(of: ","),
              let sourcePatternData = Data(base64Encoded: String(sourcePatternURL[sourcePatternURL.index(after: patternComma)...])),
              let sourcePattern = NSBitmapImageRep(data: sourcePatternData),
              let sourceTop = sourcePattern.colorAt(x: 32, y: 9)?.usingColorSpace(.deviceRGB),
              let sourceBottom = sourcePattern.colorAt(x: 32, y: 27)?.usingColorSpace(.deviceRGB),
              let normalizedTop = normalizedBitmap.colorAt(x: 160, y: 45)?.usingColorSpace(.deviceRGB),
              let normalizedBottom = normalizedBitmap.colorAt(x: 160, y: 135)?.usingColorSpace(.deviceRGB) else {
            throw LumaError("Scene capture orientation fixture could not decode its color samples.")
        }
        func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
            abs(lhs.redComponent - rhs.redComponent) + abs(lhs.greenComponent - rhs.greenComponent) + abs(lhs.blueComponent - rhs.blueComponent)
        }
        guard colorDistance(sourceTop, sourceBottom) > 1,
              colorDistance(sourceTop, normalizedTop) < 0.12,
              colorDistance(sourceBottom, normalizedBottom) < 0.12 else {
            throw LumaError("Scene capture resizing changed or vertically flipped the rendered frame colors.")
        }
        _ = try await host.webView.callAsyncJavaScript("window.lumaCapture=window.__lumaOriginalCapture;delete window.__lumaOriginalCapture;delete window.__lumaPatternCapture;return true", arguments: [:], in: nil, contentWorld: .page)
        _ = try await host.webView.callAsyncJavaScript("HTMLCanvasElement.prototype.toBlob=function(callback){callback(null)}; return true", arguments: [:], in: nil, contentWorld: .page)
        let fallbackFrame = try await host.capture(time: 0.1, width: 320, height: 180)
        guard let fallbackBitmap = NSBitmapImageRep(data: fallbackFrame) else { throw LumaError("Scene capture did not fall back to a decodable data URL when canvas.toBlob returned null.") }
        guard fallbackBitmap.pixelsWide == 320, fallbackBitmap.pixelsHigh == 180 else { throw LumaError("Data URL fallback frame dimensions are wrong: got \(fallbackBitmap.pixelsWide)×\(fallbackBitmap.pixelsHigh), expected 320×180.") }
        _ = try await host.webView.callAsyncJavaScript("window.__lumaCaptureForBridgeTest=window.lumaCapture;window.lumaCapture=async()=>null;return true", arguments: [:], in: nil, contentWorld: .page)
        var captureDiagnostic = ""
        do {
            _ = try await host.capture(time: 0.1, width: 320, height: 180)
        } catch {
            captureDiagnostic = error.localizedDescription
        }
        _ = try await host.webView.callAsyncJavaScript("window.lumaCapture=window.__lumaCaptureForBridgeTest;delete window.__lumaCaptureForBridgeTest;return true", arguments: [:], in: nil, contentWorld: .page)
        guard captureDiagnostic.contains("Capture returned null") else {
            throw LumaError("Scene capture bridge did not preserve its renderer error details: \(captureDiagnostic.isEmpty ? "capture unexpectedly succeeded" : captureDiagnostic).")
        }
        _ = try await host.webView.callAsyncJavaScript("window.__lumaDataURL=HTMLCanvasElement.prototype.toDataURL;HTMLCanvasElement.prototype.toDataURL=function(){return 'data:,'};return true", arguments: [:], in: nil, contentWorld: .page)
        let nativeFrame = try await host.capture(time: 0.1, width: 320, height: 180)
        _ = try await host.webView.callAsyncJavaScript("HTMLCanvasElement.prototype.toDataURL=window.__lumaDataURL;delete window.__lumaDataURL;return true", arguments: [:], in: nil, contentWorld: .page)
        guard let nativeBitmap = NSBitmapImageRep(data: nativeFrame), nativeBitmap.pixelsWide == 320, nativeBitmap.pixelsHigh == 180 else {
            throw LumaError("The native snapshot fallback did not preserve the requested frame dimensions.")
        }
        var nativeBright = 0
        for y in stride(from: 0, to: 180, by: 3) { for x in stride(from: 0, to: 320, by: 3) {
            if let color = nativeBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.greenComponent > 0.2 { nativeBright += 1 }
        } }
        guard nativeBright > 10 else { throw LumaError("The native snapshot fallback lost the rendered text.") }
        let overlayRemoved = try await host.webView.callAsyncJavaScript("return document.getElementById('luma-capture-output')===null", arguments: [:], in: nil, contentWorld: .page)
        guard overlayRemoved as? Bool == true else { throw LumaError("Native scene capture left its temporary canvas over the renderer.") }
        var bright=0
        for y in stride(from:0,to:180,by:3){for x in stride(from:0,to:320,by:3){if let color=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB),color.greenComponent>0.2 {bright += 1}}}
        guard bright>10 else {throw LumaError("The scene capture contained no rendered text")}
        let fixtures = resources.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/Fixtures")
        let texture = try Data(contentsOf: fixtures.appendingPathComponent("fallback.tex"))
        let decodedTexture = try await host.decodeTexture(texture)
        guard let textureBitmap = NSBitmapImageRep(data: decodedTexture), textureBitmap.pixelsWide == 8, textureBitmap.pixelsHigh == 8,
              let sample = textureBitmap.colorAt(x: 4, y: 4)?.usingColorSpace(.deviceRGB), sample.greenComponent > 0.7 else { throw LumaError("Packed texture fallback did not decode its pixels") }
        let videoTexture = try Data(contentsOf: fixtures.appendingPathComponent("video-texture.tex"))
        let extractedVideo = try await host.decodeTextureMedia(videoTexture)
        guard extractedVideo.isVideo, extractedVideo.data.count == 20, String(decoding: extractedVideo.data[4..<8], as: UTF8.self) == "ftyp" else { throw LumaError("Video texture payload was not extracted") }
        let still = root.appendingPathComponent("snapshot.mov")
        try await StillMovieExporter.export(imageData: frame, output: still)
        let stillAsset = AVURLAsset(url: still)
        let generator = AVAssetImageGenerator(asset: stillAsset)
        let first = try await generator.image(at: .zero).image
        let last = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
        guard first.width == last.width, first.height == last.height else { throw LumaError("Snapshot frame dimensions changed") }
        let firstBitmap = NSBitmapImageRep(cgImage: first), lastBitmap = NSBitmapImageRep(cgImage: last)
        var difference = 0.0; var samples = 0
        for y in stride(from: 0, to: first.height, by: 4) { for x in stride(from: 0, to: first.width, by: 4) {
            if let a = firstBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), let b = lastBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                difference += abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent); samples += 3
            }
        } }
        guard samples > 0, difference / Double(samples) < 0.01 else { throw LumaError("Snapshot wallpaper pixels changed beyond normal compression noise") }
        let movie=root.appendingPathComponent("scene.mov")
        try await SceneMovieExporter.export(host:host,output:movie,seconds:1,fps:12,width:320,height:180,progress:{_ in})
        let asset=AVURLAsset(url:movie);let duration=try await asset.load(.duration).seconds
        guard duration>0.8,try await asset.loadTracks(withMediaType:.video).count == 1 else {throw LumaError("Scene movie is incomplete")}
        host.stop(); window.close()
        try await verifyScripts(root: root, resources: resources, template: object)
    }

    @MainActor static func verifyControlBridge(_ host: SceneHost) async throws {
        let snapshot = try await host.editorSnapshot(includeLayers: true, includeDiagnostics: true)
        let lightweight = try await host.editorSnapshot()
        guard snapshot.available, abs(snapshot.time - 0.5) < 0.1, snapshot.layers?.count == 1,
              snapshot.layers?.first?["name"] as? String == "Text fixture", snapshot.diagnostics != nil,
              snapshot.skippedScripts != nil, lightweight.layers == nil, lightweight.diagnostics == nil else {
            throw LumaError("The combined editor snapshot lost layers, timeline, or diagnostic data.")
        }
        _ = try await host.webView.callAsyncJavaScript("""
        window.__lumaSnapshotOriginal=window.lumaEditorSnapshot;
        window.lumaEditorSnapshot=()=>({available:true,time:-1});return true
        """, arguments: [:], in: nil, contentWorld: .page)
        do { _ = try await host.editorSnapshot(); throw LumaError("An invalid snapshot was accepted.") }
        catch let error as LumaError { guard error.message.contains("unsupported editor status") else { throw error } }
        _ = try await host.webView.callAsyncJavaScript("window.lumaEditorSnapshot=()=>({available:true,time:0,layers:Array.from({length:5001},()=>({}))});return true", arguments: [:], in: nil, contentWorld: .page)
        do { _ = try await host.editorSnapshot(includeLayers: true); throw LumaError("An oversized snapshot was accepted.") }
        catch let error as LumaError { guard error.message.contains("unsupported layer") else { throw error } }
        _ = try await host.webView.callAsyncJavaScript("""
        window.lumaEditorSnapshot=window.__lumaSnapshotOriginal;delete window.__lumaSnapshotOriginal;
        window.__lumaControlOriginals={};window.__lumaControlCalls={};
        for(const name of ['pause','resume','setFps','setVolume','setFit']){
          const original=window.wallpaper[name];window.__lumaControlOriginals[name]=original;
          window.wallpaper[name]=function(...args){(window.__lumaControlCalls[name]??=[]).push(args);return original.apply(this,args)};
        }return true
        """, arguments: [:], in: nil, contentWorld: .page)
        for _ in 0..<64 { host.setPlaying(false); host.configure(DisplayConfiguration(), preferences: AppPreferences()) }
        host.setPlaying(true); host.setPlaying(false)
        var config = DisplayConfiguration(), preferences = AppPreferences()
        config.volume = 0.25; config.fit = .contain; preferences.sceneFPS = 24
        for _ in 0..<64 { host.configure(config, preferences: preferences) }
        config.volume = 0.5; host.configure(config, preferences: preferences)
        let calls = try await host.webView.callAsyncJavaScript("return Object.fromEntries(Object.entries(window.__lumaControlCalls).map(([key,value])=>[key,value.length]))", arguments: [:], in: nil, contentWorld: .page) as? [String: Int]
        guard calls == ["pause": 1, "resume": 1, "setFps": 1, "setVolume": 2, "setFit": 1] else {
            throw LumaError("Unchanged controls repeated renderer work or dropped transitions: \(String(describing: calls)).")
        }
        _ = try await host.webView.callAsyncJavaScript("for(const [key,value] of Object.entries(window.__lumaControlOriginals))window.wallpaper[key]=value;delete window.__lumaControlOriginals;delete window.__lumaControlCalls;return true", arguments: [:], in: nil, contentWorld: .page)
        host.configure(DisplayConfiguration(), preferences: AppPreferences())
        print("PASS: atomic editor status snapshots, snapshot limits, and renderer controls skip repeated values while applying transitions")
    }
    @MainActor static func verifyWallpaperResourceHandler(root: URL) async throws {
        let resourceRoot = root.appendingPathComponent("scheme-resources", isDirectory: true)
        let outsideRoot = root.appendingPathComponent("scheme-outside", isDirectory: true)
        try FileManager.default.createDirectory(at: resourceRoot, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: false)

        let payloadSize = 16 * 1024 * 1024
        let payload = Data((0..<payloadSize).map { UInt8(truncatingIfNeeded: $0 * 31) })
        try payload.write(to: resourceRoot.appendingPathComponent("large.bin"))
        try payload.write(to: resourceRoot.appendingPathComponent("large.js"))
        let shrinkingResource = resourceRoot.appendingPathComponent("shrinking.bin")
        try payload.write(to: shrinkingResource)
        let outsideData = Data("outside the wallpaper".utf8)
        try outsideData.write(to: outsideRoot.appendingPathComponent("secret.bin"))
        try FileManager.default.createSymbolicLink(at: resourceRoot.appendingPathComponent("escape.bin"), withDestinationURL: outsideRoot.appendingPathComponent("secret.bin"))
        let reviewedSource = Data("export function update(){return 'reviewed'}".utf8)
        try reviewedSource.write(to: resourceRoot.appendingPathComponent("scene.js"))

        let scheme = WallpaperScheme(project: resourceRoot, assets: nil)
        let webView = WKWebView(frame: .zero)
        let streamed = WallpaperSchemeTaskFixture(url: URL(string: "luma://wallpaper/project/large.bin")!)
        scheme.webView(webView, start: streamed)
        let streamDeadline = Date().addingTimeInterval(10)
        while !streamed.finished && streamed.error == nil && Date() < streamDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard streamed.finished, streamed.error == nil,
              (streamed.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") == String(payloadSize),
              streamed.chunks.count > 1, streamed.chunks.allSatisfy({ !$0.isEmpty && $0.count <= 1024 * 1024 }),
              streamed.chunks.reduce(into: Data(), { $0.append($1) }) == payload else {
            throw LumaError("Large wallpaper resources were not streamed in bounded, complete chunks: chunks=\(streamed.chunks.count), error=\(streamed.error?.localizedDescription ?? "none").")
        }

        let payloadFingerprint = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        scheme.setApprovedScriptResources(["large.js": payloadFingerprint])
        let reviewedStream = WallpaperSchemeTaskFixture(url: URL(string: "luma://wallpaper/project/large.js")!)
        scheme.webView(webView, start: reviewedStream)
        let reviewedDeadline = Date().addingTimeInterval(10)
        while !reviewedStream.finished && reviewedStream.error == nil && Date() < reviewedDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard reviewedStream.finished, reviewedStream.error == nil,
              reviewedStream.chunks.count > 1,
              reviewedStream.chunks.allSatisfy({ !$0.isEmpty && $0.count <= 1024 * 1024 }),
              reviewedStream.chunks.reduce(into: Data(), { $0.append($1) }) == payload else {
            throw LumaError("A fingerprint-verified large script was not streamed from its exact reviewed snapshot.")
        }

        let cancellable = WallpaperSchemeTaskFixture(url: URL(string: "luma://wallpaper/project/large.bin")!)
        cancellable.onData = { scheme.webView(webView, stop: cancellable) }
        scheme.webView(webView, start: cancellable)
        let firstChunkDeadline = Date().addingTimeInterval(5)
        while cancellable.chunks.isEmpty && cancellable.error == nil && Date() < firstChunkDeadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        guard !cancellable.chunks.isEmpty else { throw LumaError("The streaming cancellation fixture did not receive its first chunk.") }
        let stoppedChunkCount = cancellable.chunks.count
        try await Task.sleep(for: .milliseconds(100))
        guard !cancellable.finished, cancellable.error == nil, cancellable.chunks.count == stoppedChunkCount else {
            throw LumaError("A stopped wallpaper resource continued delivering callbacks.")
        }

        let shrinking = WallpaperSchemeTaskFixture(url: URL(string: "luma://wallpaper/project/shrinking.bin")!)
        shrinking.onData = {
            if let file = try? FileHandle(forWritingTo: shrinkingResource) {
                try? file.truncate(atOffset: 0)
                try? file.close()
            }
        }
        scheme.webView(webView, start: shrinking)
        let shrinkingDeadline = Date().addingTimeInterval(5)
        while shrinking.error == nil && !shrinking.finished && Date() < shrinkingDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard shrinking.error?.localizedDescription.contains("ended before its advertised size") == true,
              !shrinking.finished, shrinking.chunks.count == 1 else {
            throw LumaError("A wallpaper resource that shrank during streaming did not fail cleanly.")
        }

        let escaped = WallpaperSchemeTaskFixture(url: URL(string: "luma://wallpaper/project/escape.bin")!)
        scheme.webView(webView, start: escaped)
        let escapeDeadline = Date().addingTimeInterval(5)
        while escaped.error == nil && !escaped.finished && Date() < escapeDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard escaped.error != nil, escaped.chunks.isEmpty else { throw LumaError("Wallpaper resource handler followed a symlink outside the active wallpaper.") }

        scheme.setApprovedScriptResources(["scene.js": "not-the-current-fingerprint"])
        let changedScript = WallpaperSchemeTaskFixture(url: URL(string: "luma://wallpaper/project/scene.js")!)
        scheme.webView(webView, start: changedScript)
        let scriptDeadline = Date().addingTimeInterval(5)
        while changedScript.error == nil && !changedScript.finished && Date() < scriptDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let scriptError = changedScript.error,
              scriptError.localizedDescription.localizedCaseInsensitiveContains("changed after review"),
              changedScript.chunks.isEmpty else {
            throw LumaError("A changed reviewed script was not rejected before any bytes were delivered.")
        }

        scheme.setApprovedScriptResources(["large.js": "not-the-large-source-fingerprint"])
        let changedLargeScript = WallpaperSchemeTaskFixture(url: URL(string: "luma://wallpaper/project/large.js")!)
        scheme.webView(webView, start: changedLargeScript)
        let largeScriptDeadline = Date().addingTimeInterval(10)
        while changedLargeScript.error == nil && !changedLargeScript.finished && Date() < largeScriptDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let temporarySnapshots = ((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
            .filter { $0.hasPrefix("luma-reviewed-resource-") }
        guard changedLargeScript.error?.localizedDescription.localizedCaseInsensitiveContains("changed after review") == true,
              changedLargeScript.chunks.isEmpty, temporarySnapshots.isEmpty else {
            throw LumaError("A fingerprint-mismatched large script was delivered or left a temporary snapshot behind.")
        }
        print("PASS: bounded wallpaper streaming, cancellation, symlink containment, exact script snapshots, and fingerprint rejection")
    }

    @MainActor static func verifyScripts(root: URL, resources: URL, template: [String: Any]) async throws {
        func project(_ name: String, code: String, helper: String? = nil, objectScript: String? = nil, extraLayer: Bool = false, extraParticle: Bool = false) throws -> URL {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            var object = template
            var layer = (object["objects"] as! [[String: Any]])[0]
            layer["text"] = ["value": "BASE", "script": code]
            if extraParticle { layer["particle"] = "particles/fixture-missing.json" }
            if let objectScript { layer["alpha"] = ["value": 1, "script": objectScript] }
            object["objects"] = [layer]
            if let helper {
                var sibling = layer
                sibling["id"] = 2; sibling["name"] = "Shared helper"; sibling["visible"] = false
                sibling["text"] = ["value": "", "script": helper]
                object["objects"] = [layer, sibling]
            } else if extraLayer {
                var sibling = (template["objects"] as! [[String: Any]])[0]
                sibling["id"] = 2; sibling["name"] = "Second Layer"; sibling["text"] = "SIBLING"
                sibling["origin"] = "600 300 0"
                object["objects"] = [layer, sibling]
            }
            let scene = try JSONSerialization.data(withJSONObject: object)
            var package = Data()
            func number(_ n: Int) { var n = UInt32(n).littleEndian; withUnsafeBytes(of: &n) { package.append(contentsOf: $0) } }
            number(8); package.append(Data("PKGV0012".utf8)); number(1)
            number(10); package.append(Data("scene.json".utf8)); number(0); number(scene.count); package.append(scene)
            try package.write(to: folder.appendingPathComponent("scene.pkg"))
            try Data("{\"title\":\"Script fixture\",\"type\":\"scene\",\"file\":\"scene.pkg\"}".utf8).write(to: folder.appendingPathComponent("project.json"))
            return folder
        }
        func run(_ name: String, code: String, enabled: Bool, staleApproval: Bool = false, changedAfterReview: Bool = false, rejected: Bool = false, timeoutEvent: String? = nil, helper: String? = nil, objectScript: String? = nil, extraLayer: Bool = false, extraParticle: Bool = false, expectedDiagnostic: String? = nil, check: ((SceneHost) async throws -> Void)? = nil) async throws {
            let folder = try project(name, code: code, helper: helper, objectScript: objectScript, extraLayer: extraLayer, extraParticle: extraParticle)
            let raceScriptURL = folder.appendingPathComponent("reviewed-helper.js")
            if changedAfterReview { try Data("export function update(){ return 'reviewed'; }".utf8).write(to: raceScriptURL) }
            let review = try SceneScriptReview.inspect(folder: folder)
            guard review.canApprove else { throw LumaError("Script fixture did not produce a complete source review (\(review.sources.count) sources): \(review.issues.joined(separator: "; "))") }
            if changedAfterReview { try Data("export function update(){ return 'changed after approval'; }".utf8).write(to: raceScriptURL, options: .atomic) }
            let packageBytes = try Data(contentsOf: folder.appendingPathComponent("scene.pkg"))
            guard let reviewedPackageDigest = review.resourceFingerprints["scene.pkg"] else { throw LumaError("The review did not fingerprint the active scene package.") }
            let actualDigest = SHA256.hash(data: packageBytes).map { String(format: "%02x", $0) }.joined()
            guard actualDigest == reviewedPackageDigest else { throw LumaError("The reviewed package digest does not match the exact package bytes.") }
            var wallpaper = Wallpaper(title: name, kind: .scene, folder: name, entry: "scene.pkg")
            wallpaper.trustedScripts = enabled
            wallpaper.scriptApprovalFingerprint = staleApproval ? "stale-fingerprint" : review.fingerprint
            let host = SceneHost(folder: folder, assets: nil, wallpaper: wallpaper, configuration: DisplayConfiguration(), preferences: AppPreferences(), resources: resources)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 180), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true; window.contentView = host.webView; window.orderFrontRegardless()
            defer { host.stop(); window.close() }
            var failure: String?, diagnostics: [String] = []
            host.failed = { failure = $0 }; host.diagnostic = { diagnostics.append($0) }
            let deadline = Date().addingTimeInterval(35)
            while !host.didBecomeReady {
                if let failure { throw LumaError(failure) }
                guard Date() < deadline else {
                    let rendererState = try? await host.webView.callAsyncJavaScript("const canvas=document.querySelector('canvas'); const gl=canvas?.getContext('webgl2'); return {readyState:document.readyState,visibility:document.visibilityState,focused:document.hasFocus(),canvas:canvas?{width:canvas.width,height:canvas.height,clientWidth:canvas.clientWidth,clientHeight:canvas.clientHeight,contextLost:gl?.isContextLost()??null}:null,wallpaperInstance:typeof window.wallpaper?.pause==='function',wallpaperType:typeof window.wallpaper,diagnostics:window.lumaEditorScriptIssues?.()||[]}", arguments: [:], in: nil, contentWorld: .page)
                    throw LumaError("Script fixture did not render: \(name); pageLoaded=\(host.pageLoaded), webViewLoading=\(host.webView.isLoading), url=\(host.webView.url?.absoluteString ?? "none"), rendererError=\(failure ?? "none"), diagnostics=\(diagnostics.joined(separator: "; ")), rendererState=\(Safety.json(rendererState ?? NSNull()))")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            if let event = timeoutEvent {
                let timeout = Date().addingTimeInterval(8)
                while !diagnostics.contains(where: { $0.contains("timed out during \(event)") }) {
                    guard Date() < timeout else { throw LumaError("No watchdog timeout for \(name): \(diagnostics.joined(separator: "; "))") }
                    try await Task.sleep(for: .milliseconds(50))
                }
                let before = await host.editorTime()
                try await Task.sleep(for: .milliseconds(250))
                guard await host.editorTime() > before else { throw LumaError("Render clock froze after \(name) timed out.") }
                _ = try await host.capture(time: 0.2, width: 320, height: 180)
                let count = diagnostics.filter { $0.contains("timed out") }.count
                try await Task.sleep(for: .milliseconds(250))
                guard diagnostics.filter({ $0.contains("timed out") }).count == count else { throw LumaError("Timed-out scripts continued receiving events.") }
            } else {
                let expected = enabled && !staleApproval && !changedAfterReview && !rejected ? 123.0 : 960.0
                host.setPlaying(true)
                let limit = Date().addingTimeInterval(5)
                var properties: [String: Any]?
                repeat {
                    try await Task.sleep(for: .milliseconds(100))
                    properties = try await host.editorLayerProperties(id: "1")
                    if enabled && !staleApproval && !rejected && (properties?["origin"] as? [NSNumber])?.first?.doubleValue == expected { break }
                } while Date() < limit
                let origin = properties?["origin"] as? [NSNumber]
                let issues = await host.editorScriptDiagnostics()
                if let expectedDiagnostic, !(diagnostics + issues).contains(where: { $0.localizedCaseInsensitiveContains(expectedDiagnostic) }) {
                    throw LumaError("Expected SceneScript diagnostic '\(expectedDiagnostic)' for \(name): \((diagnostics + issues).joined(separator: "; "))")
                }
                guard origin?.first?.doubleValue == expected else { throw LumaError("Script approval/clock check failed for \(name): \(Safety.json(properties ?? [:])); time \(await host.editorTime()); \((diagnostics + issues).joined(separator: "; "))") }
                if rejected {
                    guard !(diagnostics + issues).isEmpty, !diagnostics.contains(where: { $0.contains("timed out") }) else { throw LumaError("A rejected script caused a false watchdog timeout.") }
                }
            }
            try await check?(host)
            host.stop()
            guard !host.didBecomeReady else { throw LumaError("Stopped host remained ready.") }
            print("PASS: SceneScript \(name)")
        }
        let clock = "export function update(value) { const clockOK=typeof engine.runtime==='number' && typeof engine.timeOfDay==='number' && Date.now()>1000000000000 && new Date().getTime()===Date.now(); thisLayer.origin.x=clockOK?123:456; return JSON.stringify({clockOK:clockOK,x:thisLayer.origin.x,now:Date.now()}); }"
        try await run("reviewed-clock", code: clock, enabled: true) { host in
            let layer = try await host.editorLayerProperties(id: "1") ?? [:]
            guard let text = layer["text"] as? String, let bytes = text.data(using: .utf8),
                  let value = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                  value["clockOK"] as? Bool == true, (value["x"] as? Double) == 123,
                  (value["now"] as? Double ?? 0) > 1_000_000_000_000
            else { throw LumaError("Worker clock/vector values were not returned after the host write: \(Safety.json(layer))") }
        }
        try await run("review-source-changed-after-review", code: clock, enabled: true, changedAfterReview: true, expectedDiagnostic: "source changed")
        try await run("mixed-text-object-updates", code: clock, enabled: true, objectScript: "export function update(value) { return value; }")
        try await run("isolated-random", code: "export function update(value) { const first=Math.random(),second=Math.random(); thisLayer.origin=new Vec3(first>=0 && first<1 && second>=0 && second<1 && first!==second?123:456,540,0); return 'RANDOM'; }", enabled: true)
        try await run("layer-transform-matrix", code: "export function update(value) { const world=thisLayer.getTransformMatrix().transformPoint(new Vec3(0,0,0)); const good=world.subtract(thisLayer.origin).length()<0.001; thisLayer.origin=new Vec3(good?123:456,540,0); return 'TRANSFORM'; }", enabled: true)
        try await run("bounded-timers", code: "export function init() { shared.cancelledRan=false; const cancel=engine.setTimeout(()=>{shared.cancelledRan=true;},1); cancel(); engine.setTimeout(()=>{thisLayer.origin=new Vec3(!shared.cancelledRan && Date.now()>1000000000000?123:456,540,0);},50); } export function update(value) { return 'TIMERS'; }", enabled: true)
        try await run("shared-functions-and-storage", code: "export function update(value) { const good=typeof shared.double==='function' && shared.double(21)===42 && shared.elapsed()>0 && localStorage.get('sibling')===true; thisLayer.origin=new Vec3(good?123:456,540,0); return 'SHARED'; }", enabled: true, helper: "export function init() { shared.double=value=>value*2; shared.elapsed=()=>engine.runtime; localStorage.set('sibling',true); }")
        try await run("batch-preserves-sibling-mutations", code: "export function update(value){shared.tick=engine.runtime;shared.expected=0.25+(Math.floor(engine.runtime*1000)%500)/1000;thisScene.getLayer('Shared helper').alpha=shared.expected;thisLayer.origin=new Vec3(123,540,0);return shared.seen&&!shared.failed?'BATCH_GOOD':'WAIT';}", enabled: true, helper: "export function update(value){if(shared.tick===engine.runtime){shared.seen=true;if(Math.abs(thisLayer.alpha-shared.expected)>1e-8)shared.failed=true;}return value;}") { host in
            let deadline = Date().addingTimeInterval(3)
            var value = ""
            repeat {
                try await Task.sleep(for: .milliseconds(100))
                value = try await host.editorLayerProperties(id: "1")?["text"] as? String ?? ""
            } while value != "BATCH_GOOD" && Date() < deadline
            guard value == "BATCH_GOOD" else { throw LumaError("A later script reset its sibling's mutation within the same update batch.") }
        }
        try await run("shared-layer-handles-clock-media", code: "let title=''; export function mediaPropertiesChanged(event){title=event.title+'|'+event.artist;} export function update(value){shared.cachedSongs[0].layer.pointsize=32; thisLayer.origin=new Vec3(123,540,0); return Date.now()+'|'+title;}", enabled: true, helper: "export function init(){shared.cachedSongs=[{name:'song',layer:thisScene.getLayer('Text fixture')}]; Object.defineProperty(shared,'workerOnly',{enumerable:true,get(){throw new Error('Shared getter must not be serialized')}});}") { host in
            _ = try await host.webView.callAsyncJavaScript("window.lumaSetMedia({hasMedia:true,state:1,title:'Actual event title',artist:'Actual event artist'});return true", arguments: [:], in: nil, contentWorld: .page)
            let deadline = Date().addingTimeInterval(5)
            var text = ""
            repeat {
                try await Task.sleep(for: .milliseconds(100))
                text = try await host.editorLayerProperties(id: "1")?["text"] as? String ?? ""
            } while !text.contains("Actual event title|Actual event artist") && Date() < deadline
            guard text.contains("Actual event title|Actual event artist") else { throw LumaError("Shared layer handles stopped media events: \(await host.editorScriptDiagnostics())") }
            try await Task.sleep(for: .milliseconds(200))
            let next = try await host.editorLayerProperties(id: "1")?["text"] as? String ?? ""
            guard next != text, Double(next.split(separator: "|").first ?? "0") ?? 0 > 1_700_000_000_000 else { throw LumaError("Shared layer handles stopped the advancing clock.") }
            _ = try await host.capture(time: 0.2, width: 320, height: 180)
        }
        try await run("vectors-matrices-and-storage", code: "export function init() { localStorage.set('flag',false); localStorage.set('value',{x:7,y:8}); shared.counter=0; } export function update(value) { shared.counter++; const m=Mat4.compose(new Vec3(4,5,6),new Vec3(20,30,40),new Vec3(2,3,4)); const v=new Vec3(2,4,6); const roundtrip=m.inverse().transformPoint(m.transformPoint(v)); const m2=Mat3.compose(new Vec2(4,5),30,new Vec2(2,3)); const p=new Vec2(7,8); const back=m2.inverse().transformPoint(m2.transformPoint(p)); const good=roundtrip.subtract(v).length()<0.0001 && back.subtract(p).length()<0.0001 && Mat4.lookAt(new Vec3(0,0,10),new Vec3(0,0,0),new Vec3(0,1,0)).transformPoint(new Vec3(0,0,10)).length()<0.001 && localStorage.get('flag')===false && localStorage.get('value').x===7 && shared.counter>0; thisLayer.origin=new Vec3(good?123:456,540,0); return 'MATH'; }", enabled: true)
        try await run("scene-settings", code: "export function update(value) { thisLayer.origin=new Vec3(123,540,0); thisScene.clearcolor=new Vec3(0.02,0.75,0.02); thisScene.bloom=false; return 'SCENE'; }", enabled: true) { host in
            try await Task.sleep(for: .milliseconds(250))
            let frame = try await host.capture(time: 0.5, width: 320, height: 180)
            guard let bitmap = NSBitmapImageRep(data: frame), let color = bitmap.colorAt(x: 310, y: 10)?.usingColorSpace(.deviceRGB), color.greenComponent > 0.5 else { throw LumaError("SceneScript scene color did not cross the worker bridge.") }
        }
        try await run("wall-clock-and-style", code: "export function update(value) { thisLayer.origin = new Vec3(123, 540, 0); return JSON.stringify({now:Date.now(),date:new Date().getTime(),year:new Date().getFullYear(),size:thisLayer.pointsize,font:thisLayer.font,width:engine.canvasSize.divide(2).x,screen:engine.screenResolution.divide(2).x}); }", enabled: true) { host in
            func sample() async throws -> [String: Any] {
                let layer = try await host.editorLayerProperties(id: "1")
                guard let text = layer?["text"] as? String, let bytes = text.data(using: .utf8),
                      let value = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                      let now = value["now"] as? Double, let date = value["date"] as? Double,
                      abs(now - Date().timeIntervalSince1970 * 1000) < 10_000, abs(now - date) < 100,
                      (value["year"] as? Int) == Calendar.current.component(.year, from: Date()),
                      (value["size"] as? Int) == 32, (value["font"] as? String) == "systemfont_arial",
                      (value["width"] as? Int) == 960, (value["screen"] as? Double ?? 0) > 0
                else { throw LumaError("Wall clock or style bridge failed: \(Safety.json(layer ?? [:])); \(await host.editorScriptDiagnostics())") }
                return value
            }
            let before = try await sample()
            try await Task.sleep(for: .milliseconds(350))
            let after = try await sample()
            guard (after["now"] as! Double) > (before["now"] as! Double) else { throw LumaError("Wall clock stopped advancing.") }
        }
        try await run("text-style-writeback", code: "export function update(value) { thisLayer.origin = new Vec3(123, 540, 0); thisLayer.pointsize=40; thisLayer.font='systemfont_arial'; thisLayer.opaquebackground=true; thisLayer.backgroundcolor=new Vec3(0.2,0.3,0.4); thisLayer.color.x=0.2; thisLayer.padding=12; thisLayer.horizontalalign='left'; thisLayer.verticalalign='top'; thisLayer.limitwidth=true; thisLayer.maxwidth=1500; thisLayer.limitrows=true; thisLayer.maxrows=2; thisLayer.alpha=0.75; thisLayer.spacing=new Vec2(3,5); thisLayer.castshadow=true; return 'STYLE BRIDGE'; }", enabled: true) { host in
            let value = try await host.editorLayerProperties(id: "1") ?? [:]
            guard (value["text"] as? String) == "STYLE BRIDGE", (value["textPointsize"] as? Int) == 40,
                  (value["textOpaquebackground"] as? Bool) == true, (value["textCastshadow"] as? Bool) == true,
                  (value["textSpacing"] as? [NSNumber])?.map(\.intValue) == [3,5],
                  (value["textPadding"] as? Int) == 12, (value["textHAlign"] as? String) == "left",
                  (value["textVAlign"] as? String) == "top", (value["textMaxrows"] as? Int) == 2,
                  (value["textMaxwidth"] as? Int) == 1500, (value["alpha"] as? Double) == 0.75,
                  (value["textBackgroundcolor"] as? [NSNumber])?.first?.doubleValue == 0.2,
                  (value["textColor"] as? [NSNumber])?.first?.doubleValue == 0.2
            else { throw LumaError("Text style writes did not reach the renderer: \(Safety.json(value))") }
            try await Task.sleep(for: .milliseconds(200))
            let frame = try await host.capture(time: 0.4, width: 320, height: 180)
            guard let bitmap = NSBitmapImageRep(data: frame) else { throw LumaError("Text-style scene frame was not decodable.") }
            let styledBackgroundPixels = (0..<bitmap.pixelsHigh).reduce(0) { count, y in
                count + (0..<bitmap.pixelsWide).reduce(0) { partial, x in
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return partial }
                    return partial + (c.redComponent < 0.08 && c.greenComponent > 0.15 && c.blueComponent > 0.20 ? 1 : 0)
                }
            }
            guard styledBackgroundPixels > 40 else { throw LumaError("Script text background styling did not appear in the rendered frame (matched pixels: \(styledBackgroundPixels)).") }
        }
        try await run("nested-layer-snapshot-writeback", code: "export function update(value) { const layers=thisScene.enumerateLayers(); const byName=thisScene.getLayer('Second Layer'); const byID=thisScene.getLayerByID(2); const before=byID?.text; if (byName) byName.text='NESTED UPDATED'; if (byID) { byID.origin.x=320; byID.origin.y=300; } thisLayer.origin=new Vec3(123,540,0); return JSON.stringify({length:layers.length,ids:layers.map(layer=>layer.id),named:byName?.id,idText:before}); }", enabled: true, extraLayer: true) { host in
            let sourceLayer = try await host.editorLayerProperties(id: "1") ?? [:]
            let resultData = (sourceLayer["text"] as? String ?? "").data(using: .utf8) ?? Data()
            let result = (try? JSONSerialization.jsonObject(with: resultData)) as? [String: Any] ?? [:]
            let target = try await host.editorLayerProperties(id: "2") ?? [:]
            guard result["length"] as? Int == 2, (result["ids"] as? [Int]) == [1, 2], result["named"] as? Int == 2, result["idText"] is String,
                  target["text"] as? String == "NESTED UPDATED", (target["origin"] as? [NSNumber])?.first?.doubleValue == 320
            else { throw LumaError("Nested layer references did not write through: result=\(Safety.json(result)), target=\(Safety.json(target)), hostLayers=\(Safety.json(try await host.editorLayers()))") }
            let frame = try await host.capture(time: 0.3, width: 320, height: 180)
            guard let bitmap = NSBitmapImageRep(data: frame) else { throw LumaError("Nested-layer rendered frame was not decodable.") }
            let changed = (0..<bitmap.pixelsHigh).reduce(0) { count, y in
                count + (0..<bitmap.pixelsWide).reduce(0) { partial, x in
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return partial }
                    return partial + ((c.greenComponent > 0.2 && c.redComponent < 0.8) ? 1 : 0)
                }
            }
            guard changed > 10 else { throw LumaError("Updated scene text was not present in the rendered frame.") }
        }
        try await run("audio-buffer-types-and-provider-diagnostic", code: "export function update(value) { const buffers=engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_32); const isFloat32=value=>Object.prototype.toString.call(value)==='[object Float32Array]'; const ok=isFloat32(buffers.left) && isFloat32(buffers.right) && isFloat32(buffers.average) && buffers.left.length===32 && buffers.right.length===32 && buffers.average.length===32; thisLayer.origin=new Vec3(ok?123:456,540,0); return ok?'AUDIO TYPES':'BAD AUDIO'; }", enabled: true, expectedDiagnostic: "live system capture requires")
        try await run("unsupported-api-diagnostic", code: "export function update(value) { try { thisLayer.getVideoTexture(); } catch (_) {} try { thisLayer.getBoneCount(); } catch (_) {} thisLayer.origin=new Vec3(123,540,0); return 'DIAGNOSED'; }", enabled: true, expectedDiagnostic: "no active video decoder")
        try await run("media-events", code: "let title=''; export function mediaPropertiesChanged(event) { title=event.title+'|'+event.artist+'|'+event.albumTitle; } export function mediaTimelineChanged(event) { shared.position=event.position; } export function update(value) { thisLayer.origin=new Vec3(123,540,0); return title; }", enabled: true) { host in
            for title in ["First track", "Second track"] {
                _ = try await host.webView.callAsyncJavaScript("window.lumaSetMedia({hasMedia:true,state:1,title:title,artist:'Artist',album:'Album',position:12,duration:90});", arguments: ["title": title], in: nil, contentWorld: .page)
                let deadline = Date().addingTimeInterval(5)
                var text = ""
                repeat {
                    try await Task.sleep(for: .milliseconds(100))
                    text = (try await host.editorLayerProperties(id: "1"))?["text"] as? String ?? ""
                    if text == "\(title)|Artist|Album" { break }
                } while Date() < deadline
                guard text == "\(title)|Artist|Album" else { throw LumaError("Track metadata did not update SceneScript text: \(text)") }
            }
        }
        try await run("missing-particle-provider", code: "export function update(value) { try { thisLayer.getParticleSystem().play(); } catch (_) {} thisLayer.origin=new Vec3(123,540,0); return 'PARTICLE'; }", enabled: true, extraParticle: true, expectedDiagnostic: "no active particle renderer")
        try await run("no-fabricated-media-metadata", code: "let title=''; export function mediaPropertiesChanged(event) { title=event.title; } export function update(value) { thisLayer.origin=new Vec3(123,540,0); return title; }", enabled: true, expectedDiagnostic: "selected Music/Spotify") { host in
            try await Task.sleep(for: .milliseconds(300))
            let value = try await host.editorLayerProperties(id: "1") ?? [:]
            guard value["text"] as? String == "" else { throw LumaError("A missing media provider fabricated SceneScript metadata: \(Safety.json(value))") }
        }
        try await run("init-only", code: clock.replacingOccurrences(of: "function update", with: "function init"), enabled: true)
        try await run("disabled-scripts", code: clock, enabled: false)
        try await run("stale-approval", code: clock, enabled: true, staleApproval: true)
        try await run("syntax-error", code: "export function update(value) { broken( }", enabled: true, rejected: true)
        try await run("capability-boundary", code: "export function update(value) { let leaked = false; try { leaked = thisLayer.getParent.constructor('return typeof fetch !== typeof undefined || typeof postMessage !== typeof undefined || typeof document !== typeof undefined')(); } catch (error) {} thisLayer.origin = new Vec3(!leaked && typeof fetch === 'undefined' && typeof document === 'undefined' && (typeof window === 'undefined' || typeof window.document === 'undefined') ? 123 : 456, 540, 0); return 'BOUNDARY'; }", enabled: true)
        try await run("initialization-loop", code: "while (true) {} export function update(value) { return value; }", enabled: true, timeoutEvent: "initialization")
        try await run("init-hook-loop", code: "export function init(value) { while (true) {} } export function update(value) { return value; }", enabled: true, timeoutEvent: "init")
        try await run("update-loop", code: "export function update(value) { while (true) {} }", enabled: true, timeoutEvent: "update")
        try await run("timer-loop", code: "export function init() { engine.setTimeout(()=>{while(true){}},20); } export function update(value) { return value; }", enabled: true, timeoutEvent: "timerTimeout")
    }
}

import Foundation
import AppKit
import AVFoundation

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
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("LumaSceneTests-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
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
        window.isReleasedWhenClosed=false;window.ignoresMouseEvents=true;window.contentView=host.webView;window.orderBack(nil)
        defer {host.stop();window.close()}
        var error:String?
        host.failed={error=$0};host.diagnostic={print("Scene diagnostic:",$0)}
        let deadline=Date().addingTimeInterval(40)
        while !host.didBecomeReady {if let error{throw LumaError(error)};guard Date()<deadline else {throw LumaError("No scene frame arrived")};try await Task.sleep(for:.milliseconds(100))}
        guard await host.editorAvailable() else { throw LumaError("The bundled WebWallGL editor API did not attach to a scene preview.") }
        let editorLayers = try await host.editorLayers()
        guard editorLayers.count == 1 else { throw LumaError("The editor API did not return the fixture layer.") }
        print("Editor layer snapshot:", Safety.json(editorLayers))
        let selectedLayerID = editorLayers.first?["id"].map(String.init(describing:)) ?? "1"
        let layerProperties = try await host.editorLayerProperties(id: selectedLayerID)
        guard layerProperties != nil else { throw LumaError("The editor API could not read the selected layer properties.") }
        let textHotAdd = await host.editorCanHotAdd(spec: ["duplicateOf": 1])
        guard !textHotAdd.0, !textHotAdd.1.isEmpty else { throw LumaError("The renderer's hot-add capability check did not reject an unsupported text-layer insert.") }
        host.setPlaying(false)
        await host.editorSeek(0.5)
        let seekTime = await host.editorTime()
        guard abs(seekTime - 0.5) < 0.1 else { throw LumaError("The editor timeline did not synchronize its seek with the preview clock.") }
        let hitLayers = try await host.editorHitTest(x: 160, y: 90)
        print("Editor center hit test:", Safety.json(hitLayers))
        guard hitLayers.contains(selectedLayerID) else { throw LumaError("The editor hit test did not select the visible fixture layer.") }
        host.editorSetPreviewQuality(antiAliasing: "fxaa", particles: "medium", postProcessing: "low")
        try await Task.sleep(for: .milliseconds(100))
        let frame=try await host.capture(time:0,width:320,height:180)
        guard let bitmap=NSBitmapImageRep(data:frame),bitmap.pixelsWide == 320,bitmap.pixelsHigh == 180 else {throw LumaError("Scene frame dimensions are wrong")}
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

    @MainActor static func verifyScripts(root: URL, resources: URL, template: [String: Any]) async throws {
        func project(_ name: String, code: String) throws -> URL {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            var object = template
            var layer = (object["objects"] as! [[String: Any]])[0]
            layer["text"] = ["value": "BASE", "script": code]
            object["objects"] = [layer]
            let scene = try JSONSerialization.data(withJSONObject: object)
            var package = Data()
            func number(_ n: Int) { var n = UInt32(n).littleEndian; withUnsafeBytes(of: &n) { package.append(contentsOf: $0) } }
            number(8); package.append(Data("PKGV0012".utf8)); number(1)
            number(10); package.append(Data("scene.json".utf8)); number(0); number(scene.count); package.append(scene)
            try package.write(to: folder.appendingPathComponent("scene.pkg"))
            try Data("{\"title\":\"Script fixture\",\"type\":\"scene\",\"file\":\"scene.pkg\"}".utf8).write(to: folder.appendingPathComponent("project.json"))
            return folder
        }
        func run(_ name: String, code: String, enabled: Bool, staleApproval: Bool = false, rejected: Bool = false, timeoutEvent: String? = nil) async throws {
            let folder = try project(name, code: code)
            let review = try SceneScriptReview.inspect(folder: folder)
            guard review.canApprove else { throw LumaError("Script fixture did not produce a complete source review (\(review.sources.count) sources): \(review.issues.joined(separator: "; "))") }
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
                guard Date() < deadline else { throw LumaError("Script fixture did not render: \(name); \(diagnostics.joined(separator: "; "))") }
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
                let expected = enabled && !staleApproval && !rejected ? 123.0 : 960.0
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
                guard origin?.first?.doubleValue == expected else { throw LumaError("Script approval/clock check failed for \(name): \(Safety.json(properties ?? [:])); time \(await host.editorTime()); \((diagnostics + issues).joined(separator: "; "))") }
                if rejected {
                    guard !(diagnostics + issues).isEmpty, !diagnostics.contains(where: { $0.contains("timed out") }) else { throw LumaError("A rejected script caused a false watchdog timeout.") }
                }
            }
            host.stop()
            guard !host.didBecomeReady else { throw LumaError("Stopped host remained ready.") }
            print("PASS: SceneScript \(name)")
        }
        let clock = "export function update(value) { thisLayer.origin = new Vec3(typeof engine.runtime === 'number' && typeof engine.timeOfDay === 'number' ? 123 : 456, 540, 0); return 'CLOCK OK'; }"
        try await run("reviewed-clock", code: clock, enabled: true)
        try await run("init-only", code: clock.replacingOccurrences(of: "function update", with: "function init"), enabled: true)
        try await run("disabled-scripts", code: clock, enabled: false)
        try await run("stale-approval", code: clock, enabled: true, staleApproval: true)
        try await run("syntax-error", code: "export function update(value) { broken( }", enabled: true, rejected: true)
        try await run("capability-boundary", code: "export function update(value) { let leaked = false; try { leaked = thisLayer.getParent.constructor('return typeof fetch !== typeof undefined || typeof postMessage !== typeof undefined || typeof document !== typeof undefined')(); } catch (error) {} thisLayer.origin = new Vec3(!leaked && typeof fetch === 'undefined' && typeof document === 'undefined' && (typeof window === 'undefined' || typeof window.document === 'undefined') ? 123 : 456, 540, 0); return 'BOUNDARY'; }", enabled: true)
        try await run("initialization-loop", code: "while (true) {} export function update(value) { return value; }", enabled: true, timeoutEvent: "initialization")
        try await run("init-hook-loop", code: "export function init(value) { while (true) {} } export function update(value) { return value; }", enabled: true, timeoutEvent: "init")
        try await run("update-loop", code: "export function update(value) { while (true) {} }", enabled: true, timeoutEvent: "update")
    }
}

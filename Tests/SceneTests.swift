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
        // Keep WebKit's rendering surface visible for the full regression run.
        // A window ordered behind the desktop can have its web content process
        // reclaimed while capture/export is exercising the scene renderer.
        window.isReleasedWhenClosed=false;window.ignoresMouseEvents=true;window.contentView=host.webView;window.orderFrontRegardless()
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
        _ = try await host.webView.callAsyncJavaScript("HTMLCanvasElement.prototype.toBlob=function(callback){callback(null)}; return true", arguments: [:], in: nil, contentWorld: .page)
        let fallbackFrame = try await host.capture(time: 0.1, width: 320, height: 180)
        guard let fallbackBitmap = NSBitmapImageRep(data: fallbackFrame), fallbackBitmap.pixelsWide == 320, fallbackBitmap.pixelsHigh == 180 else { throw LumaError("Scene capture did not fall back to a data URL when canvas.toBlob returned null.") }
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
        func run(_ name: String, code: String, enabled: Bool, staleApproval: Bool = false, rejected: Bool = false, timeoutEvent: String? = nil, helper: String? = nil, objectScript: String? = nil, extraLayer: Bool = false, extraParticle: Bool = false, expectedDiagnostic: String? = nil, check: ((SceneHost) async throws -> Void)? = nil) async throws {
            let folder = try project(name, code: code, helper: helper, objectScript: objectScript, extraLayer: extraLayer, extraParticle: extraParticle)
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
        try await run("mixed-text-object-updates", code: clock, enabled: true, objectScript: "export function update(value) { return value; }")
        try await run("isolated-random", code: "export function update(value) { const first=Math.random(),second=Math.random(); thisLayer.origin=new Vec3(first>=0 && first<1 && second>=0 && second<1 && first!==second?123:456,540,0); return 'RANDOM'; }", enabled: true)
        try await run("layer-transform-matrix", code: "export function update(value) { const world=thisLayer.getTransformMatrix().transformPoint(new Vec3(0,0,0)); const good=world.subtract(thisLayer.origin).length()<0.001; thisLayer.origin=new Vec3(good?123:456,540,0); return 'TRANSFORM'; }", enabled: true)
        try await run("bounded-timers", code: "export function init() { shared.cancelledRan=false; const cancel=engine.setTimeout(()=>{shared.cancelledRan=true;},1); cancel(); engine.setTimeout(()=>{thisLayer.origin=new Vec3(!shared.cancelledRan && Date.now()>1000000000000?123:456,540,0);},50); } export function update(value) { return 'TIMERS'; }", enabled: true)
        try await run("shared-functions-and-storage", code: "export function update(value) { const good=typeof shared.double==='function' && shared.double(21)===42 && shared.elapsed()>0 && localStorage.get('sibling')===true; thisLayer.origin=new Vec3(good?123:456,540,0); return 'SHARED'; }", enabled: true, helper: "export function init() { shared.double=value=>value*2; shared.elapsed=()=>engine.runtime; localStorage.set('sibling',true); }")
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

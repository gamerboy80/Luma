import Foundation
import AppKit
import AVFoundation

@main struct CoreTests {
    @MainActor private static var currentPhase = "test initialization"

    @MainActor static func main() async {
        do { try await run() }
        catch {
            let diagnostic = "CORE TEST FAILED during \(currentPhase): \(String(reflecting: error))\n"
            FileHandle.standardError.write(Data(diagnostic.utf8))
            exit(1)
        }
    }

    @MainActor private static func run() async throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1; guard condition() else { throw LumaError("FAILED: \(message)") }
        }
        func rejects(_ body: () throws -> Void) throws {
            do { try body() } catch { assertions += 1; return }; throw LumaError("FAILED: unsafe input was accepted")
        }
        currentPhase = "display adjustment geometry and draft ownership"
        let landscape = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let square = CGSize(width: 1000, height: 1000)
        try check(WallpaperPlacement.orientedPixels(CGSize(width: 1920, height: 1080), orientation: 6) == CGSize(width: 1080, height: 1920), "rotated image metadata uses the oriented pixel dimensions")
        var placement = DisplayConfiguration()
        try check(WallpaperPlacement.contentRect(in: landscape, sourcePixels: square, displayPixels: landscape.size, configuration: placement) == CGRect(x: 0, y: -420, width: 1920, height: 1920), "Fill crops square media to a landscape display")
        placement.fit = .contain
        try check(WallpaperPlacement.contentRect(in: landscape, sourcePixels: square, displayPixels: landscape.size, configuration: placement) == CGRect(x: 420, y: 0, width: 1080, height: 1080), "Fit preserves aspect ratio and centers letterboxing")
        placement.fit = .stretch
        try check(WallpaperPlacement.contentRect(in: landscape, sourcePixels: square, displayPixels: landscape.size, configuration: placement) == landscape, "Stretch fills the entire display")
        placement.fit = .center
        let hd = CGSize(width: 960, height: 540)
        try check(WallpaperPlacement.frame(in: landscape, configuration: placement, sourcePixels: hd, displayPixels: landscape.size) == CGRect(x: 480, y: 270, width: 960, height: 540), "Center retains one source pixel per display backing pixel")
        try check(WallpaperPlacement.frame(in: CGRect(x: 0, y: 0, width: 960, height: 540), configuration: placement, sourcePixels: hd, displayPixels: landscape.size) == CGRect(x: 240, y: 135, width: 480, height: 270), "Center respects HiDPI logical-to-backing scale")
        placement.fit = .cover; placement.scale = 2; placement.offsetX = 0.1; placement.offsetY = -0.2
        try check(WallpaperPlacement.frame(in: landscape, configuration: placement) == CGRect(x: -768, y: -756, width: 3840, height: 2160), "zoom and positioning preserve existing native placement semantics")
        try check(WallpaperPlacement.frame(in: CGRect(x: 0, y: 0, width: 480, height: 270), configuration: placement) == CGRect(x: -192, y: -189, width: 960, height: 540), "the preview and desktop use proportionally identical placement")
        try check(WallpaperPlacement.previewSize(display: CGSize(width: 1080, height: 1920), available: CGSize(width: 600, height: 400)) == CGSize(width: 225, height: 400), "rotated display previews retain portrait shape")
        try check(WallpaperPlacement.previewSize(display: landscape.size, available: CGSize(width: 600, height: 400)) == CGSize(width: 600, height: 337.5), "landscape previews fit available space without distortion")
        try check(WallpaperPlacement.previewSize(display: .zero, available: landscape.size) == .zero, "a disconnected or zero-size display does not produce invalid geometry")
        let dragged = WallpaperPlacement.draggedOffsets(start: .zero, translation: CGSize(width: 48, height: 27), previewSize: CGSize(width: 480, height: 270))
        try check(abs(dragged.width - 0.1) < 0.0001 && abs(dragged.height + 0.1) < 0.0001, "dragging converts SwiftUI's downward y axis into desktop offsets")
        try check(WallpaperPlacement.draggedOffsets(start: dragged, translation: .zero, previewSize: .zero) == dragged, "display disappearance during dragging preserves the last valid position")
        var draft = DisplayAdjustmentDraft(displayID: "screen-A", configuration: DisplayConfiguration())
        draft.configuration = placement
        try check(draft.hasChanges, "adjustments remain an unsaved draft")
        let otherSettings = DisplayConfiguration(wallpaperID: UUID(), paused: true, enabled: false, fit: .center, scale: 2, offsetX: 0.2, offsetY: -0.1, volume: 0.4, speed: 1.5)
        var reset = DisplayAdjustmentDraft(displayID: "screen-A", configuration: otherSettings); reset.resetPlacement()
        try check(reset.configuration.fit == .cover && reset.configuration.scale == 1 && reset.configuration.offsetX == 0 && reset.configuration.offsetY == 0 && reset.configuration.wallpaperID == otherSettings.wallpaperID && reset.configuration.volume == 0.4 && reset.configuration.speed == 1.5 && !reset.configuration.enabled, "reset only changes placement, preserving assignment and playback settings")
        let accepted = try draft.validated(connectedIDs: ["screen-A", "screen-B"], saved: DisplayConfiguration())
        try check(accepted == placement && draft.displayID == "screen-A", "a draft is bound to its intended persistent display ID")
        try rejects { _ = try draft.validated(connectedIDs: ["screen-B"], saved: DisplayConfiguration()) }
        try rejects { _ = try draft.validated(connectedIDs: ["screen-A"], saved: otherSettings) }
        let centerRoundTrip = try JSONDecoder().decode(DisplayConfiguration.self, from: JSONEncoder().encode(otherSettings))
        try check(centerRoundTrip == otherSettings, "Center placement persists with display-specific settings")
        currentPhase = "scene media metadata and fixed query checks"
        let track = SceneMediaProvider.decode(["playing", "A \"title\"\nwith text", "Artist", "Album", "Album Artist", "12.5", "180", "3"])
        try check(track.available && track.title == "A \"title\"\nwith text" && track.position == 12.5 && track.duration == 180, "track metadata preserves text and timeline")
        try check(track.artist == "Artist" && track.albumArtist == "Album Artist" && track.trackIndex == 3, "all supplied track fields")
        try check(SceneMediaProvider.decode([]) == .empty, "invalid metadata is empty")
        let invalidTrack = SceneMediaProvider.decode(["unknown", "Title", "", "", "", "nan", "inf", "-7"])
        try check(invalidTrack.position == 0 && invalidTrack.duration == 0 && invalidTrack.trackIndex == 0 && invalidTrack.state == "stopped", "metadata rejects nonfinite or negative values")
        try check(JSONSerialization.isValidJSONObject(track.json), "track data is safe for the script snapshot")
        let response = try JSONSerialization.data(withJSONObject: ["playing", "A \"title\"\n曲", "Artist", "Album", "Album Artist", 12.5, 180, 3] as [Any])
        let processTrack = try SceneMediaProvider.decodeResponse(response).get()
        try check(processTrack.title == "A \"title\"\n曲" && processTrack.position == 12.5 && processTrack.trackIndex == 3, "process metadata safely decodes JSON text and numeric fields")
        try rejects { _ = try SceneMediaProvider.decodeResponse(Data("not JSON".utf8)).get() }
        try rejects { _ = try SceneMediaProvider.decodeResponse(Data("[\"playing\",{}]".utf8)).get() }
        try rejects { _ = try SceneMediaProvider.decodeResponse(Data(repeating: 32, count: 65_537)).get() }
        let encoderSize = try TemporalEncoder.dimensions(for: CGSize(width: 128, height: 72))
        try check(encoderSize.width == 128 && encoderSize.height == 72, "encoder accepts ordinary video dimensions")
        try rejects { _ = try TemporalEncoder.dimensions(for: CGSize(width: CGFloat.infinity, height: 72)) }
        try rejects { _ = try TemporalEncoder.dimensions(for: CGSize(width: 8193, height: 72)) }
        try check(TemporalEncoder.frameRate(from: Float.greatestFiniteMagnitude) == 240 && TemporalEncoder.frameRate(from: Float.nan) == 30, "encoder clamps unsafe frame rates before integer conversion")
        let largeTimestampBoundary = try TemporalEncoder.frameBoundary(normalizedSeconds: 1e300, fps: 60, totalFrames: 10_000)
        let negativeTimestampBoundary = try TemporalEncoder.frameBoundary(normalizedSeconds: -1e300, fps: 60, totalFrames: 10_000)
        try check(largeTimestampBoundary == 10_000,
                  "large but finite presentation timestamps clamp before Int64 conversion")
        try check(negativeTimestampBoundary == 0,
                  "negative presentation timestamps clamp before Int64 conversion")
        let ordinaryFrameCount = try TemporalEncoder.frameCount(duration: 2, fps: 30)
        try check(ordinaryFrameCount == 60, "encoder calculates bounded frame counts")
        try rejects { _ = try TemporalEncoder.frameCount(duration: 1e300, fps: 60) }
        try rejects { _ = try TemporalEncoder.frameBoundary(normalizedSeconds: .nan, fps: 60, totalFrames: 10_000) }
        for source in [SceneMediaProvider.Source.music, .spotify] {
            var scriptError: NSDictionary?
            let query = NSAppleScript(source: SceneMediaProvider.metadataScript(for: source))
            let queryCompiles = query?.compileAndReturnError(&scriptError) == true
            try check(queryCompiles, "fixed \(source.title) metadata query compiles without executing automation: \(scriptError ?? [:])")
            let processQuery = NSAppleScript(source: SceneMediaProvider.metadataProcessScript(for: source))
            let processQueryCompiles = processQuery?.compileAndReturnError(&scriptError) == true
            try check(processQueryCompiles, "fixed \(source.title) subprocess query compiles without executing automation: \(scriptError ?? [:])")
        }
        try check(!SceneMediaProvider.metadataScript(for: .spotify).contains("/ 1000.0"), "Spotify duration is kept in the seconds used by its Apple Event dictionary")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LumaTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        currentPhase = "asynchronous project import responsiveness and cancellation"
        let largeProject = root.appendingPathComponent("many-assets-project", isDirectory: true)
        let projectAssets = largeProject.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: projectAssets, withIntermediateDirectories: true)
        try Data("{\"title\":\"Import responsiveness fixture\",\"type\":\"web\",\"file\":\"index.html\"}".utf8)
            .write(to: largeProject.appendingPathComponent("project.json"))
        try Data("<!doctype html><title>Import fixture</title>".utf8).write(to: largeProject.appendingPathComponent("index.html"))
        for index in 0..<2_500 {
            try Data("asset-\(index)".utf8).write(to: projectAssets.appendingPathComponent("asset-\(index).txt"))
        }

        let cancelledCopyLibrary = LibraryStore(root: root.appendingPathComponent("cancelled-project-copy-library"))
        let cancelledCopyMediaRoot = cancelledCopyLibrary.root.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: cancelledCopyMediaRoot, withIntermediateDirectories: true)
        let mediaBeforeCancelledCopy = Set(try FileManager.default.contentsOfDirectory(atPath: cancelledCopyMediaRoot.path))
        let cancelledCopy = Task { try await cancelledCopyLibrary.importURL(largeProject) }
        while !cancelledCopyLibrary.hasImportInProgress { await Task.yield() }
        cancelledCopy.cancel()
        do { try await cancelledCopy.value; throw LumaError("FAILED: cancelled project copy published a wallpaper") }
        catch is CancellationError { assertions += 1 }
        let mediaAfterCancelledCopy = Set(try FileManager.default.contentsOfDirectory(atPath: cancelledCopyMediaRoot.path))
        try check(!cancelledCopyLibrary.hasImportInProgress &&
                  !cancelledCopyLibrary.state.wallpapers.contains(where: { !$0.isBuiltIn }) &&
                  mediaAfterCancelledCopy == mediaBeforeCancelledCopy &&
                  FileManager.default.fileExists(atPath: largeProject.appendingPathComponent("project.json").path),
                  "cancelling an asynchronous project copy removes partial managed data and preserves the source")

        let responsiveImportLibrary = LibraryStore(root: root.appendingPathComponent("responsive-import-library"))
        var responsiveImportFinished = false
        var mainActorRanDuringImport = false
        let mainActorHeartbeat = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(10))
            mainActorRanDuringImport = responsiveImportLibrary.hasImportInProgress && !responsiveImportFinished
        }
        try await responsiveImportLibrary.importURL(largeProject)
        responsiveImportFinished = true
        try await mainActorHeartbeat.value
        try check(mainActorRanDuringImport && responsiveImportLibrary.state.wallpapers.contains(where: { $0.title == "Import responsiveness fixture" }),
                  "large project validation and copying leave the main actor responsive and publish after success")

        let unsafePreferenceRoot = root.appendingPathComponent("UnsafePreferences")
        try FileManager.default.createDirectory(at: unsafePreferenceRoot, withIntermediateDirectories: true)
        var unsafePreferences = SavedLibrary(); unsafePreferences.preferences.playlistSeconds = 1e300
        try JSONEncoder().encode(unsafePreferences).write(to: unsafePreferenceRoot.appendingPathComponent("library.json"))
        let normalizedLibrary = LibraryStore(root: unsafePreferenceRoot)
        try check(normalizedLibrary.state.preferences.playlistSeconds == 86_400,
                  "untrusted persisted playlist intervals normalize to the supported range")

        let failedEditRoot = root.appendingPathComponent("FailedLibraryEdit")
        let failedEditStore = LibraryStore(root: failedEditRoot)
        let failedEditID = UUID()
        failedEditStore.state.wallpapers.append(Wallpaper(id: failedEditID, title: "Fixture", kind: .web,
                                                          folder: failedEditID.uuidString, entry: "index.html"))
        try check(failedEditStore.save(), "save a library fixture before testing a failed edit")
        let libraryFile = failedEditRoot.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: libraryFile)
        try FileManager.default.createDirectory(at: libraryFile, withIntermediateDirectories: false)
        let editSucceeded = failedEditStore.edit(failedEditID) { $0.favorite = true }
        try check(!editSucceeded && failedEditStore.state.wallpapers.first?.favorite == false,
                  "failed library persistence rolls back the in-memory wallpaper edit")

        currentPhase = "path, ownership, playback, and native catalog policy checks"
        for invalid in ["../outside","/etc/passwd","a/../../b","a/./b","a\\..\\b", "nul\0file"] { try rejects { _ = try Safety.child(invalid, under: root) } }
        let link = root.appendingPathComponent("escape"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.deletingLastPathComponent())
        try rejects { _ = try Safety.child("escape/private", under: root) }
        let normal = try Safety.child("models/a.json", under: root)
        try check(normal.path.hasPrefix(root.path), "normal project path")
        try check(Safety.workshopID("https://steamcommunity.com/sharedfiles/filedetails/?id=123456") == "123456", "Steam URL")
        try check(Safety.workshopID("123456") == "123456", "Steam numeric ID")
        try check(Safety.workshopID("https://evil.example/?id=123456") == nil, "reject non-Steam host")
        try check(Safety.workshopID("123; touch /tmp/no") == nil, "reject command injection")
        let previousStill = root.appendingPathComponent("previous.png"), nextStill = root.appendingPathComponent("next.png")
        let stillReceipt = DesktopStillReceipt(screenID: "fixture", originalURL: root.appendingPathComponent("original.png"), installedURL: nextStill, generatedURLs: [previousStill, nextStill])
        let reloadedStillReceipt = try JSONDecoder().decode(DesktopStillReceipt.self, from: JSONEncoder().encode(stillReceipt))
        try check(reloadedStillReceipt.ownedURLs.contains(previousStill) && reloadedStillReceipt.ownedURLs.contains(nextStill), "desktop receipt retains both generated stills across interrupted replacement")
        let legacyStillData = try JSONSerialization.data(withJSONObject: ["screenID": "fixture", "installedURL": nextStill.absoluteString])
        let legacyStillReceipt = try JSONDecoder().decode(DesktopStillReceipt.self, from: legacyStillData)
        try check(legacyStillReceipt.ownedURLs == [nextStill], "legacy desktop receipts retain ownership without the new generated-file list")
        let stillDirectory = root.appendingPathComponent("DesktopStills", isDirectory: true)
        try FileManager.default.createDirectory(at: stillDirectory, withIntermediateDirectories: true)
        let stillID = UUID()
        let stillURL = stillDirectory.appendingPathComponent("\(stillID.uuidString).png")
        let originalDesktop = root.appendingPathComponent("original-desktop.png")
        try Data("still".utf8).write(to: stillURL)
        try Data("original".utf8).write(to: originalDesktop)
        let validStillReceipt = DesktopStillReceipt(screenID: "display-1", originalURL: originalDesktop, installedURL: stillURL, generatedURLs: [stillURL])
        try DesktopStillOwnership.validate(["display-1": validStillReceipt], directory: stillDirectory)
        try check(true, "valid desktop still ownership stays inside its managed directory")
        let outsideStill = root.appendingPathComponent("\(UUID().uuidString).png")
        try Data("outside".utf8).write(to: outsideStill)
        let escapedStillReceipt = DesktopStillReceipt(screenID: "display-1", originalURL: originalDesktop, installedURL: outsideStill)
        try rejects { try DesktopStillOwnership.validate(["display-1": escapedStillReceipt], directory: stillDirectory) }
        let symlinkStill = stillDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try FileManager.default.createSymbolicLink(at: symlinkStill, withDestinationURL: outsideStill)
        let symlinkStillReceipt = DesktopStillReceipt(screenID: "display-1", originalURL: originalDesktop, installedURL: symlinkStill)
        try rejects { try DesktopStillOwnership.validate(["display-1": symlinkStillReceipt], directory: stillDirectory) }
        try FileManager.default.removeItem(at: symlinkStill)
        var policy = PlaybackPolicy(userPaused: false, holds: ["sleep", "battery"])
        try check(!policy.shouldPlay, "all holds respected"); policy.holds.remove("sleep"); try check(!policy.shouldPlay, "removing one hold keeps others"); policy.userPaused = true; policy.holds.removeAll(); try check(!policy.shouldPlay, "manual pause survives wake"); policy.userPaused = false; try check(policy.shouldPlay, "resume with no holds")
        let original: [String: Any] = ["version":77,"unknown":["preserve":true],"assets":[["id":"apple","categories":["apple-category"]],["id":"third-party","categories":["third"]]],"categories":[["id":"apple-category","extra":123]]]
        let added = try NativeCatalog.adding(assetID:"luma-owned", title:"Test", video:root.appendingPathComponent("test.mov"), thumbnail:root.appendingPathComponent("test.png"), to:original)
        try check((added["assets"] as? [[String:Any]])?.count == 3,"append custom native asset")
        try check((added["version"] as? Int) == 77,"preserve native version")
        let removed = NativeCatalog.removingOwned(from:added)
        try check(NSDictionary(dictionary:removed).isEqual(to:original),"remove only Luma records")
        try rejects { _ = try NativeCatalog.adding(assetID:"x",title:"t",video:root,thumbnail:root,to:["assets":"unknown"]) }
        let oldConfiguration = try PropertyListSerialization.data(fromPropertyList:["assetID":"old"], format:.binary,options:0)
        let desktop: [String:Any] = ["Content":["Choices":[["Provider":"desktop","Configuration":oldConfiguration]]],"PrivateField":42]
        let idle: [String:Any] = ["Content":["Choices":[["Provider":"idle","Configuration":oldConfiguration,"Preserve":"yes"]],"EncodedOptionValues":Data([1,2,3])],"Settings":["foo":"bar"]]
        let store:[String:Any] = ["AllSpacesAndDisplays":["Desktop":desktop,"Idle":idle],"Unrelated":88]
        let updated = try NativeSelection.selecting(assetID:"new",in:store)
        let all = updated["AllSpacesAndDisplays"] as! [String:Any]
        try check(NSDictionary(dictionary:all["Desktop"] as! [String:Any]).isEqual(to:desktop),"preserve separate desktop")
        let newIdle = all["Idle"] as! [String:Any]; let content = newIdle["Content"] as! [String:Any]; let choices = content["Choices"] as! [[String:Any]]
        try check(choices[0]["Preserve"] as? String == "yes","preserve choice fields")
        try check(content["EncodedOptionValues"] as? Data == Data([1,2,3]),"preserve encoded option values")
        let configuration = try PropertyListSerialization.propertyList(from:choices[0]["Configuration"] as! Data,format:nil) as! [String:Any]
        try check(configuration["assetID"] as? String == "new","write nested asset plist")
        try rejects { _ = try NativeSelection.selecting(assetID:"new",in:["unknown":true]) }
        print("PASS: \(assertions) policy, path, Workshop ID, catalog, and selection assertions")
        let fixture = root.appendingPathComponent("fixture.mov")
        currentPhase = "AVFoundation H.264 fixture encode (128×72, 60 frames)"
        try await makeVideo(fixture)
        currentPhase = "native display adjustment preview"
        _ = NSApplication.shared
        let previewImageURL = root.appendingPathComponent("display-preview.png")
        let previewGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: fixture))
        let previewFrame = try await previewGenerator.image(at: .zero).image
        guard let previewPNG = NSBitmapImageRep(cgImage: previewFrame).representation(using: .png, properties: [:]) else { throw LumaError("Could not encode the adjustment preview fixture.") }
        try previewPNG.write(to: previewImageURL)
        let preview = DisplayWallpaperPreviewView(frame: CGRect(x: 0, y: 0, width: 480, height: 270))
        var previewStatus = ""
        preview.displayPixels = landscape.size
        preview.load(folder: root, media: previewImageURL, assets: nil, wallpaper: Wallpaper(title: "Preview", kind: .image, folder: "", entry: "display-preview.png"), configuration: DisplayConfiguration(), preferences: AppPreferences()) { previewStatus = $0 }
        defer { preview.stop() }
        let previewDeadline = Date().addingTimeInterval(10)
        while previewStatus != "Image preview" { guard Date() < previewDeadline else { throw LumaError("The native adjustment preview did not load: \(previewStatus)") }; try await Task.sleep(for: .milliseconds(25)) }
        for mode in FitMode.allCases {
            preview.configuration.fit = mode; preview.configuration.offsetX = 0.1; preview.configuration.offsetY = -0.1
            preview.layout()
            let expected = WallpaperPlacement.frame(in: preview.bounds, configuration: preview.configuration, sourcePixels: CGSize(width: previewFrame.width, height: previewFrame.height), displayPixels: landscape.size)
            try check(preview.layer?.sublayers?.first?.frame == expected && preview.layer?.masksToBounds == true, "native adjustment preview applies shared \(mode.title) geometry and clips to the display frame")
        }
        preview.stop()
        currentPhase = "video library import, persistence, and ownership rollback checks"
        let library = LibraryStore(root:root.appendingPathComponent("library"))
        try await library.importURL(fixture)
        try check(library.state.wallpapers.count == 1,"import generated video")
        try check(library.state.wallpapers[0].duration ?? 0 > 0,"extract duration")
        let restored = LibraryStore(root:library.root)
        try check(restored.state.wallpapers.count == 1,"restore saved library")

        currentPhase = "pause policy and configuration while a desktop video is still loading"
        if let screen = NSScreen.screens.first {
            _ = NSApplication.shared
            let settingsWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 160, height: 100), styleMask: .titled, backing: .buffered, defer: false)
            let libraryWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 160, height: 100), styleMask: .titled, backing: .buffered, defer: false)
            for window in [settingsWindow, libraryWindow] {
                window.isReleasedWhenClosed = false
                window.alphaValue = 0
                window.orderFrontRegardless()
            }
            defer { settingsWindow.close(); libraryWindow.close() }
            settingsWindow.title = "Luma"
            libraryWindow.title = "Different display title"
            libraryWindow.identifier = LumaWindowIdentity.library
            try check(LumaWindowIdentity.libraryWindow(in: [settingsWindow, libraryWindow]) === libraryWindow,
                      "Open Library selects the tagged library window even when a settings window is listed first")
            libraryWindow.orderOut(nil)
            try check(LumaWindowIdentity.libraryWindow(in: [settingsWindow, libraryWindow]) == nil,
                      "a visible settings window cannot suppress opening a missing library window")
            let pendingLibrary = LibraryStore(root: root.appendingPathComponent("pending-playback-library"))
            try await pendingLibrary.importURL(fixture)
            pendingLibrary.state.preferences.restoreAtLaunch = false
            pendingLibrary.state.preferences.paused = false
            let pendingEngine = DesktopEngine(library: pendingLibrary)
            defer { pendingEngine.shutdown() }
            try check(!pendingEngine.isTrackingPointer, "no cursor polling timer runs without an active scene")
            pendingLibrary.state.preferences.paused = true
            pendingEngine.apply(pendingLibrary.state.wallpapers[0], to: screen.persistentID)
            guard let waiting = pendingEngine.pending[screen.persistentID], let waitingPlayer = waiting.player else {
                throw LumaError("FAILED: the isolated desktop fixture did not create a pending video surface")
            }
            try check(waitingPlayer.rate == 0, "global pause applies to a video before its first frame becomes ready")
            pendingEngine.configure(screen.persistentID) { $0.volume = 0.4; $0.scale = 1.25; $0.fit = .contain }
            try check(abs(waitingPlayer.volume - 0.4) < 0.001 && waiting.configuration.scale == 1.25 && waiting.configuration.fit == .contain && waitingPlayer.rate == 0,
                      "configuration edits reach the pending surface without resuming paused playback")
            // Hide the isolated surface before giving AppKit a run-loop turn;
            // this exercises real AVPlayer readiness without covering the desktop.
            waiting.window.orderOut(nil)
            let firstFrameDeadline = Date().addingTimeInterval(10)
            while pendingEngine.surfaces[screen.persistentID] !== waiting {
                guard Date() < firstFrameDeadline else { throw LumaError("FAILED: paused video never produced a ready first frame: \(pendingEngine.message)") }
                try await Task.sleep(for: .milliseconds(50))
            }
            try check(waiting.ready && waitingPlayer.rate == 0, "a paused desktop video still renders its first frame without advancing playback")
            pendingLibrary.state.preferences.paused = false; pendingEngine.updatePolicy()
            try check(!pendingEngine.isTrackingPointer && waitingPlayer.rate > 0, "running native video playback does not start a scene cursor timer")
            pendingLibrary.state.preferences.paused = true; pendingEngine.updatePolicy()
            pendingLibrary.state.displays["offline-display-fixture"] = otherSettings
            try check(pendingLibrary.save(), "persist independent display configurations before adjustment")
            var adjustment = DisplayAdjustmentDraft(displayID: screen.persistentID, configuration: pendingLibrary.state.displays[screen.persistentID] ?? DisplayConfiguration())
            adjustment.configuration.fit = .center; adjustment.configuration.scale = 1; adjustment.configuration.offsetX = 0; adjustment.configuration.offsetY = 0
            let applied = try pendingEngine.applyAdjustment(adjustment)
            try check(pendingLibrary.state.displays["offline-display-fixture"] == otherSettings && pendingLibrary.state.displays[screen.persistentID] == applied, "applying adjustments changes only the selected display")
            let restoredDisplays = try JSONDecoder().decode(SavedLibrary.self, from: Data(contentsOf: pendingLibrary.root.appendingPathComponent("library.json")))
            try check(restoredDisplays.displays[screen.persistentID] == applied && restoredDisplays.displays["offline-display-fixture"] == otherSettings, "display placement and unrelated display settings survive persistence")
            let actualSource = waitingPlayer.currentItem?.presentationSize ?? .zero
            let expectedCenter = WallpaperPlacement.frame(in: waiting.view.bounds, configuration: applied, sourcePixels: actualSource, displayPixels: screen.wallpaperPixelSize)
            try check(waiting.videoLayer?.frame == expectedCenter, "native video Center placement uses the same geometry as its preview")
            let reconnectDraft = DisplayAdjustmentDraft(displayID: screen.persistentID, configuration: applied)
            let connectedScreens = pendingEngine.screens
            pendingEngine.screens = []
            try rejects { _ = try pendingEngine.applyAdjustment(reconnectDraft) }
            try check(pendingLibrary.state.displays[screen.persistentID] == applied, "disconnecting a display cannot redirect or apply its draft")
            pendingEngine.screens = connectedScreens
            pendingEngine.configure(screen.persistentID) { $0.offsetX = 0.1 }
            try rejects { _ = try pendingEngine.applyAdjustment(reconnectDraft) }
            let videoID = pendingLibrary.state.wallpapers[0].id
            pendingLibrary.edit(videoID) { $0.propertiesJSON = "{\"temporary\":true}" }
            guard let obsolete = pendingEngine.pending[screen.persistentID] else { throw LumaError("FAILED: content edit did not stage a replacement video") }
            obsolete.window.orderOut(nil)
            pendingLibrary.edit(videoID) { $0.propertiesJSON = "{}" }
            try check(pendingEngine.pending[screen.persistentID] == nil && pendingEngine.surfaces[screen.persistentID] === waiting,
                      "reverting to the active wallpaper cancels an obsolete pending replacement for the same wallpaper ID")
            let reopenedDisplayLibrary = LibraryStore(root: pendingLibrary.root)
            try check(reopenedDisplayLibrary.state.displays == pendingLibrary.state.displays, "reopening the library restores all display adjustments")
        } else {
            print("SKIP: pending desktop playback checks require an available macOS display")
        }
        currentPhase = "video library import, persistence, and ownership rollback checks"

        // Removing a wallpaper must preserve its media when the index cannot be saved.
        let removalLibrary = LibraryStore(root: root.appendingPathComponent("removal-library"))
        try await removalLibrary.importURL(fixture)
        let removalItem = removalLibrary.state.wallpapers[0]
        let removalMedia = try removalLibrary.mediaURL(removalItem)
        let removalIndex = removalLibrary.root.appendingPathComponent("library.json")
        let savedRemovalIndex = try Data(contentsOf: removalIndex)
        try FileManager.default.removeItem(at: removalIndex)
        try FileManager.default.createDirectory(at: removalIndex, withIntermediateDirectories: false)
        removalLibrary.remove(removalItem)
        try check(removalLibrary.state.wallpapers.count == 1 && FileManager.default.fileExists(atPath: removalMedia.path), "failed removal save preserves the library record and media")
        try FileManager.default.removeItem(at: removalIndex)
        try savedRemovalIndex.write(to: removalIndex)
        try check(removalLibrary.save(), "restore the isolated removal test index")
        var unsafeLibrary = removalLibrary.state
        unsafeLibrary.wallpapers[0].folder = "../../outside"
        let unsafeIndex = try JSONEncoder().encode(unsafeLibrary)
        try unsafeIndex.write(to: removalIndex)
        let blockedLibrary = LibraryStore(root: removalLibrary.root)
        try check(blockedLibrary.error != nil && !blockedLibrary.save(), "unsafe saved ownership records block library writes")
        try check(blockedLibrary.clearDataWallpaperCount == nil, "clear review cannot claim ownership from an unsafe library")
        try rejects { try blockedLibrary.validateForClearData() }
        let preservedUnsafeIndex = try Data(contentsOf: removalIndex)
        try check(preservedUnsafeIndex == unsafeIndex && FileManager.default.fileExists(atPath: removalMedia.path), "failed Clear Data preflight preserves the unsafe index and managed media")
        try rejects { try blockedLibrary.resetForClearData() }

        let hiddenLinkProject = root.appendingPathComponent("hidden-link-project")
        try FileManager.default.createDirectory(at: hiddenLinkProject, withIntermediateDirectories: true)
        try Data("{\"type\":\"video\",\"file\":\"video.mov\"}".utf8).write(to: hiddenLinkProject.appendingPathComponent("project.json"))
        try FileManager.default.copyItem(at: fixture, to: hiddenLinkProject.appendingPathComponent("video.mov"))
        try FileManager.default.createSymbolicLink(at: hiddenLinkProject.appendingPathComponent(".hidden-link"), withDestinationURL: fixture)
        do { try await library.importURL(hiddenLinkProject); throw LumaError("FAILED: imported a hidden symlink") }
        catch let error as LumaError { guard error.message.contains("symbolic link") else { throw error }; assertions += 1 }

        let cleanupLibrary = LibraryStore(root: root.appendingPathComponent("cleanup-library"))
        var observedImport = false, blockedCleanupDuringImport = false
        cleanupLibrary.onChange = {
            observedImport = cleanupLibrary.hasImportInProgress
            do { try cleanupLibrary.validateForClearData() }
            catch { blockedCleanupDuringImport = true }
        }
        try await cleanupLibrary.importURL(fixture)
        cleanupLibrary.onChange = nil
        try check(observedImport && blockedCleanupDuringImport && !cleanupLibrary.hasImportInProgress,
                  "library tracks the complete import lifetime and blocks cleanup until the managed copy is published")

        let cancelledLibrary = LibraryStore(root: root.appendingPathComponent("cancelled-import-library"))
        let cancelledSource = root.appendingPathComponent("cancelled-import.html")
        try Data("<!doctype html><title>Cancelled source</title>".utf8).write(to: cancelledSource)
        let cancelledImport = Task { try await cancelledLibrary.importURL(cancelledSource) }
        cancelledImport.cancel()
        do { try await cancelledImport.value; throw LumaError("FAILED: cancelled import published a wallpaper") }
        catch is CancellationError { assertions += 1 }
        try check(cancelledLibrary.state.wallpapers.isEmpty && !cancelledLibrary.hasImportInProgress && FileManager.default.fileExists(atPath: cancelledSource.path),
                  "cancelled imports leave no library entry or active operation and preserve the original source")
        let unknownMedia = cleanupLibrary.root.appendingPathComponent("Media/user-file.txt")
        try Data("keep".utf8).write(to: unknownMedia)
        let ownedFolder = cleanupLibrary.folder(cleanupLibrary.state.wallpapers[0])
        let cleanupIndex = cleanupLibrary.root.appendingPathComponent("library.json")
        try cleanupLibrary.validateForClearData()
        try check(FileManager.default.fileExists(atPath: ownedFolder.path) && FileManager.default.fileExists(atPath: cleanupIndex.path), "Clear Data preflight validates without deleting data")
        let externalSentinel = root.appendingPathComponent("clear-preflight-sentinel.txt")
        try Data("outside".utf8).write(to: externalSentinel)
        let lateSymlink = ownedFolder.appendingPathComponent("late-link")
        try FileManager.default.createSymbolicLink(at: lateSymlink, withDestinationURL: externalSentinel)
        try rejects { try cleanupLibrary.validateForClearData() }
        let preservedSentinel = try String(contentsOf: externalSentinel, encoding: .utf8)
        try check(FileManager.default.fileExists(atPath: cleanupIndex.path) && FileManager.default.fileExists(atPath: ownedFolder.path) && preservedSentinel == "outside", "unsafe media symlink aborts preflight without deleting owned or external data")
        try FileManager.default.removeItem(at: lateSymlink)
        try cleanupLibrary.validateForClearData()
        try cleanupLibrary.resetForClearData()
        try check(!FileManager.default.fileExists(atPath: ownedFolder.path) && FileManager.default.fileExists(atPath: unknownMedia.path), "Clear Data removes only recorded media and preserves unknown files")
        try check(!cleanupLibrary.save() && !FileManager.default.fileExists(atPath: cleanupLibrary.root.appendingPathComponent("library.json").path), "Clear Data prevents shutdown from recreating the library")

        let externallyEditedLibrary = LibraryStore(root: root.appendingPathComponent("external-library-edit"))
        try await externallyEditedLibrary.importURL(fixture)
        let externallyOwnedFolder = externallyEditedLibrary.folder(externallyEditedLibrary.state.wallpapers[0])
        let externallyEditedIndex = externallyEditedLibrary.root.appendingPathComponent("library.json")
        let externalEdit = Data("external library update must survive".utf8)
        try externalEdit.write(to: externallyEditedIndex, options: .atomic)
        try check(!externallyEditedLibrary.save(), "an external library edit blocks a stale save")
        let preservedExternalEdit = try Data(contentsOf: externallyEditedIndex)
        try check(preservedExternalEdit == externalEdit && FileManager.default.fileExists(atPath: externallyOwnedFolder.path), "stale save preserves external library bytes and managed media")
        try rejects { try externallyEditedLibrary.validateForClearData() }
        try rejects { try externallyEditedLibrary.resetForClearData() }
        let preservedAfterBlockedClear = try Data(contentsOf: externallyEditedIndex)
        try check(preservedAfterBlockedClear == externalEdit && FileManager.default.fileExists(atPath: externallyOwnedFolder.path), "stale Clear Data preserves external library bytes and managed media")

        // Wallper Videos discovery and import use a temporary home and never touch originals.
        let wallperHome = root.resolvingSymlinksInPath().appendingPathComponent("wallper-home", isDirectory: true)
        let wallperFolder = WallperVideosDiscoveryService.folder(home: wallperHome)
        try check(wallperFolder.path == wallperHome.appendingPathComponent("Library/Application Support/Wallper/Videos", isDirectory: true).path, "expand Wallper Videos location beneath the selected home directory")
        try FileManager.default.createDirectory(at: wallperFolder, withIntermediateDirectories: true)
        let wallperSource = wallperFolder.appendingPathComponent("gentle-lake.mov")
        try FileManager.default.copyItem(at: fixture, to: wallperSource)
        try Data("not a video".utf8).write(to: wallperFolder.appendingPathComponent("notes.txt"))
        try Data("not a video".utf8).write(to: wallperFolder.appendingPathComponent("broken.mp4"))
        let outsideVideo = fixture
        try FileManager.default.createSymbolicLink(at: wallperFolder.appendingPathComponent("outside.mov"), withDestinationURL: outsideVideo)
        let externalVideoFolder = root.appendingPathComponent("ExternalWallperContent", isDirectory: true)
        try FileManager.default.createDirectory(at: externalVideoFolder, withIntermediateDirectories: true)
        let externalNestedVideo = externalVideoFolder.appendingPathComponent("escape.mov")
        try FileManager.default.copyItem(at: fixture, to: externalNestedVideo)
        try FileManager.default.createSymbolicLink(at: wallperFolder.appendingPathComponent("nested"), withDestinationURL: externalVideoFolder)
        let missing = try WallperVideosDiscoveryService.discover(at: root.appendingPathComponent("missing-wallper-folder"))
        try check(!missing.folderExists && missing.videos.isEmpty, "missing Wallper folder is reported without failure")
        let discovered = try WallperVideosDiscoveryService.discover(at: wallperFolder)
        try check(discovered.videos.map(\.filename) == ["broken.mp4", "gentle-lake.mov"], "discover supported readable video files and skip unsupported files and symlinks (found: \(discovered.videos.map(\.relativePath)), candidates: \(discovered.supportedCandidateCount), issues: \(discovered.issues))")
        try check(discovered.supportedCandidateCount == 2, "count supported video candidates")
        try rejects { _ = try WallperVideosDiscoveryService.validate(outsideVideo, under: wallperFolder) }
        try rejects { _ = try WallperVideosDiscoveryService.validate(wallperFolder.appendingPathComponent("outside.mov"), under: wallperFolder) }
        try rejects { _ = try WallperVideosDiscoveryService.validate(wallperFolder.appendingPathComponent("nested/escape.mov"), under: wallperFolder) }
        let wallperFolderLink = root.appendingPathComponent("WallperVideosLink")
        try FileManager.default.createSymbolicLink(at: wallperFolderLink, withDestinationURL: wallperFolder)
        try rejects { _ = try WallperVideosDiscoveryService.discover(at: wallperFolderLink) }

        let fakeSteamRoot = root.appendingPathComponent("SteamRoot", isDirectory: true)
        let existingLibrary = root.appendingPathComponent("ExistingSteamLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeSteamRoot.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: existingLibrary.appendingPathComponent("steamapps/workshop/content"), withIntermediateDirectories: true)
        let libraryVDF = "\"libraryfolders\" { \"0\" { \"path\" \"\(existingLibrary.path)\" } }"
        try Data(libraryVDF.utf8).write(to: fakeSteamRoot.appendingPathComponent("steamapps/libraryfolders.vdf"))
        let existingSteamDownload = existingLibrary.appendingPathComponent("steamapps/workshop/content/431960/123")
        try FileManager.default.createDirectory(at: existingSteamDownload, withIntermediateDirectories: true)
        try check(SteamCMD.temporaryDownloadRetentionReason(at: existingSteamDownload, steamRoot: fakeSteamRoot) != nil,
                  "Steam cleanup protects Workshop folders in every parsed Steam library")
        let unrelatedSteamCMDDownload = root.appendingPathComponent("SteamCMD/steamapps/workshop/content/431960/456")
        try FileManager.default.createDirectory(at: unrelatedSteamCMDDownload, withIntermediateDirectories: true)
        try check(SteamCMD.temporaryDownloadRetentionReason(at: unrelatedSteamCMDDownload, steamRoot: fakeSteamRoot) == nil,
                  "Steam cleanup permits temporary folders outside verified Steam libraries")
        try Data("unreadable library list".utf8).write(to: fakeSteamRoot.appendingPathComponent("steamapps/libraryfolders.vdf"), options: .atomic)
        try check(SteamCMD.temporaryDownloadRetentionReason(at: unrelatedSteamCMDDownload, steamRoot: fakeSteamRoot) != nil,
                  "Steam cleanup preserves downloads whenever existing library locations cannot be verified")

        let wallperCatalog = WallperVideosCatalog(home: wallperHome)
        await wallperCatalog.refresh()
        try check(wallperCatalog.isAvailable && wallperCatalog.videos.count == 2, "catalog exposes supported Wallper videos")
        let wallperLibrary = LibraryStore(root: root.appendingPathComponent("wallper-library"))
        await wallperCatalog.importSelected(Set(wallperCatalog.videos.map(\.id)), library: wallperLibrary)
        try check(wallperCatalog.importResults.filter { $0.status == .imported }.count == 1, "import valid Wallper video")
        try check(wallperCatalog.importResults.filter { $0.status == .failed }.count == 1, "report an invalid video without aborting other imports")
        try check(FileManager.default.fileExists(atPath: wallperSource.path), "Wallper source remains in place after import")
        try check(wallperLibrary.state.wallpapers.count == 1 && wallperLibrary.state.wallpapers[0].duration ?? 0 > 0, "Wallper import creates Luma-managed playback metadata")
        let lumaCopy = try wallperLibrary.mediaURL(wallperLibrary.state.wallpapers[0])
        try check(lumaCopy.path != wallperSource.path && FileManager.default.fileExists(atPath: lumaCopy.path), "Wallper import creates a managed copy")
        let duplicateResult = try await wallperLibrary.importWallperVideo(wallperSource, from: wallperFolder)
        if case .duplicate = duplicateResult { assertions += 1 } else { throw LumaError("FAILED: repeated Wallper import was not detected as a duplicate") }
        try check(wallperLibrary.state.wallpapers.count == 1, "duplicate Wallper import does not add another library item")
        let legacyWallperLibrary = LibraryStore(root: root.appendingPathComponent("wallper-legacy-library"))
        try await legacyWallperLibrary.importURL(wallperSource)
        let legacyDuplicate = try await legacyWallperLibrary.importWallperVideo(wallperSource, from: wallperFolder)
        if case .duplicate = legacyDuplicate { assertions += 1 } else { throw LumaError("FAILED: legacy same-name import was not recognized") }
        try check(legacyWallperLibrary.state.wallpapers.count == 1, "Wallper import recognizes a matching pre-fingerprint Luma import")
        print("PASS: Wallper discovery, symlink validation, per-file import errors, managed copies, and duplicate handling")

        let editorProjects = EditorProjectStore(library: library)
        var project = try editorProjects.create(title: "Editor Fixture")
        let packageURL = editorProjects.folder(for: project).appendingPathComponent(project.entry)
        var originalPackage = try SceneProjectPackage(data: Data(contentsOf: packageURL))
        let unknownBytes = Data([0, 17, 42, 255])
        originalPackage.entries.append(.init(name: "vendor/unknown.bin", bytes: unknownBytes))
        try originalPackage.encoded().write(to: packageURL, options: .atomic)
        let editorDocument = try SceneProjectDocument(folder: editorProjects.folder(for: project))
        try editorDocument.addTextLayer()
        try editorDocument.renameLayer(at: 0, to: "Clock Text")
        try editorDocument.transformLayers(indices: [0], dx: 32, dy: -16, snapToGrid: false)
        try editorDocument.save()
        let savedPackage = try SceneProjectPackage(data: Data(contentsOf: packageURL))
        try check(savedPackage.entries.first(where: { $0.name == "vendor/unknown.bin" })?.bytes == unknownBytes, "scene saves preserve unknown package entries")
        let savedLayer = try SceneProjectDocument(folder: editorProjects.folder(for: project)).objects[0]
        try check(savedLayer["name"] as? String == "Clock Text", "layer rename persists")
        try check((savedLayer["origin"] as? String)?.contains("992") == true, "layer transform persists as scene coordinates")
        try editorDocument.undo()
        try check((editorDocument.objects[0]["origin"] as? String)?.contains("960") == true, "undo restores transform")
        try editorDocument.redo()
        try check((editorDocument.objects[0]["origin"] as? String)?.contains("992") == true, "redo reapplies transform")
        project = try editorProjects.duplicate(project.id)
        try check(project.title == "Editor Fixture Copy" && !project.scriptsApproved && !project.scriptsEnabled, "duplicate clears script approval")
        try editorProjects.rename(project.id, to: "Renamed Fixture")
        let exportParent = root.appendingPathComponent("EditorExports")
        try FileManager.default.createDirectory(at: exportParent, withIntermediateDirectories: true)
        let exported = try editorProjects.export(project.id, to: exportParent)
        try check(FileManager.default.fileExists(atPath: exported.appendingPathComponent("project.json").path), "project export copies a valid project folder")
        let reopenedLibrary = LibraryStore(root: library.root)
        let restoredEditorProjects = EditorProjectStore(library: reopenedLibrary)
        try check(restoredEditorProjects.projects.count == 2 && restoredEditorProjects.recentProjectIDs.first == project.id, "editor project browser restores projects and recents")
        try rejects { _ = try SceneProjectPackage(data: package("../escape.json", bytes: Data([1]))) }
        let unsafeProject = root.appendingPathComponent("unsafe-editor-project")
        try FileManager.default.createDirectory(at: unsafeProject, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: unsafeProject.appendingPathComponent("outside"), withDestinationURL: root)
        try rejects { _ = try editorProjects.importProject(unsafeProject) }
        let malicious = root.appendingPathComponent("malicious")
        try FileManager.default.createDirectory(at:malicious,withIntermediateDirectories:true)
        try Data("{\"type\":\"video\",\"file\":\"../fixture.mov\"}".utf8).write(to:malicious.appendingPathComponent("project.json"))
        do {try await reopenedLibrary.importURL(malicious);throw LumaError("FAILED unsafe import")} catch let error as LumaError {guard error.message.contains("unsafe path") else {throw error};assertions += 1}
        try check(reopenedLibrary.state.wallpapers.count == 1,"failed import does not publish item")
        let item = reopenedLibrary.state.wallpapers[0];reopenedLibrary.remove(item)
        try check(reopenedLibrary.state.wallpapers.isEmpty,"remove imported copy")
        try check(FileManager.default.fileExists(atPath:fixture.path),"original source preserved")
        print("PASS: import, persistence, rollback, and source-preservation checks")
        currentPhase = "temporal HEVC conversion and temporal sample-group validation"
        let encoded = root.appendingPathComponent("temporal.mov")
        try await TemporalEncoder.encode(source:fixture,output:encoded,progress:{_ in})
        let file = try Data(contentsOf:encoded)
        try check(file.range(of:Data("tscl".utf8)) != nil,"temporal layer metadata")
        try check(file.range(of:Data("tsas".utf8)) != nil,"temporal access metadata")
        let encodedAsset = AVURLAsset(url:encoded)
        let tracks = try await encodedAsset.loadTracks(withMediaType:.video)
        try check(tracks.count == 1,"temporal movie has one video track")
        try check(MovieMetadata.temporalGroups(in: file).isSuperset(of: ["tscl", "tsas"]), "parse real sample grouping records")
        try check(MovieMetadata.temporalGroups(in: Data("tscl tsas".utf8)).isEmpty, "reject temporal strings outside MOV boxes")
        print("PASS: HEVC Main10 conversion and temporal sample groups")
        currentPhase = "SteamCMD discovery and installation migration checks"
        let steamFolder = root.appendingPathComponent("Steam")
        try FileManager.default.createDirectory(at: steamFolder, withIntermediateDirectories: true)
        let script = steamFolder.appendingPathComponent("steamcmd.sh")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: script.path)
        try check(SteamCMD.executable(in: steamFolder) == script, "readable SteamCMD script need not have executable bit")
        try check(SteamCMD.executable(in: root) == script, "detect nested SteamCMD install")
        try check(SteamCMD.executable(in: root.appendingPathComponent("missing")) == nil, "missing SteamCMD directory")
        let fakeDirectory = root.appendingPathComponent("fake-steam")
        try FileManager.default.createDirectory(at: fakeDirectory.appendingPathComponent("steamcmd.sh"), withIntermediateDirectories: true)
        try check(SteamCMD.executable(in: fakeDirectory) == nil, "directory named steamcmd.sh is not a script")
        let executable = steamFolder.appendingPathComponent("steamcmd")
        try Data("test binary".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try check(SteamCMD.executable(in: steamFolder) == executable, "prefer native SteamCMD to the launcher script")
        let environment = SteamCMD.environment(for: executable, inherited: ["DYLD_LIBRARY_PATH": "/custom/lib", "KEEP": "yes"])
        try check(environment["DYLD_LIBRARY_PATH"] == steamFolder.path + ":/custom/lib", "preserve and prepend SteamCMD library paths")
        try check(environment["DYLD_FRAMEWORK_PATH"] == steamFolder.path, "SteamCMD framework directory")
        try check(environment["KEEP"] == "yes", "preserve unrelated environment variables")
        let migrationHome = root.appendingPathComponent("migration-home")
        let currentRoot = migrationHome.appendingPathComponent("Library/Application Support/Luma")
        let previousRoot = migrationHome.appendingPathComponent("Library/Containers/dev.patrick.Luma/Data/Library/Application Support/Luma")
        try FileManager.default.createDirectory(at: previousRoot, withIntermediateDirectories: true)
        try Data("sentinel".utf8).write(to: previousRoot.appendingPathComponent("library.json"))
        try check(LibraryStore.preferredRoot(defaultRoot: currentRoot, home: migrationHome).path == previousRoot.path, "reuse sandboxed library after switching build profiles")
        try FileManager.default.createDirectory(at: currentRoot, withIntermediateDirectories: true)
        try Data("newer".utf8).write(to: currentRoot.appendingPathComponent("library.json"))
        try check(LibraryStore.preferredRoot(defaultRoot: currentRoot, home: migrationHome).path == currentRoot.path, "existing normal library takes precedence")
        func package(_ name: String, bytes: Data, offset: Int = 0) -> Data {
            var data = Data()
            func number(_ value: Int) { var n = UInt32(value).littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
            number(8); data.append(Data("PKGV0012".utf8)); number(1)
            number(name.utf8.count); data.append(Data(name.utf8)); number(offset); number(bytes.count); data.append(bytes)
            return data
        }
        currentPhase = "packed scene media discovery and path validation"
        let packed = package("materials/background.png", bytes: Data([1,2,3]))
        let media = try SceneMediaDiscovery.archiveCandidates(packed)
        try check(media.count == 1, "discover packed scene image")
        let packedBytes = try media[0].bytes()
        try check(packedBytes == Data([1,2,3]), "read exact packed scene media range")
        try rejects { _ = try SceneMediaDiscovery.archiveCandidates(package("../escape.png", bytes: Data([1]))) }
        try rejects { _ = try SceneMediaDiscovery.archiveCandidates(package("video.mp4", bytes: Data([1]), offset: 50)) }
        try rejects { _ = try SceneMediaDiscovery.archiveCandidates(Data([0,0,0])) }
        currentPhase = "native static scene fallback encoding, catalog installation, and removal"
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fixture))
        let image = try await generator.image(at: .zero).image
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        let sceneID = UUID()
        let sceneFolder = library.root.appendingPathComponent("Media/\(sceneID.uuidString)")
        try FileManager.default.createDirectory(at: sceneFolder, withIntermediateDirectories: true)
        try png.write(to: sceneFolder.appendingPathComponent("background.png"))
        try png.write(to: sceneFolder.appendingPathComponent("preview.png"))
        let fallbackChoices = try SceneMediaDiscovery.candidates(folder: sceneFolder, entry: "scene.pkg", preview: "preview.png")
        try check(fallbackChoices.first?.name == "background.png", "prefer background image to preview")
        let nativeRoot = root.appendingPathComponent("com.apple.wallpaper")
        let manifest = nativeRoot.appendingPathComponent("aerials/manifest/entries.json")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["assets": [], "categories": [], "preserve": "sentinel"]).write(to: manifest)
        let fallback = NativeLockScreen(library: library, wallpaperRoot: nativeRoot, opensSettings: false)
        fallback.sceneMode = .sourceMedia
        let sceneWallpaper = Wallpaper(id: sceneID, title: "Broken scene with image", kind: .scene, folder: sceneID.uuidString, entry: "missing.pkg")
        fallback.install(sceneWallpaper, assets: nil)
        let deadline = Date().addingTimeInterval(30)
        while fallback.busy { guard Date() < deadline else { throw LumaError("Fallback integration check timed out") }; try await Task.sleep(for: .milliseconds(100)) }
        try check(fallback.receipt?.sourceDescription == "Scene image: background.png", "install source image when scene cannot render")
        guard let receipt = fallback.receipt else { throw LumaError(fallback.status) }
        let installed = try Data(contentsOf: URL(fileURLWithPath: receipt.videoPath))
        try check(MovieMetadata.temporalGroups(in: installed).isSuperset(of: ["tscl", "tsas"]), "still fallback has native temporal metadata")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        try check(catalog["preserve"] as? String == "sentinel", "fallback installer preserves catalog metadata")
        fallback.removeInstalled()
        try check(fallback.receipt == nil && !FileManager.default.fileExists(atPath: library.root.appendingPathComponent("native-receipt.json").path), "normal native uninstall removes the persisted receipt")
        let afterRemoval = NativeLockScreen(library: library, wallpaperRoot: nativeRoot, opensSettings: false)
        try check(!afterRemoval.hasManagedChanges && !FileManager.default.fileExists(atPath: receipt.videoPath), "native removal stays removed after service restart")

        func recordedNativeFixture(_ name: String, manifestExisted: Bool = false, createdDirectories: [String]) throws -> (service: NativeLockScreen, library: LibraryStore, wallpaperRoot: URL, manifest: URL, video: URL, receipt: URL, installedData: Data) {
            let fixtureLibrary = LibraryStore(root: root.appendingPathComponent("\(name)-library"))
            let fixtureRoot = root.appendingPathComponent("\(name)-wallpaper", isDirectory: true)
            let id = UUID().uuidString
            let fixtureManifest = fixtureRoot.appendingPathComponent("aerials/manifest/entries.json")
            let fixtureVideo = fixtureRoot.appendingPathComponent("aerials/videos/\(id).mov")
            let fixtureThumbnail = fixtureRoot.appendingPathComponent("aerials/thumbnails/\(id).png")
            try FileManager.default.createDirectory(at: fixtureVideo.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: fixtureThumbnail.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: fixtureManifest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let baseline: [String: Any] = ["assets": [], "categories": [], "fixture": name]
            let baselineData = try JSONSerialization.data(withJSONObject: baseline, options: [.sortedKeys])
            let installed = try NativeCatalog.adding(assetID: id, title: name, video: fixtureVideo, thumbnail: fixtureThumbnail, to: baseline)
            let installedData = try JSONSerialization.data(withJSONObject: installed, options: [.sortedKeys])
            try installedData.write(to: fixtureManifest)
            try Data("fixture video".utf8).write(to: fixtureVideo)
            try Data("fixture thumbnail".utf8).write(to: fixtureThumbnail)
            let backup = fixtureLibrary.root.appendingPathComponent("NativeBackups/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try baselineData.write(to: backup.appendingPathComponent("entries.json"))
            let state = NativeInstallState(manifestExisted: manifestExisted,
                                           installedManifestSHA256: NativeCatalog.sha256(installedData),
                                           createdDirectories: createdDirectories)
            try JSONEncoder().encode(state).write(to: backup.appendingPathComponent("install-state.json"))
            let fixtureReceiptURL = fixtureLibrary.root.appendingPathComponent("native-receipt.json")
            let fixtureReceipt = NativeReceipt(assetID: id, title: name, videoPath: fixtureVideo.path, thumbnailPath: fixtureThumbnail.path)
            try JSONEncoder().encode(fixtureReceipt).write(to: fixtureReceiptURL)
            return (NativeLockScreen(library: fixtureLibrary, wallpaperRoot: fixtureRoot, opensSettings: false), fixtureLibrary, fixtureRoot, fixtureManifest, fixtureVideo, fixtureReceiptURL, installedData)
        }
        func appendRecordedNativeInstall(library: LibraryStore, wallpaperRoot: URL, manifest: URL) throws -> URL {
            let original = try Data(contentsOf: manifest)
            let catalog = try JSONSerialization.jsonObject(with: original) as! [String: Any]
            let id = UUID().uuidString
            let video = wallpaperRoot.appendingPathComponent("aerials/videos/\(id).mov")
            let thumbnail = wallpaperRoot.appendingPathComponent("aerials/thumbnails/\(id).png")
            let updated = try NativeCatalog.adding(assetID: id, title: "Second install", video: video, thumbnail: thumbnail, to: catalog)
            let bytes = try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys])
            let backup = library.root.appendingPathComponent("NativeBackups/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try original.write(to: backup.appendingPathComponent("entries.json"))
            let state = NativeInstallState(manifestExisted: true, installedManifestSHA256: NativeCatalog.sha256(bytes), createdDirectories: [])
            try JSONEncoder().encode(state).write(to: backup.appendingPathComponent("install-state.json"))
            try Data("second video".utf8).write(to: video)
            try Data("second thumbnail".utf8).write(to: thumbnail)
            try bytes.write(to: manifest, options: .atomic)
            let receipt = NativeReceipt(assetID: id, title: "Second install", videoPath: video.path, thumbnailPath: thumbnail.path)
            try JSONEncoder().encode(receipt).write(to: library.root.appendingPathComponent("native-receipt.json"), options: .atomic)
            return video
        }

        let absentBeforeInstall = try recordedNativeFixture("catalog-created-by-luma", createdDirectories: ["aerials/manifest", "aerials/thumbnails", "aerials/videos", "aerials"])
        try absentBeforeInstall.service.restoreManagedChangesForClearData()
        try check(!FileManager.default.fileExists(atPath: absentBeforeInstall.manifest.path), "native cleanup restores a catalog manifest that was absent before Luma installed")
        try check(!FileManager.default.fileExists(atPath: absentBeforeInstall.wallpaperRoot.appendingPathComponent("aerials").path), "native cleanup removes only its now-empty directories created by Luma")
        try check(!FileManager.default.fileExists(atPath: absentBeforeInstall.video.path) && !FileManager.default.fileExists(atPath: absentBeforeInstall.receipt.path), "native cleanup removes generated media and receipt when restoring an originally absent catalog")

        currentPhase = "native cleanup after repeated installs and intervening external catalog edits"
        let repeatedInstall = try recordedNativeFixture("catalog-repeated-install", createdDirectories: ["aerials/manifest", "aerials/thumbnails", "aerials/videos", "aerials"])
        let secondVideo = try appendRecordedNativeInstall(library: repeatedInstall.library, wallpaperRoot: repeatedInstall.wallpaperRoot, manifest: repeatedInstall.manifest)
        let repeatedService = NativeLockScreen(library: repeatedInstall.library, wallpaperRoot: repeatedInstall.wallpaperRoot, opensSettings: false)
        try repeatedService.restoreManagedChangesForClearData()
        try check(!FileManager.default.fileExists(atPath: repeatedInstall.manifest.path) && !FileManager.default.fileExists(atPath: repeatedInstall.video.path) && !FileManager.default.fileExists(atPath: secondVideo.path),
                  "native cleanup follows consecutive Luma installs back to the originally absent manifest and removes both installs")

        let interveningEdit = try recordedNativeFixture("catalog-intervening-edit", createdDirectories: [])
        var interveningObject = try JSONSerialization.jsonObject(with: interveningEdit.installedData) as! [String: Any]
        interveningObject["externalMetadata"] = "written between Luma installs"
        try JSONSerialization.data(withJSONObject: interveningObject, options: [.sortedKeys]).write(to: interveningEdit.manifest, options: .atomic)
        let interveningSecondVideo = try appendRecordedNativeInstall(library: interveningEdit.library, wallpaperRoot: interveningEdit.wallpaperRoot, manifest: interveningEdit.manifest)
        let interveningService = NativeLockScreen(library: interveningEdit.library, wallpaperRoot: interveningEdit.wallpaperRoot, opensSettings: false)
        try interveningService.restoreManagedChangesForClearData()
        let interveningResult = try JSONSerialization.jsonObject(with: Data(contentsOf: interveningEdit.manifest)) as! [String: Any]
        try check(interveningResult["externalMetadata"] as? String == "written between Luma installs" && (interveningResult["assets"] as? [[String: Any]])?.isEmpty == true,
                  "native cleanup preserves catalog changes made by another writer between Luma installs")
        try check(!FileManager.default.fileExists(atPath: interveningEdit.video.path) && !FileManager.default.fileExists(atPath: interveningSecondVideo.path),
                  "native cleanup removes both generated media sets while preserving intervening catalog changes")

        let externallyChangedCatalog = try recordedNativeFixture("catalog-with-external-edits", createdDirectories: [])
        var editedObject = try JSONSerialization.jsonObject(with: externallyChangedCatalog.installedData) as! [String: Any]
        editedObject["externalMetadata"] = "preserve me"
        let externalCatalogBytes = try JSONSerialization.data(withJSONObject: editedObject, options: [.sortedKeys])
        try externalCatalogBytes.write(to: externallyChangedCatalog.manifest, options: .atomic)
        try externallyChangedCatalog.service.restoreManagedChangesForClearData()
        let preservedCatalog = try JSONSerialization.jsonObject(with: Data(contentsOf: externallyChangedCatalog.manifest)) as! [String: Any]
        try check(preservedCatalog["externalMetadata"] as? String == "preserve me" && (preservedCatalog["assets"] as? [[String: Any]])?.isEmpty == true,
                  "native cleanup removes Luma records but preserves a catalog modified by another writer")

        let externallyRemovedCatalog = try recordedNativeFixture("catalog-removed-externally", createdDirectories: ["aerials/manifest", "aerials/thumbnails", "aerials/videos", "aerials"])
        try FileManager.default.removeItem(at: externallyRemovedCatalog.manifest)
        try externallyRemovedCatalog.service.restoreManagedChangesForClearData()
        try check(!FileManager.default.fileExists(atPath: externallyRemovedCatalog.video.path) && !FileManager.default.fileExists(atPath: externallyRemovedCatalog.receipt.path),
                  "native cleanup remains retryable if the system catalog was removed externally")

        let untouchedCatalogRoot = root.appendingPathComponent("untouched-catalog-wallpaper", isDirectory: true)
        let untouchedManifest = untouchedCatalogRoot.appendingPathComponent("aerials/manifest/entries.json")
        try FileManager.default.createDirectory(at: untouchedManifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let untouchedData = try JSONSerialization.data(withJSONObject: ["assets": [], "categories": [], "otherApp": "keep"], options: [.sortedKeys])
        try untouchedData.write(to: untouchedManifest)
        let untouchedLibrary = LibraryStore(root: root.appendingPathComponent("untouched-catalog-library"))
        let untouchedBackups = untouchedLibrary.root.appendingPathComponent("NativeBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: untouchedBackups, withIntermediateDirectories: true)
        let untouchedSelectionData = try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
        try untouchedSelectionData.write(to: untouchedBackups.appendingPathComponent("selection-original.plist"))
        let untouchedService = NativeLockScreen(library: untouchedLibrary, wallpaperRoot: untouchedCatalogRoot, opensSettings: false)
        try untouchedService.restoreManagedChangesForClearData()
        let preservedUntouchedBytes = try Data(contentsOf: untouchedManifest)
        try check(preservedUntouchedBytes == untouchedData, "native cleanup does not rewrite a catalog when it contains no Luma records")

        let selectionNativeLibrary = LibraryStore(root: root.appendingPathComponent("selection-native-library"))
        let selectionNativeRoot = root.appendingPathComponent("selection-native-wallpaper-root", isDirectory: true)
        let selectionAssetID = UUID().uuidString
        let selectionVideo = selectionNativeRoot.appendingPathComponent("aerials/videos/\(selectionAssetID).mov")
        let selectionThumbnail = selectionNativeRoot.appendingPathComponent("aerials/thumbnails/\(selectionAssetID).png")
        let selectionManifest = selectionNativeRoot.appendingPathComponent("aerials/manifest/entries.json")
        try FileManager.default.createDirectory(at: selectionVideo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: selectionThumbnail.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: selectionManifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("selection video".utf8).write(to: selectionVideo)
        try Data("selection thumb".utf8).write(to: selectionThumbnail)
        let selectionNativeBase: [String: Any] = ["assets": [], "categories": [], "preserve": "selection-test"]
        let selectionCatalog = try NativeCatalog.adding(assetID: selectionAssetID, title: "Selection fixture", video: selectionVideo, thumbnail: selectionThumbnail, to: selectionNativeBase)
        try JSONSerialization.data(withJSONObject: selectionCatalog, options: [.sortedKeys]).write(to: selectionManifest)
        let originalSelectionData = try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
        let installedSelection = try NativeSelection.selecting(assetID: selectionAssetID, in: store)
        let installedSelectionData = try PropertyListSerialization.data(fromPropertyList: installedSelection, format: .binary, options: 0)
        let liveSelectionURL = selectionNativeRoot.appendingPathComponent("Store/Index.plist")
        try FileManager.default.createDirectory(at: liveSelectionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try installedSelectionData.write(to: liveSelectionURL)
        let selectionBackupRoot = selectionNativeLibrary.root.appendingPathComponent("NativeBackups", isDirectory: true)
        let selectionAssetBackup = selectionBackupRoot.appendingPathComponent(selectionAssetID, isDirectory: true)
        try FileManager.default.createDirectory(at: selectionAssetBackup, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: selectionNativeBase, options: [.sortedKeys]).write(to: selectionAssetBackup.appendingPathComponent("entries.json"))
        try originalSelectionData.write(to: selectionBackupRoot.appendingPathComponent("selection-original.plist"))
        try installedSelectionData.write(to: selectionBackupRoot.appendingPathComponent("selection-installed.plist"))
        let selectionReceipt = NativeReceipt(assetID: selectionAssetID, title: "Selection fixture", videoPath: selectionVideo.path, thumbnailPath: selectionThumbnail.path)
        let selectionReceiptURL = selectionNativeLibrary.root.appendingPathComponent("native-receipt.json")
        try JSONEncoder().encode(selectionReceipt).write(to: selectionReceiptURL)
        let selectionNative = NativeLockScreen(library: selectionNativeLibrary, wallpaperRoot: selectionNativeRoot, opensSettings: false)
        try selectionNative.restoreManagedChangesForClearData()
        let restoredSelection = try Data(contentsOf: selectionNativeRoot.appendingPathComponent("Store/Index.plist"))
        let restoredCatalog = try JSONSerialization.jsonObject(with: Data(contentsOf: selectionManifest)) as! [String: Any]
        try check(restoredSelection == originalSelectionData, "native cleanup restores the previous wallpaper selection when the current value still matches Luma")
        try check((restoredCatalog["preserve"] as? String) == "selection-test" && (restoredCatalog["assets"] as? [[String: Any]])?.isEmpty == true,
                  "native cleanup removes only Luma catalog entries and preserves unrelated catalog fields")
        try check(!FileManager.default.fileExists(atPath: selectionVideo.path) && !FileManager.default.fileExists(atPath: selectionReceiptURL.path),
                  "native cleanup removes recorded generated files and receipt after restoration")

        let corruptNativeLibrary = LibraryStore(root: root.appendingPathComponent("corrupt-native-library"))
        let corruptReceiptURL = corruptNativeLibrary.root.appendingPathComponent("native-receipt.json")
        let corruptReceiptBytes = Data("{malformed receipt".utf8)
        try corruptReceiptBytes.write(to: corruptReceiptURL)
        let corruptNative = NativeLockScreen(library: corruptNativeLibrary, wallpaperRoot: root.appendingPathComponent("corrupt-wallpaper-root"), opensSettings: false)
        try check(corruptNative.hasManagedChanges && corruptNative.clearDataPreflightError != nil, "malformed native receipt blocks Clear Data and remains visible as managed state")
        try rejects { try corruptNative.validateForClearData() }
        try rejects { try corruptNative.restoreManagedChangesForClearData() }
        let preservedCorruptReceipt = try Data(contentsOf: corruptReceiptURL)
        try check(preservedCorruptReceipt == corruptReceiptBytes, "failed native cleanup preserves a malformed receipt for recovery")

        let externalNativeLibrary = LibraryStore(root: root.appendingPathComponent("external-native-library"))
        let externalWallpaperRoot = root.appendingPathComponent("external-wallpaper-root", isDirectory: true)
        let nativeAssetID = UUID().uuidString
        let nativeVideo = externalWallpaperRoot.appendingPathComponent("aerials/videos/\(nativeAssetID).mov")
        let nativeThumbnail = externalWallpaperRoot.appendingPathComponent("aerials/thumbnails/\(nativeAssetID).png")
        let nativeManifest = externalWallpaperRoot.appendingPathComponent("aerials/manifest/entries.json")
        try FileManager.default.createDirectory(at: nativeVideo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nativeThumbnail.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nativeManifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("video".utf8).write(to: nativeVideo)
        try Data("thumbnail".utf8).write(to: nativeThumbnail)
        let nativeCatalog = try NativeCatalog.adding(assetID: nativeAssetID, title: "Fixture", video: nativeVideo, thumbnail: nativeThumbnail,
                                                     to: ["assets": [], "categories": []])
        let originalNativeManifest = try JSONSerialization.data(withJSONObject: nativeCatalog, options: [.sortedKeys])
        try originalNativeManifest.write(to: nativeManifest)
        let nativeBackupDirectory = externalNativeLibrary.root.appendingPathComponent("NativeBackups/\(nativeAssetID)", isDirectory: true)
        try FileManager.default.createDirectory(at: nativeBackupDirectory, withIntermediateDirectories: true)
        try Data("{\"assets\":[],\"categories\":[]}".utf8).write(to: nativeBackupDirectory.appendingPathComponent("entries.json"))
        let nativeReceiptURL = externalNativeLibrary.root.appendingPathComponent("native-receipt.json")
        let nativeReceipt = NativeReceipt(assetID: nativeAssetID, title: "Fixture", videoPath: nativeVideo.path, thumbnailPath: nativeThumbnail.path, sourceDescription: "fixture")
        try JSONEncoder().encode(nativeReceipt).write(to: nativeReceiptURL)
        let externalNative = NativeLockScreen(library: externalNativeLibrary, wallpaperRoot: externalWallpaperRoot, opensSettings: false)
        try externalNative.validateForClearData()
        var changedNativeReceipt = nativeReceipt
        changedNativeReceipt.title = "Edited outside Luma"
        let changedNativeReceiptData = try JSONEncoder().encode(changedNativeReceipt)
        try changedNativeReceiptData.write(to: nativeReceiptURL, options: .atomic)
        try check(externalNative.clearDataPreflightError != nil, "an externally edited native receipt blocks the Clear Data review")
        try rejects { try externalNative.restoreManagedChangesForClearData() }
        let preservedNativeManifest = try Data(contentsOf: nativeManifest)
        let preservedNativeVideo = FileManager.default.fileExists(atPath: nativeVideo.path)
        let preservedNativeReceiptData = try Data(contentsOf: nativeReceiptURL)
        try check(preservedNativeManifest == originalNativeManifest && preservedNativeVideo && preservedNativeReceiptData == changedNativeReceiptData,
                  "external receipt edits stop catalog restoration and preserve the receipt and generated files")

        let editedBackupLibrary = LibraryStore(root: root.appendingPathComponent("edited-native-backup-library"))
        let editedBackupRoot = root.appendingPathComponent("edited-native-backup-wallpaper-root", isDirectory: true)
        let editedBackupManifest = editedBackupRoot.appendingPathComponent("aerials/manifest/entries.json")
        try FileManager.default.createDirectory(at: editedBackupManifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let emptyNativeManifest = try JSONSerialization.data(withJSONObject: ["assets": [], "categories": []], options: [.sortedKeys])
        try emptyNativeManifest.write(to: editedBackupManifest)
        let editedBackups = editedBackupLibrary.root.appendingPathComponent("NativeBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: editedBackups, withIntermediateDirectories: true)
        let selectionOriginalBackup = editedBackups.appendingPathComponent("selection-original.plist")
        let initialSelectionBackup = try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
        try initialSelectionBackup.write(to: selectionOriginalBackup)
        let editedBackupService = NativeLockScreen(library: editedBackupLibrary, wallpaperRoot: editedBackupRoot, opensSettings: false)
        try editedBackupService.validateForClearData()
        let externalSelectionBackup = try PropertyListSerialization.data(fromPropertyList: ["external": "changed"], format: .binary, options: 0)
        try externalSelectionBackup.write(to: selectionOriginalBackup, options: .atomic)
        try check(editedBackupService.clearDataPreflightError != nil, "externally edited native selection backup blocks Clear Data")
        try rejects { try editedBackupService.restoreManagedChangesForClearData() }
        let stillEditedBackup = try Data(contentsOf: selectionOriginalBackup)
        let preservedEditedManifest = try Data(contentsOf: editedBackupManifest)
        try check(stillEditedBackup == externalSelectionBackup && preservedEditedManifest == emptyNativeManifest,
                  "external native backup edits remain intact and stop system catalog changes")
        guard let oversizedBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8193, pixelsHigh: 1,
                                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let oversizedPNG = oversizedBitmap.representation(using: .png, properties: [:]) else {
            throw LumaError("Could not create the oversized-image fallback fixture.")
        }
        try rejects { _ = try SceneStaticFallback.normalizedImage(oversizedPNG) }
        print("PASS: SteamCMD detection, packed media safety, source-image fallback, and native still installation in a temporary catalog")
        print("ALL PASSED (\(assertions) assertions). No system wallpaper files were changed.")
    }
    static func makeVideo(_ url:URL) async throws {
        if #available(macOS 27.0, *) {
            try await makeVideoUsingReceiver(url)
            return
        }
        let writer=try AVAssetWriter(outputURL:url,fileType:.mov)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:128,AVVideoHeightKey:72])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:128,kCVPixelBufferHeightKey as String:72])
        guard writer.canAdd(input) else { throw LumaError("The H.264 fixture writer cannot accept a video input.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? LumaError("Could not start the H.264 fixture writer.") }
        writer.startSession(atSourceTime:.zero)
        guard let pool=adaptor.pixelBufferPool else { throw LumaError("The H.264 fixture writer did not create a pixel-buffer pool.") }
        defer { if writer.status != .completed { writer.cancelWriting() } }
        for n in 0..<60 {
            let deadline=Date().addingTimeInterval(15)
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing, Date() < deadline else { throw writer.error ?? LumaError("The H.264 fixture writer stalled before frame \(n).") }
                try await Task.sleep(for:.milliseconds(3))
            }
            var pixel:CVPixelBuffer?
            let allocation=CVPixelBufferPoolCreatePixelBuffer(nil,pool,&pixel)
            guard allocation == kCVReturnSuccess, let pixel else { throw LumaError("Could not allocate H.264 fixture frame \(n) (Core Video \(allocation)).") }
            let lock=CVPixelBufferLockBaseAddress(pixel,[])
            guard lock == kCVReturnSuccess else { throw LumaError("Could not lock H.264 fixture frame \(n) (Core Video \(lock)).") }
            defer { CVPixelBufferUnlockBaseAddress(pixel,[]) }
            guard let base=CVPixelBufferGetBaseAddress(pixel) else { throw LumaError("H.264 fixture frame \(n) has no pixel storage.") }
            memset(base,Int32(30+n*2),CVPixelBufferGetDataSize(pixel))
            guard adaptor.append(pixel,withPresentationTime:CMTime(value:Int64(n),timescale:30)) else { throw writer.error ?? LumaError("Could not append H.264 fixture frame \(n).") }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? LumaError("The H.264 fixture movie did not finish.") }
    }
    @available(macOS 27.0, *)
    static func makeVideoUsingReceiver(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 72])
        let attributes = CVPixelBufferCreationAttributes(pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA), size: CVImageSize(width: 128, height: 72))
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 128,
            kCVPixelBufferHeightKey as String: 72,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, poolAttributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            throw LumaError("The H.264 fixture writer did not create a pixel-buffer pool.")
        }
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            try Task.checkCancellation()
            var pixel: CVPixelBuffer?
            let allocation = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel)
            guard allocation == kCVReturnSuccess, let pixel else { throw LumaError("Could not allocate H.264 fixture frame \(frame) (Core Video \(allocation)).") }
            let lockResult = CVPixelBufferLockBaseAddress(pixel, [])
            guard lockResult == kCVReturnSuccess else { throw LumaError("Could not lock H.264 fixture frame \(frame) (Core Video \(lockResult)).") }
            if let base = CVPixelBufferGetBaseAddress(pixel) { memset(base, Int32(30 + frame * 2), CVPixelBufferGetDataSize(pixel)) }
            else { CVPixelBufferUnlockBaseAddress(pixel, []); throw LumaError("H.264 fixture frame \(frame) has no pixel storage.") }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            try await receiver.append(CVReadOnlyPixelBuffer(unsafeBuffer: pixel), with: CMTime(value: Int64(frame), timescale: 30))
        }
        receiver.finish()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? LumaError("The H.264 fixture movie did not finish.") }
    }
}

import Foundation
import AppKit
import AVFoundation

@main struct CoreTests {
    @MainActor static func main() async throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1; guard condition() else { throw LumaError("FAILED: \(message)") }
        }
        func rejects(_ body: () throws -> Void) throws {
            do { try body() } catch { assertions += 1; return }; throw LumaError("FAILED: unsafe input was accepted")
        }
        let track = SceneMediaProvider.decode(["playing", "A \"title\"\nwith text", "Artist", "Album", "Album Artist", "12.5", "180", "3"])
        try check(track.available && track.title == "A \"title\"\nwith text" && track.position == 12.5 && track.duration == 180, "track metadata preserves text and timeline")
        try check(track.artist == "Artist" && track.albumArtist == "Album Artist" && track.trackIndex == 3, "all supplied track fields")
        try check(SceneMediaProvider.decode([]) == .empty, "invalid metadata is empty")
        let invalidTrack = SceneMediaProvider.decode(["unknown", "Title", "", "", "", "nan", "inf", "-7"])
        try check(invalidTrack.position == 0 && invalidTrack.duration == 0 && invalidTrack.trackIndex == 0 && invalidTrack.state == "stopped", "metadata rejects nonfinite or negative values")
        try check(JSONSerialization.isValidJSONObject(track.json), "track data is safe for the script snapshot")
        var scriptError: NSDictionary?
        let query = NSAppleScript(source: SceneMediaProvider.metadataScript(for: .music))
        let queryCompiles = query?.compileAndReturnError(&scriptError) == true
        try check(queryCompiles, "fixed Music metadata query compiles without executing automation: \(scriptError ?? [:])")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LumaTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        try await makeVideo(fixture)
        let library = LibraryStore(root:root.appendingPathComponent("library"))
        try await library.importURL(fixture)
        try check(library.state.wallpapers.count == 1,"import generated video")
        try check(library.state.wallpapers[0].duration ?? 0 > 0,"extract duration")
        let restored = LibraryStore(root:library.root)
        try check(restored.state.wallpapers.count == 1,"restore saved library")

        // Removing a wallpaper must preserve its media when the index cannot be saved.
        let removalLibrary = LibraryStore(root: root.appendingPathComponent("removal-library"))
        try await removalLibrary.importURL(fixture)
        let removalItem = removalLibrary.state.wallpapers[0]
        let removalMedia = try removalLibrary.mediaURL(removalItem)
        let removalIndex = removalLibrary.root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: removalIndex)
        try FileManager.default.createDirectory(at: removalIndex, withIntermediateDirectories: false)
        removalLibrary.remove(removalItem)
        try check(removalLibrary.state.wallpapers.count == 1 && FileManager.default.fileExists(atPath: removalMedia.path), "failed removal save preserves the library record and media")
        try FileManager.default.removeItem(at: removalIndex)
        try check(removalLibrary.save(), "restore the isolated removal test index")
        var unsafeLibrary = removalLibrary.state
        unsafeLibrary.wallpapers[0].folder = "../../outside"
        let unsafeIndex = try JSONEncoder().encode(unsafeLibrary)
        try unsafeIndex.write(to: removalIndex)
        let blockedLibrary = LibraryStore(root: removalLibrary.root)
        try check(blockedLibrary.error != nil && !blockedLibrary.save(), "unsafe saved ownership records block library writes")
        let preservedUnsafeIndex = try Data(contentsOf: removalIndex)
        try check(preservedUnsafeIndex == unsafeIndex, "unsafe library index is preserved for recovery")
        try rejects { try blockedLibrary.resetForClearData() }

        let hiddenLinkProject = root.appendingPathComponent("hidden-link-project")
        try FileManager.default.createDirectory(at: hiddenLinkProject, withIntermediateDirectories: true)
        try Data("{\"type\":\"video\",\"file\":\"video.mov\"}".utf8).write(to: hiddenLinkProject.appendingPathComponent("project.json"))
        try FileManager.default.copyItem(at: fixture, to: hiddenLinkProject.appendingPathComponent("video.mov"))
        try FileManager.default.createSymbolicLink(at: hiddenLinkProject.appendingPathComponent(".hidden-link"), withDestinationURL: fixture)
        do { try await library.importURL(hiddenLinkProject); throw LumaError("FAILED: imported a hidden symlink") }
        catch let error as LumaError { guard error.message.contains("symbolic link") else { throw error }; assertions += 1 }

        let cleanupLibrary = LibraryStore(root: root.appendingPathComponent("cleanup-library"))
        try await cleanupLibrary.importURL(fixture)
        let unknownMedia = cleanupLibrary.root.appendingPathComponent("Media/user-file.txt")
        try Data("keep".utf8).write(to: unknownMedia)
        let ownedFolder = cleanupLibrary.folder(cleanupLibrary.state.wallpapers[0])
        try cleanupLibrary.resetForClearData()
        try check(!FileManager.default.fileExists(atPath: ownedFolder.path) && FileManager.default.fileExists(atPath: unknownMedia.path), "Clear Data removes only recorded media and preserves unknown files")
        try check(!cleanupLibrary.save() && !FileManager.default.fileExists(atPath: cleanupLibrary.root.appendingPathComponent("library.json").path), "Clear Data prevents shutdown from recreating the library")

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
        let missing = try WallperVideosDiscoveryService.discover(at: root.appendingPathComponent("missing-wallper-folder"))
        try check(!missing.folderExists && missing.videos.isEmpty, "missing Wallper folder is reported without failure")
        let discovered = try WallperVideosDiscoveryService.discover(at: wallperFolder)
        try check(discovered.videos.map(\.filename) == ["broken.mp4", "gentle-lake.mov"], "discover supported readable video files and skip unsupported files and symlinks")
        try check(discovered.supportedCandidateCount == 2, "count supported video candidates")
        try rejects { _ = try WallperVideosDiscoveryService.validate(outsideVideo, under: wallperFolder) }
        try rejects { _ = try WallperVideosDiscoveryService.validate(wallperFolder.appendingPathComponent("outside.mov"), under: wallperFolder) }
        let wallperFolderLink = root.appendingPathComponent("WallperVideosLink")
        try FileManager.default.createSymbolicLink(at: wallperFolderLink, withDestinationURL: wallperFolder)
        try rejects { _ = try WallperVideosDiscoveryService.discover(at: wallperFolderLink) }

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
        let restoredEditorProjects = EditorProjectStore(library: LibraryStore(root: library.root))
        try check(restoredEditorProjects.projects.count == 2 && restoredEditorProjects.recentProjectIDs.first == project.id, "editor project browser restores projects and recents")
        try rejects { _ = try SceneProjectPackage(data: package("../escape.json", bytes: Data([1]))) }
        let unsafeProject = root.appendingPathComponent("unsafe-editor-project")
        try FileManager.default.createDirectory(at: unsafeProject, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: unsafeProject.appendingPathComponent("outside"), withDestinationURL: root)
        try rejects { _ = try editorProjects.importProject(unsafeProject) }
        let malicious = root.appendingPathComponent("malicious")
        try FileManager.default.createDirectory(at:malicious,withIntermediateDirectories:true)
        try Data("{\"type\":\"video\",\"file\":\"../fixture.mov\"}".utf8).write(to:malicious.appendingPathComponent("project.json"))
        do {try await library.importURL(malicious);throw LumaError("FAILED unsafe import")} catch let error as LumaError {guard error.message.contains("unsafe path") else {throw error};assertions += 1}
        try check(library.state.wallpapers.count == 1,"failed import does not publish item")
        let item = library.state.wallpapers[0];library.remove(item)
        try check(library.state.wallpapers.isEmpty,"remove imported copy")
        try check(FileManager.default.fileExists(atPath:fixture.path),"original source preserved")
        print("PASS: import, persistence, rollback, and source-preservation checks")
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
        let packed = package("materials/background.png", bytes: Data([1,2,3]))
        let media = try SceneMediaDiscovery.archiveCandidates(packed)
        try check(media.count == 1, "discover packed scene image")
        let packedBytes = try media[0].bytes()
        try check(packedBytes == Data([1,2,3]), "read exact packed scene media range")
        try rejects { _ = try SceneMediaDiscovery.archiveCandidates(package("../escape.png", bytes: Data([1]))) }
        try rejects { _ = try SceneMediaDiscovery.archiveCandidates(package("video.mp4", bytes: Data([1]), offset: 50)) }
        try rejects { _ = try SceneMediaDiscovery.archiveCandidates(Data([0,0,0])) }
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
        print("PASS: SteamCMD detection, packed media safety, source-image fallback, and native still installation in a temporary catalog")
        print("ALL PASSED (\(assertions) assertions). No system wallpaper files were changed.")
    }
    static func makeVideo(_ url:URL) async throws {
        let writer=try AVAssetWriter(outputURL:url,fileType:.mov)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:128,AVVideoHeightKey:72])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:128,kCVPixelBufferHeightKey as String:72])
        writer.add(input);guard writer.startWriting() else {throw writer.error!};writer.startSession(atSourceTime:.zero)
        for n in 0..<60 {
            while !input.isReadyForMoreMediaData {try await Task.sleep(for:.milliseconds(2))}
            var pixel:CVPixelBuffer?;CVPixelBufferPoolCreatePixelBuffer(nil,adaptor.pixelBufferPool!,&pixel)
            guard let pixel else {throw LumaError("No fixture pixel buffer")}
            CVPixelBufferLockBaseAddress(pixel,[])
            memset(CVPixelBufferGetBaseAddress(pixel),Int32(30+n*2),CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel,[])
            guard adaptor.append(pixel,withPresentationTime:CMTime(value:Int64(n),timescale:30)) else {throw writer.error!}
        }
        input.markAsFinished();await writer.finishWriting();guard writer.status == .completed else {throw writer.error!}
    }
}

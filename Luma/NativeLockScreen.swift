import AppKit
import AVFoundation
import Combine

// Changes only Luma's catalog records, preserving Apple and other apps' entries.
enum NativeCatalog {
    static let categoryID = "D839C508-3E1F-4A1B-98DB-64485752C810"
    static let subcategoryID = "D839C508-3E1F-4A1B-98DB-64485752C811"
    static func adding(assetID: String, title: String, video: URL, thumbnail: URL, to original: [String: Any]) throws -> [String: Any] {
        guard var assets = original["assets"] as? [[String: Any]], var categories = original["categories"] as? [[String: Any]] else { throw LumaError("This macOS catalog has an unknown schema. No system files were changed.") }
        var catalog = original
        assets.removeAll { $0["id"] as? String == assetID }
        assets.append(["id":assetID,"shotID":"LUMA_\(assetID)","accessibilityLabel":title,"localizedNameKey":title,
                       "categories":[categoryID],"subcategories":[subcategoryID],"includeInShuffle":true,"showInTopLevel":true,
                       "preferredOrder":0,"pointsOfInterest":["0":"LUMA_\(assetID)_0"],"previewImage":thumbnail.absoluteString,"url-4K-SDR-240FPS":video.absoluteString])
        categories.removeAll { $0["id"] as? String == categoryID }
        let common: [String: Any] = ["localizedNameKey":"Luma","localizedDescriptionKey":"Luma Live Wallpapers","preferredOrder":0,"previewImage":thumbnail.absoluteString,"representativeAssetID":assetID]
        var category = common; category["id"] = categoryID
        var sub = common; sub["id"] = subcategoryID; category["subcategories"] = [sub]
        categories.append(category); catalog["assets"] = assets; catalog["categories"] = categories
        return catalog
    }
    static func removingOwned(from original: [String: Any]) -> [String: Any] {
        var catalog = original
        if let assets = original["assets"] as? [[String: Any]] { catalog["assets"] = assets.filter { !(($0["categories"] as? [String])?.contains(categoryID) ?? false) } }
        if let categories = original["categories"] as? [[String: Any]] { catalog["categories"] = categories.filter { $0["id"] as? String != categoryID } }
        return catalog
    }
}

// Works with the observed Linked and Idle shapes. A linked choice is deliberately
// left linked: selecting it can also affect the static desktop, as the UI explains.
enum NativeSelection {
    static func selecting(assetID: String, in original: [String: Any]) throws -> [String: Any] {
        let config = try PropertyListSerialization.data(fromPropertyList: ["assetID":assetID], format: .binary, options: 0)
        var changed = 0
        func walk(_ value: Any) -> Any {
            if let array = value as? [Any] { return array.map(walk) }
            guard var dictionary = value as? [String: Any] else { return value }
            for key in Array(dictionary.keys) {
                if ["Idle","Linked"].contains(key), var surface = dictionary[key] as? [String: Any], var content = surface["Content"] as? [String: Any], let choices = content["Choices"] as? [[String: Any]], !choices.isEmpty {
                    var choice = choices[0]; choice["Provider"] = "com.apple.wallpaper.choice.aerials"; choice["Configuration"] = config; choice["Files"] = [Any]()
                    content["Choices"] = [choice]; surface["Content"] = content; dictionary[key] = surface; changed += 1
                } else { dictionary[key] = walk(dictionary[key]!) }
            }
            return dictionary
        }
        guard let result = walk(original) as? [String: Any], changed > 0 else { throw LumaError("The wallpaper selection format is not recognized. Select Luma in System Settings instead.") }
        return result
    }
}

struct NativeReceipt: Codable {
    var assetID: String
    var title: String
    var videoPath: String
    var thumbnailPath: String
    var installed = Date()
    var sourceDescription: String?
}

@MainActor final class NativeLockScreen: ObservableObject {
    @Published var busy = false
    @Published var progress = 0.0
    @Published var status = "Install a prepared video into macOS's native wallpaper collection."
    @Published var receipt: NativeReceipt?
    @Published var staticFallbackURL: URL?
    @Published var staticFallbackSource = ""
    @Published var selectAutomatically = false
    @Published var sceneSeconds = 20
    @Published var sceneMode: SceneLockScreenMode = .automatic
    private var task: Task<Void, Never>?
    private let library: LibraryStore
    private var root: URL?
    private let opensSettings: Bool
    private var recordedAssetIDs: [String] {
        let backupRoot = library.root.appendingPathComponent("NativeBackups", isDirectory: true)
        guard let rootAttributes = try? FileManager.default.attributesOfItem(atPath: backupRoot.path),
              rootAttributes[.type] as? FileAttributeType == .typeDirectory else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        return entries.compactMap { directory in
            guard let id = UUID(uuidString: directory.lastPathComponent)?.uuidString,
                  let directoryValues = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else { return nil }
            let snapshot = directory.appendingPathComponent("entries.json")
            guard let fileValues = try? snapshot.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  fileValues.isRegularFile == true, fileValues.isSymbolicLink != true else { return nil }
            return id
        }
    }
    var hasManagedChanges: Bool {
        if receipt != nil { return true }
        return !recordedAssetIDs.isEmpty
    }
    init(library: LibraryStore, wallpaperRoot: URL? = nil, opensSettings: Bool = true) {
        self.library = library; self.opensSettings = opensSettings
        root = wallpaperRoot
        if root == nil, let data = Bookmark.savedData(forKey: "native-root") { root = try? Bookmark.resolve(data) }
        if let data = try? Data(contentsOf: library.root.appendingPathComponent("native-receipt.json")) { receipt = try? JSONDecoder().decode(NativeReceipt.self, from: data) }
        let fallbackDirectory = library.root.appendingPathComponent("LockScreenFallbacks", isDirectory: true)
        let fallback = fallbackDirectory.appendingPathComponent("lock-screen-still.png")
        let marker = fallbackDirectory.appendingPathComponent(".luma-owned")
        let directoryValues = try? fallbackDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let markerValues = try? marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        if directoryValues?.isDirectory == true, directoryValues?.isSymbolicLink != true,
           markerValues?.isRegularFile == true, markerValues?.isSymbolicLink != true,
           (try? String(contentsOf: marker, encoding: .utf8)) == "Luma static fallback v1",
           (try? fallback.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile) == true,
           (try? fallback.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isSymbolicLink) != true {
            staticFallbackURL = fallback
            staticFallbackSource = UserDefaults.standard.string(forKey: "luma.lockScreenFallback.source") ?? "Prepared still image"
        }
    }
    func chooseRoot() {
        do {
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.directoryURL = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Application Support")
            panel.message = "Choose your com.apple.wallpaper folder in ~/Library/Application Support. Luma will add its own collection and save backups. Press ⇧⌘G to enter the path."
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            guard chosen.lastPathComponent == "com.apple.wallpaper" else { throw LumaError("Choose the com.apple.wallpaper folder, not the aerials subfolder.") }
            root = chosen; UserDefaults.standard.set(try Bookmark.create(chosen), forKey: "native-root")
            status = "Wallpaper folder connected."
        } catch { status = error.localizedDescription }
    }
    func install(_ wallpaper: Wallpaper, assets: URL?) {
        guard !busy else { return }
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else { status = "Native video lock screens require macOS 26 or newer. Desktop wallpapers work on macOS 14+."; return }
        if root == nil { chooseRoot() }
        guard let root else { return }
        let access = root.startAccessingSecurityScopedResource()
        busy = true; progress = 0
        let requestedMode = sceneMode
        let requestedSeconds = sceneSeconds
        task = Task {
            var host: SceneHost?
            var renderWindow: NSWindow?
            var sceneError: String?
            let work = library.root.appendingPathComponent("NativeCache/\(UUID().uuidString)")
            defer { if access { root.stopAccessingSecurityScopedResource() }; host?.stop(); renderWindow?.close(); try? FileManager.default.removeItem(at: work); busy = false; task = nil }
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                try Data("Luma NativeCache v1".utf8).write(to: work.appendingPathComponent(".luma-owned"), options: .atomic)
                let encoded = work.appendingPathComponent("prepared.mov")
                @MainActor func getHost() -> SceneHost {
                    if let host { return host }
                    let scene = SceneHost(folder: library.folder(wallpaper), assets: assets, wallpaper: wallpaper, configuration: DisplayConfiguration(), preferences: library.state.preferences)
                    host = scene
                    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 720), styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true; window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
                    window.contentView = scene.webView; window.orderBack(nil); renderWindow = window
                    scene.failed = { sceneError = $0 }
                    return scene
                }
                @MainActor func readyHost() async throws -> SceneHost {
                    let scene = getHost(); let deadline = Date().addingTimeInterval(50)
                    while !scene.didBecomeReady {
                        try Task.checkCancellation()
                        if let sceneError { throw LumaError(sceneError) }
                        guard Date() < deadline else { throw LumaError("Scene export timed out while loading.") }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    return scene
                }
                @MainActor func encode(_ source: URL) async throws {
                    try Task.checkCancellation()
                    try? FileManager.default.removeItem(at: encoded)
                    status = "Preparing native lock screen video…"
                    let worker = Task.detached(priority: .userInitiated) {
                        try await TemporalEncoder.encode(source: source, output: encoded) { value in Task { @MainActor in self.progress = 0.55 + value * 0.4 } }
                    }
                    try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                }
                @MainActor func still(_ data: Data) async throws {
                    try Task.checkCancellation()
                    guard let image = NSBitmapImageRep(data: data), let png = image.representation(using: .png, properties: [:]) else { throw LumaError("The scene image cannot be decoded.") }
                    try png.write(to: work.appendingPathComponent("fallback.png"), options: .atomic)
                    let movie = work.appendingPathComponent("still-\(UUID().uuidString).mov")
                    let worker = Task.detached(priority: .userInitiated) { try await StillMovieExporter.export(imageData: png, output: movie) }
                    try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    try await encode(movie)
                }
                @MainActor func snapshot() async throws -> String {
                    status = "Capturing a still frame from the scene…"
                    let scene = try await readyHost()
                    let capture = try await scene.capture(time: 0, width: 1920, height: 1080)
                    try await still(capture)
                    return "Captured scene still"
                }
                @MainActor func sourceMedia(_ candidates: [SceneMediaCandidate]) async throws -> String? {
                    for (index, candidate) in candidates.enumerated() {
                        try Task.checkCancellation()
                        do {
                            status = "Trying scene media: \(candidate.name)…"
                            var usedVideo = candidate.isVideo
                            if candidate.isVideo {
                                let url: URL
                                if let file = candidate.file { url = file }
                                else { url = work.appendingPathComponent("media-\(index).\(candidate.ext)"); try candidate.bytes().write(to: url, options: .atomic) }
                                guard try await AVURLAsset(url: url).load(.isPlayable) else { continue }
                                try await encode(url)
                            } else {
                                let data = try candidate.bytes()
                                if candidate.ext == "tex" {
                                    let decoded = try await getHost().decodeTextureMedia(data)
                                    if decoded.isVideo {
                                        let movie = work.appendingPathComponent("texture-\(index).mp4")
                                        try decoded.data.write(to: movie, options: .atomic); try await encode(movie); usedVideo = true
                                    } else { try await still(decoded.data) }
                                }
                                else { try await still(data) }
                            }
                            return "\(candidate.isPreview ? "Scene preview" : usedVideo ? "Scene video" : "Scene image"): \(candidate.name)"
                        } catch is CancellationError { throw CancellationError() }
                        catch { try Task.checkCancellation(); continue }
                    }
                    return nil
                }
                let sourceDescription: String
                if wallpaper.kind == .video {
                    try await encode(library.mediaURL(wallpaper)); sourceDescription = "Original video"
                } else if wallpaper.kind == .image {
                    try await still(Data(contentsOf: library.mediaURL(wallpaper))); sourceDescription = "Original still image"
                } else if wallpaper.kind == .scene {
                    var selected: String?
                    if requestedMode == .automatic {
                        do {
                            status = "Rendering \(requestedSeconds) seconds of the scene…"
                            let scene = try await readyHost(); let movie = work.appendingPathComponent("scene.mov")
                            try await SceneMovieExporter.export(host: scene, output: movie, seconds: requestedSeconds, fps: 30, width: 1920, height: 1080) { self.progress = $0 * 0.55 }
                            try await encode(movie); selected = "Rendered scene loop"
                        } catch is CancellationError { throw CancellationError() }
                        catch { try Task.checkCancellation(); status = "Scene loop unavailable. Trying a lock screen fallback…" }
                    }
                    if selected == nil, requestedMode == .snapshot {
                        do { selected = try await snapshot() } catch is CancellationError { throw CancellationError() } catch { try Task.checkCancellation() }
                    }
                    if selected == nil {
                        let choices = try SceneMediaDiscovery.candidates(folder: library.folder(wallpaper), entry: wallpaper.entry, preview: wallpaper.preview)
                        selected = try await sourceMedia(choices.filter { !$0.isPreview })
                        if selected == nil, requestedMode != .snapshot {
                            do { selected = try await snapshot() } catch is CancellationError { throw CancellationError() } catch { try Task.checkCancellation() }
                        }
                        if selected == nil { selected = try await sourceMedia(choices.filter(\.isPreview)) }
                    }
                    guard let selected else { throw LumaError("This scene could not produce a lock screen loop, usable video/image, or captured still. Try a project with a preview image or a supported source video.") }
                    sourceDescription = selected
                } else { throw LumaError("Choose a video, image, or Wallpaper Engine scene.") }
                try Task.checkCancellation()
                status = "Installing Luma's native wallpaper collection…"
                let assetID = UUID().uuidString.uppercased()
                var result = try await commit(encoded: encoded, title: wallpaper.title, assetID: assetID, root: root)
                result.sourceDescription = sourceDescription
                receipt = result; try JSONEncoder().encode(result).write(to: library.root.appendingPathComponent("native-receipt.json"), options: .atomic)
                if selectAutomatically { try select(assetID: assetID, root: root) }
                progress = 1
                status = "Installed using \(sourceDescription.lowercased()). " + (selectAutomatically ? "Selected for the native wallpaper." : "Select Luma in Wallpaper settings for your lock screen / screen saver.")
                if opensSettings { openSettings() }
            } catch is CancellationError { status = "Cancelled. No unfinished wallpaper was installed." }
            catch { status = error.localizedDescription }
        }
    }
    func prepareStaticFallback(_ wallpaper: Wallpaper, assets: URL?) {
        guard !busy else { return }
        busy = true; progress = 0
        task = Task {
            defer { busy = false; task = nil }
            do {
                status = "Preparing a static lock-screen fallback…"
                let result = try await SceneStaticFallback.image(wallpaper: wallpaper, folder: library.folder(wallpaper),
                                                                mediaURL: library.mediaURL(wallpaper), assets: assets,
                                                                preferences: library.state.preferences)
                try Task.checkCancellation()
                let directory = library.root.appendingPathComponent("LockScreenFallbacks", isDirectory: true)
                let marker = directory.appendingPathComponent(".luma-owned")
                let fm = FileManager.default
                if fm.fileExists(atPath: directory.path) {
                    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    let markerValues = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true,
                          markerValues.isRegularFile == true, markerValues.isSymbolicLink != true,
                          try String(contentsOf: marker, encoding: .utf8) == "Luma static fallback v1" else {
                        throw LumaError("The fallback folder is not an owned Luma folder, so it was left untouched.")
                    }
                } else {
                    try fm.createDirectory(at: directory, withIntermediateDirectories: false)
                    try Data("Luma static fallback v1".utf8).write(to: marker, options: .atomic)
                }
                let output = directory.appendingPathComponent("lock-screen-still.png")
                if fm.fileExists(atPath: output.path) {
                    let values = try output.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        throw LumaError("The existing fallback is not a regular Luma image file, so it was left untouched.")
                    }
                }
                try result.0.write(to: output, options: .atomic)
                staticFallbackURL = output
                staticFallbackSource = result.1
                UserDefaults.standard.set(result.1, forKey: "luma.lockScreenFallback.source")
                progress = 1
                status = "Saved a static fallback using \(result.1). Preview it here, then add it in System Settings → Wallpaper if your macOS setup allows a separate lock-screen choice."
            } catch is CancellationError { status = "Static fallback preparation was cancelled." }
            catch { status = error.localizedDescription }
        }
    }
    func removeStaticFallback() throws {
        guard let fallback = staticFallbackURL else { return }
        let directory = library.root.appendingPathComponent("LockScreenFallbacks", isDirectory: true)
        let marker = directory.appendingPathComponent(".luma-owned")
        let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let markerValues = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true,
              markerValues.isRegularFile == true, markerValues.isSymbolicLink != true,
              try String(contentsOf: marker, encoding: .utf8) == "Luma static fallback v1" else {
            throw LumaError("Luma's fallback ownership marker is missing or changed. No files were removed.")
        }
        let values = try fallback.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              fallback.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL else {
            throw LumaError("The fallback file is no longer a regular file inside Luma's managed folder. It was left untouched.")
        }
        try FileManager.default.removeItem(at: fallback)
        try FileManager.default.removeItem(at: marker)
        if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true { try? FileManager.default.removeItem(at: directory) }
        staticFallbackURL = nil; staticFallbackSource = ""
        UserDefaults.standard.removeObject(forKey: "luma.lockScreenFallback.source")
    }
    private func commit(encoded: URL, title: String, assetID: String, root: URL) async throws -> NativeReceipt {
        let fm = FileManager.default
        try Safety.validateDirectoryIfPresent(root)
        let manifest = try Safety.child("aerials/manifest/entries.json", under: root)
        let original: Data
        let existing = fm.fileExists(atPath: manifest.path)
        if existing { original = try Data(contentsOf: manifest) }
        else {
            let seed = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/Resources/entries.json")
            original = try Data(contentsOf: seed)
        }
        guard let catalog = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw LumaError("The native catalog is invalid.") }
        let videos = try Safety.child("aerials/videos", under: root), thumbnails = try Safety.child("aerials/thumbnails", under: root)
        for folder in [videos, thumbnails, manifest.deletingLastPathComponent()] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let destination = videos.appendingPathComponent(assetID + ".mov"), thumbnail = thumbnails.appendingPathComponent(assetID + ".png")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: encoded)); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 960, height: 540)
        let image = try await generator.image(at: .zero).image
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw LumaError("Could not generate a lock screen preview.") }
        let newCatalog = try NativeCatalog.adding(assetID: assetID, title: title, video: destination, thumbnail: thumbnail, to: catalog)
        let encodedCatalog = try JSONSerialization.data(withJSONObject: newCatalog, options: [.sortedKeys])
        let backups = try Safety.child("NativeBackups/\(assetID)", under: library.root); try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        try original.write(to: backups.appendingPathComponent("entries.json"), options: .atomic)
        var published = false
        do {
            try fm.copyItem(at: encoded, to: destination); try png.write(to: thumbnail, options: .atomic)
            try Task.checkCancellation()
            if existing {
                guard try Data(contentsOf: manifest) == original else { throw LumaError("The native catalog changed during installation. Retry to preserve the latest system settings.") }
            } else if fm.fileExists(atPath: manifest.path) {
                throw LumaError("A native catalog appeared during installation. Retry to preserve the new system settings.")
            }
            try encodedCatalog.write(to: manifest, options: .atomic); published = true
            return NativeReceipt(assetID: assetID, title: title, videoPath: destination.path, thumbnailPath: thumbnail.path)
        } catch { if !published { try? fm.removeItem(at: destination); try? fm.removeItem(at: thumbnail) }; throw error }
    }
    private func select(assetID: String, root: URL) throws {
        let url = try Safety.child("Store/Index.plist", under: root)
        let data = try Data(contentsOf: url)
        guard let original = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw LumaError("Unknown wallpaper store format. Choose the wallpaper in System Settings.") }
        let result = try NativeSelection.selecting(assetID: assetID, in: original)
        let backup = try Safety.child("NativeBackups/selection-original.plist", under: library.root)
        let installedBackup = try Safety.child("NativeBackups/selection-installed.plist", under: library.root)
        let previousInstall = try? Data(contentsOf: installedBackup)
        if previousInstall != data || !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup, options: .atomic) }
        let updated = try PropertyListSerialization.data(fromPropertyList: result, format: .binary, options: 0)
        // Record both sides before mutating the system selection, so a failed
        // backup write cannot leave an untracked wallpaper change.
        try updated.write(to: installedBackup, options: .atomic)
        guard try Data(contentsOf: url) == data else { throw LumaError("Wallpaper settings changed. The newer selection was preserved.") }
        try updated.write(to: url, options: .atomic)
    }
    func removeInstalled() {
        guard !busy else { return }
        if root == nil { chooseRoot() }; guard let root else { return }
        let access = root.startAccessingSecurityScopedResource(); defer { if access { root.stopAccessingSecurityScopedResource() } }
        do { try removeInstalledChanges(in: root, openSettingsAfterward: true) }
        catch { status = error.localizedDescription }
    }
    func clearDataRestorePlan() -> [String] {
        guard hasManagedChanges else { return [] }
        let paths = receipt.map { " Remove the recorded video and thumbnail from \(URL(fileURLWithPath: $0.videoPath).deletingLastPathComponent().path)." } ?? " Remove only the Luma-owned catalog entries and generated files recorded in Luma's backup folder."
        return ["Restore your previous macOS wallpaper selection if it still matches Luma's last change, and remove Luma's native wallpaper collection.", paths]
    }
    func restoreManagedChangesForClearData() throws {
        guard !busy else { throw LumaError("Wait for the lock screen export to finish before clearing Luma data.") }
        guard hasManagedChanges else { return }
        guard let root else { throw LumaError("Luma's wallpaper folder is not available. Reconnect it before clearing data so Luma can restore your previous selection.") }
        let access = root.startAccessingSecurityScopedResource(); defer { if access { root.stopAccessingSecurityScopedResource() } }
        do { try removeInstalledChanges(in: root, openSettingsAfterward: false) }
        catch { status = "Could not restore Luma's native wallpaper changes: \(error.localizedDescription)"; throw error }
    }
    private func removeInstalledChanges(in root: URL, openSettingsAfterward: Bool) throws {
        let fm = FileManager.default
        try Safety.validateDirectoryIfPresent(root)
        let backupRoot = library.root.appendingPathComponent("NativeBackups", isDirectory: true)
        try validateBackupDirectoryIfPresent(backupRoot)
        let selectionInstalled = backupRoot.appendingPathComponent("selection-installed.plist")
        let selectionOriginal = backupRoot.appendingPathComponent("selection-original.plist")
        try validateBackupFileIfPresent(selectionInstalled)
        try validateBackupFileIfPresent(selectionOriginal)
        let manifest = try Safety.child("aerials/manifest/entries.json", under: root)
        let data = try Data(contentsOf: manifest)
        guard let original = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              original["assets"] is [[String: Any]], original["categories"] is [[String: Any]] else { throw LumaError("The native catalog schema is not recognized. No catalog records were removed.") }
        let owned = (original["assets"] as? [[String: Any]] ?? []).filter { ($0["categories"] as? [String])?.contains(NativeCatalog.categoryID) == true }
        let updated = NativeCatalog.removingOwned(from: original)
        // Restore a selection only when it still exactly matches our own write.
        let store = try Safety.child("Store/Index.plist", under: root)
        if let installed = try? Data(contentsOf: library.root.appendingPathComponent("NativeBackups/selection-installed.plist")), let current = try? Data(contentsOf: store), current == installed,
           let backup = try? Data(contentsOf: library.root.appendingPathComponent("NativeBackups/selection-original.plist")) { try backup.write(to: store, options: .atomic) }
        guard try Data(contentsOf: manifest) == data else { throw LumaError("The catalog changed. Retry removal.") }
        try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys]).write(to: manifest, options: .atomic)
        // Per-install backups retain generated IDs so a retry can finish after
        // the catalog update without touching files owned by macOS or Steam.
        let backupIDs = recordedAssetIDs
        let ownedIDs = owned.compactMap { $0["id"] as? String }.filter { UUID(uuidString: $0) != nil }
        let receiptIDs = receipt.flatMap { UUID(uuidString: $0.assetID)?.uuidString }.map { [$0] } ?? []
        for id in Set(ownedIDs + backupIDs + receiptIDs) {
            for path in ["aerials/videos/\(id).mov", "aerials/thumbnails/\(id).png"] {
                let file = try Safety.child(path, under: root)
                try validateBackupFileIfPresent(file)
                if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
            }
        }
        for id in backupIDs {
            let directory = backupRoot.appendingPathComponent(id, isDirectory: true)
            let snapshot = directory.appendingPathComponent("entries.json")
            try validateBackupFileIfPresent(snapshot)
            if fm.fileExists(atPath: snapshot.path) { try fm.removeItem(at: snapshot) }
            try removeBackupDirectoryIfEmpty(directory)
        }
        for file in [selectionInstalled, selectionOriginal] where fm.fileExists(atPath: file.path) {
            try fm.removeItem(at: file)
        }
        try removeBackupDirectoryIfEmpty(backupRoot)
        let receiptFile = try Safety.child("native-receipt.json", under: library.root)
        try validateBackupFileIfPresent(receiptFile)
        if fm.fileExists(atPath: receiptFile.path) { try fm.removeItem(at: receiptFile) }
        receipt = nil
        status = "Luma's native collection was removed."
        if openSettingsAfterward && opensSettings { openSettings() }
    }
    private func validateBackupDirectoryIfPresent(_ url: URL) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw LumaError("\(url.path) is not a Luma backup directory. It was left untouched.")
        }
    }
    private func validateBackupFileIfPresent(_ url: URL) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw LumaError("\(url.path) is not a regular Luma backup file. It was left untouched.")
        }
    }
    private func removeBackupDirectoryIfEmpty(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try validateBackupDirectoryIfPresent(url)
        if try fm.contentsOfDirectory(atPath: url.path).isEmpty { try fm.removeItem(at: url) }
    }
    func resetForClearData() {
        root = nil; receipt = nil; staticFallbackURL = nil; staticFallbackSource = ""; selectAutomatically = false; sceneSeconds = 20; sceneMode = .automatic
        UserDefaults.standard.removeObject(forKey: "luma.lockScreenFallback.source")
        status = "Install a prepared video into macOS's native wallpaper collection."
    }
    func cancel() { task?.cancel() }
    func openSettings() { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!) }
}

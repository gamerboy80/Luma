import AppKit
import AVFoundation
import Combine
import CryptoKit

/// Removes settings used by the retired private-SkyLight live overlay. Luma no
/// longer creates windows in authenticated lock-screen spaces.
enum LockScreenOverlayMigration {
    static let legacyKeys = [
        "luma.experimentalLockOverlay.enabled",
        "luma.experimentalLockOverlay.wallpaperID"
    ]

    static func retireLegacySettings(defaults: UserDefaults = .standard) {
        for key in legacyKeys { defaults.removeObject(forKey: key) }
    }
}

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
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct NativeInstallState: Codable {
    static let currentVersion = 1
    static let allowedCreatedDirectories: Set<String> = ["aerials", "aerials/videos", "aerials/thumbnails", "aerials/manifest"]
    var version = currentVersion
    var manifestExisted: Bool
    var installedManifestSHA256: String
    var createdDirectories: [String]

    func validate() throws {
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        guard version == Self.currentVersion,
              installedManifestSHA256.count == 64,
              installedManifestSHA256.unicodeScalars.allSatisfy(hexadecimal.contains),
              createdDirectories.count <= Self.allowedCreatedDirectories.count,
              Set(createdDirectories).count == createdDirectories.count,
              createdDirectories.allSatisfy(Self.allowedCreatedDirectories.contains) else {
            throw LumaError("A native wallpaper install state record is invalid.")
        }
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
    private var persistedReceiptData: Data?
    private var receiptReadError: String?
    private var persistedBackupData: [String: Data] = [:]
    private var backupReadError: String?
    private var recordedAssetIDs: [String] {
        let backupRoot = library.root.appendingPathComponent("NativeBackups", isDirectory: true)
        guard let rootAttributes = try? FileManager.default.attributesOfItem(atPath: backupRoot.path),
              rootAttributes[.type] as? FileAttributeType == .typeDirectory else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        return entries.compactMap { directory in
            guard let id = UUID(uuidString: directory.lastPathComponent)?.uuidString,
                  let directoryValues = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else { return nil }
            let hasOwnedRecord = ["entries.json", "install-state.json"].contains { name in
                guard let values = try? directory.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
            }
            guard hasOwnedRecord else { return nil }
            return id
        }
    }
    var hasManagedChanges: Bool {
        if receiptReadError != nil { return true }
        if backupReadError != nil { return true }
        if receipt != nil { return true }
        let backupRoot = library.root.appendingPathComponent("NativeBackups", isDirectory: true)
        return !recordedAssetIDs.isEmpty
            || FileManager.default.fileExists(atPath: backupRoot.appendingPathComponent("selection-original.plist").path)
            || FileManager.default.fileExists(atPath: backupRoot.appendingPathComponent("selection-installed.plist").path)
    }
    init(library: LibraryStore, wallpaperRoot: URL? = nil, opensSettings: Bool = true) {
        self.library = library; self.opensSettings = opensSettings
        root = wallpaperRoot
        if root == nil, let data = Bookmark.savedData(forKey: "native-root") { root = try? Bookmark.resolve(data) }
        do { try loadReceipt() }
        catch {
            receiptReadError = "Luma could not verify its native wallpaper receipt. Clear Data will preserve it: \(error.localizedDescription)"
            status = receiptReadError!
        }
        do { try loadBackupSnapshots() }
        catch {
            backupReadError = "Luma could not verify its native wallpaper backups. Clear Data will preserve them: \(error.localizedDescription)"
            status = backupReadError!
        }
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
        guard !busy else { status = "Wait for the current wallpaper operation to finish before changing its folder."; return }
        do {
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.directoryURL = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Application Support")
            panel.message = "Choose your com.apple.wallpaper folder in ~/Library/Application Support. Luma will add its own collection and save backups. Press ⇧⌘G to enter the path."
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            guard chosen.lastPathComponent == "com.apple.wallpaper" else { throw LumaError("Choose the com.apple.wallpaper folder, not the aerials subfolder.") }
            let bookmark = try Bookmark.create(chosen)
            root = chosen
            UserDefaults.standard.set(bookmark, forKey: "native-root")
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
        let requestedSelectAutomatically = selectAutomatically
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
                    let png = try SceneStaticFallback.normalizedImage(data)
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
                try verifyReceiptSnapshot()
                status = "Installing Luma's native wallpaper collection…"
                let assetID = UUID().uuidString.uppercased()
                var result = try await commit(encoded: encoded, title: wallpaper.title, assetID: assetID, root: root)
                result.sourceDescription = sourceDescription
                try persistReceipt(result)
                if requestedSelectAutomatically { try select(assetID: assetID, root: root) }
                progress = 1
                status = "Installed using \(sourceDescription.lowercased()). " + (requestedSelectAutomatically ? "Selected for the native wallpaper." : "Select Luma in Wallpaper settings for your lock screen / screen saver.")
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
        guard !busy else { throw LumaError("Wait for static fallback preparation to finish before removing it.") }
        try validateStaticFallbackForClearData()
        let directory = try Safety.child("LockScreenFallbacks", under: library.root)
        let marker = try Safety.child("LockScreenFallbacks/.luma-owned", under: library.root)
        let fallback = try Safety.child("LockScreenFallbacks/lock-screen-still.png", under: library.root)
        let fm = FileManager.default
        if try attributesIfPresent(fallback) != nil { try fm.removeItem(at: fallback) }
        if try attributesIfPresent(marker) != nil { try fm.removeItem(at: marker) }
        if try attributesIfPresent(directory) != nil, try fm.contentsOfDirectory(atPath: directory.path).isEmpty {
            try fm.removeItem(at: directory)
        }
        staticFallbackURL = nil; staticFallbackSource = ""
        UserDefaults.standard.removeObject(forKey: "luma.lockScreenFallback.source")
    }
    private func validateStaticFallbackForClearData() throws {
        let directory = try Safety.child("LockScreenFallbacks", under: library.root)
        guard let directoryAttributes = try attributesIfPresent(directory) else { return }
        guard directoryAttributes[.type] as? FileAttributeType == .typeDirectory else {
            throw LumaError("Luma's lock-screen fallback folder is not a directory. It was left untouched.")
        }
        let marker = try Safety.child("LockScreenFallbacks/.luma-owned", under: library.root)
        let fallback = try Safety.child("LockScreenFallbacks/lock-screen-still.png", under: library.root)
        let markerAttributes = try attributesIfPresent(marker)
        let fallbackAttributes = try attributesIfPresent(fallback)
        if markerAttributes == nil && fallbackAttributes == nil { return }
        guard let markerAttributes,
              markerAttributes[.type] as? FileAttributeType == .typeRegular,
              ((markerAttributes[.size] as? NSNumber)?.intValue ?? 0) <= 128,
              try String(contentsOf: marker, encoding: .utf8) == "Luma static fallback v1" else {
            throw LumaError("Luma's fallback ownership marker is missing or changed. The fallback files were preserved.")
        }
        if let fallbackAttributes, fallbackAttributes[.type] as? FileAttributeType != .typeRegular {
            throw LumaError("The lock-screen fallback is not a regular Luma image file. It was left untouched.")
        }
    }
    private func loadReceipt() throws {
        let url = try Safety.child("native-receipt.json", under: library.root)
        guard let attributes = try attributesIfPresent(url) else { return }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw LumaError("Luma's native wallpaper receipt is not a regular file.")
        }
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 1024 * 1024 else {
            throw LumaError("Luma's native wallpaper receipt exceeds the 1 MiB safety limit.")
        }
        let data = try Data(contentsOf: url)
        let value = try JSONDecoder().decode(NativeReceipt.self, from: data)
        try validate(value)
        receipt = value
        persistedReceiptData = data
    }
    private func persistReceipt(_ value: NativeReceipt) throws {
        try verifyReceiptSnapshot()
        let url = try Safety.child("native-receipt.json", under: library.root)
        try validate(value)
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
        receipt = value
        persistedReceiptData = data
    }
    private func verifyReceiptSnapshot() throws {
        if let receiptReadError { throw LumaError(receiptReadError) }
        let url = try Safety.child("native-receipt.json", under: library.root)
        let attributes = try attributesIfPresent(url)
        if let attributes {
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw LumaError("Luma's native wallpaper receipt is not a regular file. It was left untouched.")
            }
            guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 1024 * 1024 else {
                throw LumaError("Luma's native wallpaper receipt exceeds the 1 MiB safety limit.")
            }
        }
        let current: Data?
        do { current = try attributes == nil ? nil : Data(contentsOf: url) }
        catch { throw LumaError("Could not read Luma's native wallpaper receipt: \(error.localizedDescription)") }
        guard current == persistedReceiptData else {
            receiptReadError = "Luma's native wallpaper receipt changed outside the app. Reopen Luma before clearing data; the newer record was preserved."
            throw LumaError(receiptReadError!)
        }
        if let current {
            let decoded = try JSONDecoder().decode(NativeReceipt.self, from: current)
            try validate(decoded)
            guard receipt?.assetID == decoded.assetID else {
                throw LumaError("The native wallpaper receipt changed after it was loaded.")
            }
        }
    }
    private func validate(_ value: NativeReceipt) throws {
        let sourceLength = value.sourceDescription?.utf8.count ?? 0
        guard let id = UUID(uuidString: value.assetID), id.uuidString == value.assetID,
              value.title.utf8.count <= 4096, sourceLength <= 16_384,
              value.installed.timeIntervalSince1970.isFinite else {
            throw LumaError("Luma's native wallpaper receipt contains invalid values.")
        }
    }
    private func validate(_ value: NativeReceipt, wallpaperRoot: URL) throws {
        try validate(value)
        let id = value.assetID
        let expectedVideo = try Safety.child("aerials/videos/\(id).mov", under: wallpaperRoot)
        let expectedThumbnail = try Safety.child("aerials/thumbnails/\(id).png", under: wallpaperRoot)
        guard URL(fileURLWithPath: value.videoPath).standardizedFileURL == expectedVideo.standardizedFileURL,
              URL(fileURLWithPath: value.thumbnailPath).standardizedFileURL == expectedThumbnail.standardizedFileURL else {
            throw LumaError("Luma's native wallpaper receipt points outside its recorded catalog paths.")
        }
    }
    private func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        catch { throw LumaError("Could not inspect \(url.path): \(error.localizedDescription)") }
    }
    private func commit(encoded: URL, title: String, assetID: String, root: URL) async throws -> NativeReceipt {
        let fm = FileManager.default
        try Safety.validateDirectoryIfPresent(root)
        let manifest = try Safety.child("aerials/manifest/entries.json", under: root)
        let original: Data
        let manifestAttributes = try attributesIfPresent(manifest)
        if let manifestAttributes {
            guard manifestAttributes[.type] as? FileAttributeType == .typeRegular else {
                throw LumaError("The native wallpaper catalog is not a regular file. It was left untouched.")
            }
            original = try Data(contentsOf: manifest)
        }
        else {
            let seed = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/Resources/entries.json")
            original = try Data(contentsOf: seed)
        }
        let existing = manifestAttributes != nil
        guard let catalog = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw LumaError("The native catalog is invalid.") }
        let videos = try Safety.child("aerials/videos", under: root), thumbnails = try Safety.child("aerials/thumbnails", under: root)
        let managedDirectories: [(String, URL)] = [
            ("aerials", try Safety.child("aerials", under: root)),
            ("aerials/videos", videos),
            ("aerials/thumbnails", thumbnails),
            ("aerials/manifest", manifest.deletingLastPathComponent())
        ]
        var createdDirectories: [String] = []
        for (relative, folder) in managedDirectories {
            if try attributesIfPresent(folder) == nil { createdDirectories.append(relative) }
        }
        let destination = videos.appendingPathComponent(assetID + ".mov"), thumbnail = thumbnails.appendingPathComponent(assetID + ".png")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: encoded)); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 960, height: 540)
        let image = try await generator.image(at: .zero).image
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw LumaError("Could not generate a lock screen preview.") }
        let newCatalog = try NativeCatalog.adding(assetID: assetID, title: title, video: destination, thumbnail: thumbnail, to: catalog)
        let encodedCatalog = try JSONSerialization.data(withJSONObject: newCatalog, options: [.sortedKeys])
        let backups = try Safety.child("NativeBackups/\(assetID)", under: library.root); try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let backupEntries = try Safety.child("entries.json", under: backups)
        let backupStateURL = try Safety.child("install-state.json", under: backups)
        guard try attributesIfPresent(backupEntries) == nil, try attributesIfPresent(backupStateURL) == nil else {
            throw LumaError("A native wallpaper backup already exists for this install. No files were overwritten.")
        }
        let installState = NativeInstallState(manifestExisted: existing,
                                             installedManifestSHA256: NativeCatalog.sha256(encodedCatalog),
                                             createdDirectories: createdDirectories)
        try installState.validate()
        let encodedState = try JSONEncoder().encode(installState)
        try original.write(to: backupEntries, options: .atomic)
        persistedBackupData["\(assetID)/entries.json"] = original
        try encodedState.write(to: backupStateURL, options: .atomic)
        persistedBackupData["\(assetID)/install-state.json"] = encodedState
        var published = false
        do {
            for (_, folder) in managedDirectories { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
            try fm.copyItem(at: encoded, to: destination); try png.write(to: thumbnail, options: .atomic)
            try Task.checkCancellation()
            if existing {
                guard try Data(contentsOf: manifest) == original else { throw LumaError("The native catalog changed during installation. Retry to preserve the latest system settings.") }
            } else if try attributesIfPresent(manifest) != nil {
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
        let previousInstall = try dataIfRegularFilePresent(installedBackup)
        let previousOriginal = try dataIfRegularFilePresent(backup)
        if previousInstall == data {
            guard previousOriginal != nil else { throw LumaError("The previous wallpaper selection backup is missing. Luma preserved the current system selection.") }
        } else {
            try data.write(to: backup, options: .atomic)
            persistedBackupData["selection-original.plist"] = data
        }
        let updated = try PropertyListSerialization.data(fromPropertyList: result, format: .binary, options: 0)
        // Record both sides before mutating the system selection, so a failed
        // backup write cannot leave an untracked wallpaper change.
        try updated.write(to: installedBackup, options: .atomic)
        persistedBackupData["selection-installed.plist"] = updated
        guard try Data(contentsOf: url) == data else { throw LumaError("Wallpaper settings changed. The newer selection was preserved.") }
        try updated.write(to: url, options: .atomic)
    }
    func removeInstalled() {
        guard !busy else { return }
        if root == nil { chooseRoot() }; guard let root else { return }
        let access = root.startAccessingSecurityScopedResource(); defer { if access { root.stopAccessingSecurityScopedResource() } }
        do { try validateForClearData(); try removeInstalledChanges(in: root, openSettingsAfterward: true) }
        catch { status = error.localizedDescription }
    }
    var clearDataPreflightError: String? {
        do { try validateForClearData(); return nil }
        catch { return error.localizedDescription }
    }
    func clearDataRestorePlan() -> [String] {
        if let issue = clearDataPreflightError {
            return ["Clear Data will abort before changing the native wallpaper catalog or lock-screen fallback because Luma could not verify its receipt, backup, or ownership marker: \(issue)"]
        }
        guard hasManagedChanges else { return [] }
        let paths = receipt.map { " Remove the recorded video and thumbnail from \(URL(fileURLWithPath: $0.videoPath).deletingLastPathComponent().path)." } ?? " Remove only the Luma-owned catalog entries and generated files recorded in Luma's backup folder."
        return ["Restore your previous macOS wallpaper selection if it still matches Luma's last change, and remove Luma's native wallpaper collection.", paths]
    }
    func validateForClearData() throws {
        guard !busy else { throw LumaError("Wait for the lock screen export to finish before clearing Luma data.") }
        try validateStaticFallbackForClearData()
        try verifyReceiptSnapshot()
        if let backupReadError { throw LumaError(backupReadError) }

        let backupRoot = try Safety.child("NativeBackups", under: library.root)
        let backupState = try validateBackupRecords(at: backupRoot)
        try verifyBackupSnapshots()
        guard receipt != nil || !backupState.ids.isEmpty || backupState.hasSelectionBackup else { return }
        guard let root else {
            throw LumaError("Luma's wallpaper folder is unavailable. Reconnect it before clearing data so Luma can restore its recorded changes.")
        }
        let access = root.startAccessingSecurityScopedResource(); defer { if access { root.stopAccessingSecurityScopedResource() } }
        try Safety.validateDirectoryIfPresent(root)
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw LumaError("Luma's selected wallpaper folder is unavailable or unsafe. No system wallpaper changes were made.")
        }
        let manifest = try Safety.child("aerials/manifest/entries.json", under: root)
        let assets: [[String: Any]]
        if let manifestAttributes = try attributesIfPresent(manifest) {
            guard manifestAttributes[.type] as? FileAttributeType == .typeRegular else {
                throw LumaError("The native wallpaper catalog is not a regular file. Luma preserved its receipt and backups.")
            }
            let bytes: Data
            do { bytes = try Data(contentsOf: manifest) }
            catch { throw LumaError("Could not read the native wallpaper catalog: \(error.localizedDescription)") }
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let parsedAssets = object["assets"] as? [[String: Any]], object["categories"] is [[String: Any]] else {
                throw LumaError("The native wallpaper catalog has an unsupported schema. Luma preserved its receipt and backups.")
            }
            assets = parsedAssets
        } else {
            // A missing catalog is safe to clean up: Luma can still remove its
            // generated files from the validated backup IDs, but it must not
            // recreate the catalog just to perform cleanup.
            assets = []
        }
        try validateSelectionBackups(at: backupRoot, root: root)
        if let receipt { try validate(receipt, wallpaperRoot: root) }
        let catalogIDs = assets.compactMap { asset -> String? in
            guard (asset["categories"] as? [String])?.contains(NativeCatalog.categoryID) == true,
                  let id = asset["id"] as? String, let uuid = UUID(uuidString: id) else { return nil }
            return uuid.uuidString
        }
        let generatedIDs = Set(backupState.ids + catalogIDs + (receipt.map { [$0.assetID] } ?? []))
        for id in generatedIDs {
            for relative in ["aerials/videos/\(id).mov", "aerials/thumbnails/\(id).png"] {
                let file = try Safety.child(relative, under: root)
                if let attributes = try attributesIfPresent(file), attributes[.type] as? FileAttributeType != .typeRegular {
                    throw LumaError("Generated native wallpaper file \(file.path) is not a regular file. It was left untouched.")
                }
            }
        }
    }
    func restoreManagedChangesForClearData() throws {
        guard !busy else { throw LumaError("Wait for the lock screen export to finish before clearing Luma data.") }
        try validateForClearData()
        guard hasManagedChanges else { return }
        guard let root else { throw LumaError("Luma's wallpaper folder is not available. Reconnect it before clearing data so Luma can restore your previous selection.") }
        let access = root.startAccessingSecurityScopedResource(); defer { if access { root.stopAccessingSecurityScopedResource() } }
        do { try removeInstalledChanges(in: root, openSettingsAfterward: false) }
        catch { status = "Could not restore Luma's native wallpaper changes: \(error.localizedDescription)"; throw error }
    }
    private func removeInstalledChanges(in root: URL, openSettingsAfterward: Bool) throws {
        try validateForClearData()
        let fm = FileManager.default
        try Safety.validateDirectoryIfPresent(root)
        let backupRoot = try Safety.child("NativeBackups", under: library.root)
        let selectionInstalled = backupRoot.appendingPathComponent("selection-installed.plist")
        let selectionOriginal = backupRoot.appendingPathComponent("selection-original.plist")
        let selectionInstalledData = try dataIfRegularFilePresent(selectionInstalled)
        let selectionOriginalData = try dataIfRegularFilePresent(selectionOriginal)
        let manifest = try Safety.child("aerials/manifest/entries.json", under: root)
        let currentManifestData = try dataIfRegularFilePresent(manifest)
        let original: [String: Any]?
        let owned: [[String: Any]]
        let ownsCategory: Bool
        if let currentManifestData {
            guard let object = try JSONSerialization.jsonObject(with: currentManifestData) as? [String: Any],
                  object["assets"] is [[String: Any]], let categories = object["categories"] as? [[String: Any]] else {
                throw LumaError("The native catalog schema is not recognized. No catalog records were removed.")
            }
            original = object
            owned = (object["assets"] as? [[String: Any]] ?? []).filter { ($0["categories"] as? [String])?.contains(NativeCatalog.categoryID) == true }
            ownsCategory = categories.contains { $0["id"] as? String == NativeCatalog.categoryID }
        } else {
            original = nil
            owned = []
            ownsCategory = false
        }
        let backupIDs = recordedAssetIDs
        let installStates = try loadInstallStates(at: backupRoot, ids: backupIDs)
        let shouldRestoreMissingManifest = currentManifestData.map { canRestoreAbsentManifest($0, installs: installStates) } ?? false
        let updated = original.map(NativeCatalog.removingOwned(from:))
        let store = try Safety.child("Store/Index.plist", under: root)
        // Recheck Luma's ownership records immediately before changing system
        // files. A stale backup must be detected before catalog or selection
        // restoration starts, so Clear Data does not create a partial restore.
        try verifyReceiptSnapshot()
        try verifyBackupSnapshots()
        if let currentManifestData {
            guard try dataIfRegularFilePresent(manifest) == currentManifestData else { throw LumaError("The catalog changed. Retry removal.") }
            if shouldRestoreMissingManifest {
                guard try dataIfRegularFilePresent(manifest) == currentManifestData,
                      canRestoreAbsentManifest(currentManifestData, installs: installStates) else {
                    throw LumaError("The native catalog changed. It was preserved.")
                }
                try fm.removeItem(at: manifest)
            } else if !owned.isEmpty || ownsCategory, let updated {
                try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys]).write(to: manifest, options: .atomic)
            }
        }
        // Restore a selection only when it still exactly matches our own write.
        // The catalog write happens first; if restoration then fails, the receipt
        // and selection backups remain so Clear Data can be retried safely.
        if let installed = selectionInstalledData,
           let current = try dataIfRegularFilePresent(store), current == installed,
           let backup = selectionOriginalData {
            try backup.write(to: store, options: .atomic)
        }
        // Per-install backups retain generated IDs so a retry can finish after
        // the catalog update without touching files owned by macOS or Steam.
        let ownedIDs = owned.compactMap { $0["id"] as? String }.filter { UUID(uuidString: $0) != nil }
        let receiptIDs = receipt.flatMap { UUID(uuidString: $0.assetID)?.uuidString }.map { [$0] } ?? []
        for id in Set(ownedIDs + backupIDs + receiptIDs) {
            for path in ["aerials/videos/\(id).mov", "aerials/thumbnails/\(id).png"] {
                let file = try Safety.child(path, under: root)
                try validateBackupFileIfPresent(file)
                if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
            }
        }
        let directoriesToRemove = Set(installStates.values.flatMap(\.createdDirectories))
            .sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
        for relative in directoriesToRemove {
            let directory = try Safety.child(relative, under: root)
            guard let attributes = try attributesIfPresent(directory) else { continue }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw LumaError("A directory Luma created is no longer a regular directory. It was left untouched.")
            }
            if try fm.contentsOfDirectory(atPath: directory.path).isEmpty { try fm.removeItem(at: directory) }
        }
        for id in backupIDs {
            let directory = backupRoot.appendingPathComponent(id, isDirectory: true)
            let snapshot = try Safety.child("entries.json", under: directory)
            let state = try Safety.child("install-state.json", under: directory)
            try removeBackedUpFileIfPresent(snapshot, key: "\(id)/entries.json")
            try removeBackedUpFileIfPresent(state, key: "\(id)/install-state.json")
            try removeBackupDirectoryIfEmpty(directory)
        }
        try removeBackedUpFileIfPresent(selectionInstalled, key: "selection-installed.plist")
        try removeBackedUpFileIfPresent(selectionOriginal, key: "selection-original.plist")
        try removeBackupDirectoryIfEmpty(backupRoot)
        let receiptFile = try Safety.child("native-receipt.json", under: library.root)
        try validateBackupFileIfPresent(receiptFile)
        if try attributesIfPresent(receiptFile) != nil { try fm.removeItem(at: receiptFile) }
        receipt = nil
        persistedReceiptData = nil
        persistedBackupData.removeAll()
        backupReadError = nil
        status = "Luma's native collection was removed."
        if openSettingsAfterward && opensSettings { openSettings() }
    }
    private func canRestoreAbsentManifest(_ current: Data, installs: [String: NativeInstallState]) -> Bool {
        // Each install snapshots the catalog it replaced. Follow exact hashes
        // back from the live manifest to the install that created it. Any gap
        // means another writer intervened (or recovery data is incomplete), so
        // retain the manifest and remove only Luma's catalog entries.
        let byDigest = Dictionary(grouping: installs, by: { $0.value.installedManifestSHA256 })
        var digest = NativeCatalog.sha256(current)
        var visited = Set<String>()
        for _ in installs.indices {
            guard let matches = byDigest[digest], matches.count == 1, let install = matches.first,
                  visited.insert(install.key).inserted else { return false }
            if !install.value.manifestExisted { return true }
            guard let original = persistedBackupData["\(install.key)/entries.json"] else { return false }
            digest = NativeCatalog.sha256(original)
        }
        return false
    }
    private func validateBackupDirectoryIfPresent(_ url: URL) throws {
        guard let attributes = try attributesIfPresent(url) else { return }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw LumaError("\(url.path) is not a Luma backup directory. It was left untouched.")
        }
    }
    private func validateBackupFileIfPresent(_ url: URL) throws {
        guard let attributes = try attributesIfPresent(url) else { return }
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
    private func dataIfRegularFilePresent(_ url: URL) throws -> Data? {
        guard let attributes = try attributesIfPresent(url) else { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw LumaError("\(url.path) is not a regular Luma backup file. It was left untouched.")
        }
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 64 * 1024 * 1024 else {
            throw LumaError("Luma backup file \(url.path) exceeds the 64 MiB safety limit.")
        }
        do { return try Data(contentsOf: url) }
        catch { throw LumaError("Could not read Luma backup file \(url.path): \(error.localizedDescription)") }
    }
    private func removeBackedUpFileIfPresent(_ url: URL, key: String) throws {
        guard let expected = persistedBackupData[key] else {
            if try dataIfRegularFilePresent(url) == nil { return }
            backupReadError = "A native backup appeared outside Luma while cleanup was running. The file was preserved."
            throw LumaError(backupReadError!)
        }
        guard let current = try dataIfRegularFilePresent(url), current == expected else {
            backupReadError = "A native backup changed outside Luma while cleanup was running. The newer file was preserved."
            throw LumaError(backupReadError!)
        }
        try FileManager.default.removeItem(at: url)
        persistedBackupData.removeValue(forKey: key)
    }
    private func validateBackupRecords(at backupRoot: URL) throws -> (ids: [String], hasSelectionBackup: Bool) {
        guard let attributes = try attributesIfPresent(backupRoot) else { return ([], false) }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw LumaError("\(backupRoot.path) is not a Luma backup directory. It was left untouched.")
        }
        let entries: [URL]
        do { entries = try FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil) }
        catch { throw LumaError("Could not inspect Luma native backups: \(error.localizedDescription)") }
        var ids: [String] = []
        var hasSelectionBackup = false
        for entry in entries {
            if let id = UUID(uuidString: entry.lastPathComponent), id.uuidString == entry.lastPathComponent {
                guard let directoryAttributes = try attributesIfPresent(entry),
                      directoryAttributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw LumaError("Luma native backup \(entry.lastPathComponent) is not a regular directory. It was left untouched.")
                }
                try Safety.validateProjectTree(entry)
                let snapshot = try Safety.child("entries.json", under: entry)
                let stateURL = try Safety.child("install-state.json", under: entry)
                let snapshotData = try dataIfRegularFilePresent(snapshot)
                let stateData = try dataIfRegularFilePresent(stateURL)
                if let snapshotData {
                    guard let object = try JSONSerialization.jsonObject(with: snapshotData) as? [String: Any],
                          object["assets"] is [[String: Any]], object["categories"] is [[String: Any]] else {
                        throw LumaError("Luma native backup \(entry.lastPathComponent) has an invalid catalog snapshot. Clear Data will preserve it.")
                    }
                }
                if let stateData {
                    do {
                        let state = try JSONDecoder().decode(NativeInstallState.self, from: stateData)
                        try state.validate()
                    } catch {
                        throw LumaError("Luma native backup \(entry.lastPathComponent) has invalid install state. Clear Data will preserve it.")
                    }
                }
                guard snapshotData != nil || stateData != nil else { continue }
                ids.append(id.uuidString)
            } else if ["selection-original.plist", "selection-installed.plist"].contains(entry.lastPathComponent) {
                guard let bytes = try dataIfRegularFilePresent(entry),
                      let propertyList = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else {
                    throw LumaError("A Luma native selection backup is invalid. Clear Data will preserve it.")
                }
                if entry.lastPathComponent == "selection-installed.plist" {
                    guard let originalData = try dataIfRegularFilePresent(backupRoot.appendingPathComponent("selection-original.plist")),
                          (try? PropertyListSerialization.propertyList(from: originalData, format: nil) as? [String: Any]) != nil else {
                        throw LumaError("Luma's installed selection backup has no valid original selection. Clear Data will preserve both records.")
                    }
                }
                _ = propertyList
                hasSelectionBackup = true
            }
        }
        return (ids, hasSelectionBackup)
    }
    private func loadInstallStates(at backupRoot: URL, ids: [String]) throws -> [String: NativeInstallState] {
        var result: [String: NativeInstallState] = [:]
        for id in ids {
            let directory = try Safety.child(id, under: backupRoot)
            let stateURL = try Safety.child("install-state.json", under: directory)
            guard let data = try dataIfRegularFilePresent(stateURL) else { continue }
            let state = try JSONDecoder().decode(NativeInstallState.self, from: data)
            try state.validate()
            result[id] = state
        }
        return result
    }
    private func loadBackupSnapshots() throws {
        persistedBackupData = try readBackupSnapshotData()
    }
    private func verifyBackupSnapshots() throws {
        if let backupReadError { throw LumaError(backupReadError) }
        let current = try readBackupSnapshotData()
        guard current == persistedBackupData else {
            backupReadError = "Luma's native wallpaper backup files changed outside the app. Reopen Luma before clearing data; the newer files were preserved."
            throw LumaError(backupReadError!)
        }
    }
    private func readBackupSnapshotData() throws -> [String: Data] {
        let backupRoot = try Safety.child("NativeBackups", under: library.root)
        _ = try validateBackupRecords(at: backupRoot)
        guard try attributesIfPresent(backupRoot) != nil else { return [:] }
        let entries = try FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)
        var result: [String: Data] = [:]
        for entry in entries {
            if let id = UUID(uuidString: entry.lastPathComponent), id.uuidString == entry.lastPathComponent {
                let snapshot = try Safety.child("entries.json", under: entry)
                if let data = try dataIfRegularFilePresent(snapshot) { result["\(id.uuidString)/entries.json"] = data }
                let state = try Safety.child("install-state.json", under: entry)
                if let data = try dataIfRegularFilePresent(state) { result["\(id.uuidString)/install-state.json"] = data }
            } else if ["selection-original.plist", "selection-installed.plist"].contains(entry.lastPathComponent),
                      let data = try dataIfRegularFilePresent(entry) {
                result[entry.lastPathComponent] = data
            }
        }
        return result
    }
    private func validateSelectionBackups(at backupRoot: URL, root: URL) throws {
        guard let installed = try dataIfRegularFilePresent(backupRoot.appendingPathComponent("selection-installed.plist")) else { return }
        let store = try Safety.child("Store/Index.plist", under: root)
        guard let current = try dataIfRegularFilePresent(store), current == installed else { return }
        guard let original = try dataIfRegularFilePresent(backupRoot.appendingPathComponent("selection-original.plist")),
              (try? PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any]) != nil else {
            throw LumaError("The current wallpaper selection is Luma's install, but its original selection backup is missing or invalid. No changes were made.")
        }
    }
    func resetForClearData() {
        root = nil; receipt = nil; staticFallbackURL = nil; staticFallbackSource = ""; selectAutomatically = false; sceneSeconds = 20; sceneMode = .automatic
        persistedReceiptData = nil; receiptReadError = nil
        persistedBackupData.removeAll(); backupReadError = nil
        UserDefaults.standard.removeObject(forKey: "luma.lockScreenFallback.source")
        status = "Install a prepared video into macOS's native wallpaper collection."
    }
    func cancel() { task?.cancel() }
    func openSettings() { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!) }
}

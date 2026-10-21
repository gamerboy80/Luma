import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

@MainActor final class LibraryStore: ObservableObject {
    @Published var state = SavedLibrary()
    @Published var error: String?
    @Published var activity: String?
    @Published var progress: Double = 0
    let root: URL
    var onChange: (() -> Void)?
    private var canSave = true
    private var persistedLibraryData: Data?
    private var persistedLibraryState: SavedLibrary?
    private static let maxLibraryBytes = 64 * 1024 * 1024
    private var downloadTask: Task<Void, Never>?
    private var activeImports = 0
    var hasDownloadInProgress: Bool { downloadTask != nil }
    var hasImportInProgress: Bool { activeImports > 0 }
    var managedWallpaperFolders: [URL] {
        state.wallpapers.compactMap { wallpaper in
            guard wallpaper.folder == wallpaper.id.uuidString else { return nil }
            return root.appendingPathComponent("Media", isDirectory: true).appendingPathComponent(wallpaper.folder, isDirectory: true)
        }
    }
    init(root: URL? = nil) {
        self.root = root ?? Self.preferredRoot(defaultRoot: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Luma", isDirectory: true), home: FileManager.default.homeDirectoryForCurrentUser)
        do {
            try Safety.validateDirectoryIfPresent(self.root)
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            let stateURL = try Safety.child("library.json", under: self.root)
            if FileManager.default.fileExists(atPath: stateURL.path) {
                do {
                    let data = try Self.readLibraryData(at: stateURL)
                    persistedLibraryData = data
                    var normalized = try JSONDecoder().decode(SavedLibrary.self, from: data)
                    normalized.preferences.normalizeForRuntime()
                    for key in normalized.displays.keys { normalized.displays[key]?.normalizeForRuntime() }
                    try validateLibrary(normalized)
                    state = normalized
                    persistedLibraryState = normalized
                }
                catch { canSave = false; self.error = "The library could not be read. The original file is preserved; use Reveal Library to recover it. \(error.localizedDescription)"; return }
            }
            for index in state.wallpapers.indices where state.wallpapers[index].kind == .scene && !state.wallpapers[index].scriptsApproved {
                state.wallpapers[index].trustedScripts = false
            }
            try installBuiltIns()
        } catch { canSave = false; self.error = error.localizedDescription }
    }
    static func preferredRoot(defaultRoot: URL, home: URL) -> URL {
        // Continue using this app's existing data when switching from its sandboxed
        // local build; imported videos and display assignments do not disappear.
        if FileManager.default.fileExists(atPath: defaultRoot.appendingPathComponent("library.json").path) { return defaultRoot }
        let previous = home.appendingPathComponent("Library/Containers/dev.patrick.Luma/Data/Library/Application Support/Luma", isDirectory: true)
        if previous.path != defaultRoot.path, FileManager.default.fileExists(atPath: previous.appendingPathComponent("library.json").path) { return previous }
        return defaultRoot
    }
    func folder(_ wallpaper: Wallpaper) -> URL { root.appendingPathComponent("Media", isDirectory: true).appendingPathComponent(wallpaper.id.uuidString, isDirectory: true) }
    func mediaURL(_ wallpaper: Wallpaper) throws -> URL {
        guard wallpaper.folder == wallpaper.id.uuidString else { throw LumaError("This wallpaper has an invalid managed folder record.") }
        let directory = try Safety.child("Media/\(wallpaper.id.uuidString)", under: root)
        return try Safety.child(wallpaper.entry, under: directory)
    }
    private func validateLibrary(_ value: SavedLibrary) throws {
        guard value.version == 1, Set(value.wallpapers.map(\.id)).count == value.wallpapers.count else { throw LumaError("The library version or wallpaper IDs are invalid.") }
        let preferences = value.preferences
        guard preferences.cpuThreshold.isFinite, (50...99).contains(preferences.cpuThreshold),
              preferences.playlistSeconds.isFinite, (60...86_400).contains(preferences.playlistSeconds),
              [24, 30, 60].contains(preferences.sceneFPS), (0...23).contains(preferences.dayHour),
              (0...23).contains(preferences.nightHour) else {
            throw LumaError("The library contains invalid playback settings. Luma will use safe defaults when loading them.")
        }
        for configuration in value.displays.values {
            guard configuration.volume.isFinite, (0...1).contains(configuration.volume),
                  configuration.speed.isFinite, (0.1...4).contains(configuration.speed),
                  configuration.scale.isFinite, (0.1...4).contains(configuration.scale),
                  configuration.offsetX.isFinite, abs(configuration.offsetX) <= 100_000,
                  configuration.offsetY.isFinite, abs(configuration.offsetY) <= 100_000 else {
                throw LumaError("The library contains invalid display settings.")
            }
        }
        for wallpaper in value.wallpapers {
            guard !wallpaper.title.isEmpty, wallpaper.title.utf8.count <= 4096,
                  wallpaper.duration.map({ $0.isFinite && $0 >= 0 && $0 <= 31_536_000 }) ?? true,
                  wallpaper.width.map({ $0 > 0 && $0 <= 65_535 }) ?? true,
                  wallpaper.height.map({ $0 > 0 && $0 <= 65_535 }) ?? true else {
                throw LumaError("The library contains invalid wallpaper metadata.")
            }
            _ = try mediaURL(wallpaper)
            if let preview = wallpaper.preview { _ = try Safety.child(preview, under: folder(wallpaper)) }
        }
    }
    @discardableResult func save(notify: Bool = true) -> Bool {
        guard canSave else { error = "The existing library is unreadable and was preserved. Recover or rename library.json before making changes."; return false }
        do {
            try Safety.validateDirectoryIfPresent(root)
            try validateLibrary(state)
            let file = try Safety.child("library.json", under: root)
            try validatePersistedLibraryFile(at: file)
            let data = try JSONEncoder().encode(state)
            try data.write(to: file, options: .atomic)
            persistedLibraryData = data
            persistedLibraryState = state
        }
        catch {
            if let persistedLibraryState { state = persistedLibraryState }
            self.error = "Could not save the library: \(error.localizedDescription)"
            return false
        }
        if notify { onChange?() }
        return true
    }
    @discardableResult func edit(_ id: UUID, _ update: (inout Wallpaper) -> Void) -> Bool {
        guard let i = state.wallpapers.firstIndex(where: { $0.id == id }) else { return false }
        update(&state.wallpapers[i])
        return save()
    }
    func remove(_ wallpaper: Wallpaper) {
        guard canSave, let stored = state.wallpapers.first(where: { $0.id == wallpaper.id }), !stored.isBuiltIn else { return }
        let managedFolder: URL
        do {
            guard stored.folder == stored.id.uuidString else { throw LumaError("The wallpaper's managed folder record is invalid. No files were removed.") }
            managedFolder = try Safety.child("Media/\(stored.id.uuidString)", under: root)
            try Safety.validateDirectoryIfPresent(managedFolder)
        } catch { self.error = error.localizedDescription; return }
        let previous = state
        state.displays = state.displays.mapValues { var c = $0; if c.wallpaperID == wallpaper.id { c.wallpaperID = nil }; return c }
        state.preferences.playlistIDs.removeAll { $0 == wallpaper.id }
        state.wallpapers.removeAll { $0.id == wallpaper.id }
        guard save() else { state = previous; return }
        do {
            if FileManager.default.fileExists(atPath: managedFolder.path) { try FileManager.default.removeItem(at: managedFolder) }
        } catch {
            state = previous
            let removalError = error.localizedDescription
            _ = save()
            self.error = "Could not remove the wallpaper; its library record was retained: \(removalError)"
        }
    }
    func chooseImport(folders: Bool = false) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = folders; panel.canChooseFiles = !folders; panel.allowsMultipleSelection = true
        panel.message = folders ? "Choose Wallpaper Engine project folders, or a parent folder containing them. Files are copied into Luma." : "Import a video, image, HTML wallpaper, or scene.pkg. Files stay on this Mac."
        if !folders { panel.allowedContentTypes = [.movie, .image, .html, .json, .data] }
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }
    func importURLs(_ urls: [URL]) {
        Task {
            activity = "Importing wallpapers…"; defer { activity = nil; progress = 0 }
            for (index, url) in urls.enumerated() {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                do { try await importURL(url) } catch { self.error = "\(url.lastPathComponent): \(error.localizedDescription)" }
                progress = Double(index + 1) / Double(urls.count)
            }
        }
    }
    func importURL(_ source: URL, workshopID: String? = nil, sourceDigest: String? = nil, titleOverride: String? = nil, safeSingleFileRoot: URL? = nil) async throws {
        try Task.checkCancellation()
        guard canSave else { throw LumaError("Recover the unreadable library before importing more wallpapers.") }
        activeImports += 1
        defer { activeImports -= 1 }
        let fm = FileManager.default
        let sourceValues = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard sourceValues.isSymbolicLink != true, sourceValues.isDirectory == true || sourceValues.isRegularFile == true else { throw LumaError("Choose a regular media file or real project folder, not a symbolic link or special file.") }
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &directory) else { throw LumaError("The selected file no longer exists.") }
        if directory.boolValue && !fm.fileExists(atPath: source.appendingPathComponent("project.json").path) {
            let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            let projects = children.filter { fm.fileExists(atPath: $0.appendingPathComponent("project.json").path) }
            guard !projects.isEmpty else { throw LumaError("No project.json files were found. Choose a Wallpaper Engine project folder.") }
            for child in projects { try await importURL(child, workshopID: child.lastPathComponent.range(of: "^[0-9]+$", options: .regularExpression) != nil ? child.lastPathComponent : nil) }
            return
        }
        let projectFolder = directory.boolValue ? source : source.deletingLastPathComponent()
        let isProject = directory.boolValue || source.lastPathComponent == "project.json"
        var object: [String: Any] = [:]
        if isProject { object = try JSONSerialization.jsonObject(with: Data(contentsOf: projectFolder.appendingPathComponent("project.json"))) as? [String: Any] ?? [:] }
        let ext = source.pathExtension.lowercased()
        let type = (object["type"] as? String)?.lowercased()
        let kind: WallpaperKind
        if isProject { guard let k = WallpaperKind(rawValue: type ?? "") else { throw LumaError("This project type is not supported. Application wallpapers cannot run on macOS.") }; kind = k }
        else if ["mp4","mov","m4v","webm"].contains(ext) { kind = .video }
        else if ["jpg","jpeg","png","heic","gif","webp"].contains(ext) { kind = .image }
        else if ["html","htm"].contains(ext) { kind = .web }
        else if ext == "pkg" { kind = .scene }
        else { throw LumaError("Choose a video, image, HTML page, scene.pkg, or project.json.") }
        let entry = object["file"] as? String ?? (isProject ? (kind == .scene ? "scene.pkg" : "index.html") : source.lastPathComponent)
        let id = UUID(); let destination = root.appendingPathComponent("Media/\(id.uuidString)", isDirectory: true)
        _ = try Safety.child("Media/\(id.uuidString)", under: root)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var importedDigest = sourceDigest
        do {
            if isProject {
                // Copy only regular files and directories; reject symlinks before copying.
                try validateTree(projectFolder)
                try fm.copyItem(at: projectFolder, to: destination)
            } else {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                let copiedFile = destination.appendingPathComponent(entry)
                if let safeRoot = safeSingleFileRoot {
                    importedDigest = try WallperVideosDiscoveryService.copyRegularFile(source, under: safeRoot, to: copiedFile)
                } else {
                    guard try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw LumaError("The selected file is a symbolic link. Copy its target into a normal file first.") }
                    try fm.copyItem(at: source, to: copiedFile)
                }
            }
            let target = try Safety.child(entry, under: destination)
            if kind == .scene && !fm.fileExists(atPath: target.path) && fm.fileExists(atPath: destination.appendingPathComponent("scene.pkg").path) { object["file"] = "scene.pkg" }
            else if !fm.fileExists(atPath: target.path) { throw LumaError("The declared wallpaper file is missing: \(entry)") }
            if !isProject {
                object = ["title": titleOverride ?? source.deletingPathExtension().lastPathComponent, "type": kind.rawValue, "file": entry]
            }
            try JSONSerialization.data(withJSONObject: object).write(to: destination.appendingPathComponent("project.json"), options: .atomic)
            var wallpaper = Wallpaper(id: id, title: object["title"] as? String ?? source.deletingPathExtension().lastPathComponent, kind: kind, folder: id.uuidString, entry: object["file"] as? String ?? entry, preview: object["preview"] as? String, tags: object["tags"] as? [String] ?? [], workshopID: workshopID)
            wallpaper.contentSHA256 = importedDigest
            if kind == .video {
                let asset = AVURLAsset(url: try Safety.child(wallpaper.entry, under: destination))
                guard try await asset.load(.isPlayable), let track = try await asset.loadTracks(withMediaType: .video).first else { throw LumaError("macOS cannot decode this video. Convert it to H.264 or HEVC MP4/MOV first.") }
                let size = try await track.load(.naturalSize)
                guard size.width.isFinite, size.height.isFinite, abs(size.width) >= 1, abs(size.height) >= 1,
                      abs(size.width) <= 65_535, abs(size.height) <= 65_535 else {
                    throw LumaError("The video reports invalid or unsupported frame dimensions.")
                }
                wallpaper.width = Int(abs(size.width)); wallpaper.height = Int(abs(size.height))
                let duration = try await asset.load(.duration).seconds
                wallpaper.duration = duration.isFinite && duration >= 0 ? duration : nil
                let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 900, height: 600)
                if let image = try? await generator.image(at: .zero).image { let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]); try data?.write(to: destination.appendingPathComponent("luma-preview.png")); wallpaper.preview = "luma-preview.png" }
            } else if kind == .image { wallpaper.preview = wallpaper.entry }
            try Task.checkCancellation()
            state.wallpapers.insert(wallpaper, at: 0)
            guard save() else {
                state.wallpapers.removeAll { $0.id == wallpaper.id }
                throw LumaError(error ?? "Luma could not save the imported wallpaper to its library.")
            }
        } catch { try? fm.removeItem(at: destination); throw error }
    }
    private struct ClearTargets {
        let mediaRoot: URL
        let wallpaperFolders: [URL]
        let libraryFile: URL
        let receiptFile: URL
        let nativeCacheRoot: URL
        let nativeCacheFolders: [URL]
    }

    var clearDataWallpaperCount: Int? {
        guard canSave else { return nil }
        do {
            try validateLibrary(state)
            let file = try Safety.child("library.json", under: root)
            try validateManagedFileIfPresent(file, fileManager: FileManager.default)
            try validatePersistedLibraryFile(at: file)
            return state.wallpapers.filter { !$0.isBuiltIn }.count
        } catch { return nil }
    }

    func validateForClearData() throws {
        _ = try clearTargets()
    }

    func resetForClearData() throws {
        let targets = try clearTargets()
        let fm = FileManager.default

        // A wallpaper folder is Luma-owned only when its name matches the UUID
        // stored in the validated library. Preserve all unknown entries.
        for folder in targets.wallpaperFolders where fm.fileExists(atPath: folder.path) {
            try fm.removeItem(at: folder)
        }
        for folder in targets.nativeCacheFolders where fm.fileExists(atPath: folder.path) {
            try fm.removeItem(at: folder)
        }
        for file in [targets.libraryFile, targets.receiptFile] where fm.fileExists(atPath: file.path) {
            try fm.removeItem(at: file)
        }
        try removeDirectoryIfEmpty(targets.mediaRoot, fileManager: fm)
        try removeDirectoryIfEmpty(targets.nativeCacheRoot, fileManager: fm)
        try removeDirectoryIfEmpty(root, fileManager: fm)
        // Clear Data terminates the app after cleanup. Do not recreate the
        // library or built-in wallpaper assets during the shutdown path.
        state = SavedLibrary(); canSave = false; error = nil; activity = nil; progress = 0
    }

    private func clearTargets() throws -> ClearTargets {
        guard !hasImportInProgress, !hasDownloadInProgress else { throw LumaError("Wait for wallpaper imports and downloads to finish before clearing Luma data.") }
        guard canSave else { throw LumaError("Recover the unreadable library before clearing its data so Luma can identify its owned files safely.") }
        let fm = FileManager.default
        try Safety.validateDirectoryIfPresent(root)
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw LumaError("The Luma data folder is not a normal directory. It was left untouched to protect other files.")
        }
        try validateLibrary(state)

        let mediaRoot = try Safety.child("Media", under: root)
        try validateManagedDirectoryIfPresent(mediaRoot, fileManager: fm)
        let wallpaperFolders = try state.wallpapers.map { wallpaper -> URL in
            let folder = try Safety.child("Media/\(wallpaper.id.uuidString)", under: root)
            try validateManagedDirectoryIfPresent(folder, fileManager: fm)
            if fm.fileExists(atPath: folder.path) { try Safety.validateProjectTree(folder) }
            return folder
        }

        let libraryFile = try Safety.child("library.json", under: root)
        let receiptFile = try Safety.child("native-receipt.json", under: root)
        try validateManagedFileIfPresent(libraryFile, fileManager: fm)
        try validateManagedFileIfPresent(receiptFile, fileManager: fm)
        try validatePersistedLibraryFile(at: libraryFile)

        let nativeCacheRoot = try Safety.child("NativeCache", under: root)
        let nativeCacheFolders = try ownedNativeCacheFolders(at: nativeCacheRoot, fileManager: fm)
        return ClearTargets(mediaRoot: mediaRoot, wallpaperFolders: wallpaperFolders,
                            libraryFile: libraryFile, receiptFile: receiptFile,
                            nativeCacheRoot: nativeCacheRoot, nativeCacheFolders: nativeCacheFolders)
    }

    private func validatePersistedLibraryFile(at url: URL) throws {
        let current: Data?
        do { current = try Self.readLibraryData(at: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { current = nil }
        catch {
            let message = "Luma could not verify the current library file. It was preserved to avoid overwriting newer data: \(error.localizedDescription)"
            self.error = message
            throw LumaError(message)
        }
        guard current == persistedLibraryData else {
            canSave = false
            let message = "The library changed outside Luma after it was loaded. The newer file was preserved; reopen Luma before editing or clearing data."
            self.error = message
            throw LumaError(message)
        }
    }

    private static func readLibraryData(at url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue >= 0, size.intValue <= maxLibraryBytes else {
            throw LumaError("The library file is not a regular file within Luma's 64 MiB limit. It was preserved.")
        }
        return try Data(contentsOf: url)
    }

    private func validateManagedDirectoryIfPresent(_ url: URL, fileManager fm: FileManager) throws {
        guard let attributes = try attributesIfPresent(url, fileManager: fm) else { return }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw LumaError("\(url.path) is not a Luma-managed directory. It was left untouched.")
        }
    }
    private func validateManagedFileIfPresent(_ url: URL, fileManager fm: FileManager) throws {
        guard let attributes = try attributesIfPresent(url, fileManager: fm) else { return }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw LumaError("\(url.path) is not a regular Luma file. It was left untouched.")
        }
    }
    private func attributesIfPresent(_ url: URL, fileManager fm: FileManager) throws -> [FileAttributeKey: Any]? {
        do { return try fm.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        catch { throw LumaError("Could not inspect managed path \(url.path): \(error.localizedDescription)") }
    }
    private func removeDirectoryIfEmpty(_ url: URL, fileManager fm: FileManager) throws {
        guard fm.fileExists(atPath: url.path) else { return }
        let contents = try fm.contentsOfDirectory(atPath: url.path)
        if contents.isEmpty { try fm.removeItem(at: url) }
    }
    private func ownedNativeCacheFolders(at cacheRoot: URL, fileManager fm: FileManager) throws -> [URL] {
        try validateManagedDirectoryIfPresent(cacheRoot, fileManager: fm)
        guard fm.fileExists(atPath: cacheRoot.path) else { return [] }
        var owned: [URL] = []
        for child in try fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            guard UUID(uuidString: child.lastPathComponent)?.uuidString == child.lastPathComponent,
                  let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let marker = child.appendingPathComponent(".luma-owned")
            guard let markerValues = try? marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  markerValues.isRegularFile == true, markerValues.isSymbolicLink != true,
                  (try? String(contentsOf: marker, encoding: .utf8)) == "Luma NativeCache v1" else { continue }
            try Safety.validateProjectTree(child)
            owned.append(child)
        }
        return owned
    }
    private func validateTree(_ root: URL) throws {
        try Safety.validateProjectTree(root)
    }
    func download(_ string: String) {
        guard downloadTask == nil else { return }
        guard let url = URL(string: string), url.scheme == "https", url.host != nil else { error = "Enter a direct HTTPS video URL."; return }
        downloadTask = Task {
            activity = "Downloading \(url.lastPathComponent)…"; progress = 0
            defer { activity = nil; progress = 0; downloadTask = nil }
            let temporary = root.appendingPathComponent("download-\(UUID().uuidString).\(url.pathExtension.isEmpty ? "mp4" : url.pathExtension)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                let delegate = DownloadProgress { amount in Task { @MainActor in self.progress = amount } }
                let (file, response) = try await URLSession.shared.download(from: url, delegate: delegate)
                guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw LumaError("The server refused the download.") }
                try Task.checkCancellation(); try FileManager.default.moveItem(at: file, to: temporary)
                try await importURL(temporary, titleOverride: url.deletingPathExtension().lastPathComponent)
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func cancelDownload() { downloadTask?.cancel() }
    private func installBuiltIns() throws {
        for (name, hue) in [("Aurora Drift", 165), ("Midnight Current", 245), ("Ember Field", 22)] {
            guard !state.wallpapers.contains(where: { $0.isBuiltIn && $0.title == name }) else { continue }
            guard let template = Bundle.main.url(forResource: "ambient", withExtension: "html") else { continue }
            let id = UUID(); let dir = try Safety.child("Media/\(id.uuidString)", under: root)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let html = try String(contentsOf: template, encoding: .utf8).replacingOccurrences(of: "LUMA_HUE", with: String(hue))
            try html.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
            try Data(Safety.json(["title": name,"type":"web","file":"index.html"]).utf8).write(to: dir.appendingPathComponent("project.json"))
            state.wallpapers.append(Wallpaper(id: id, title: name, kind: .web, folder: id.uuidString, entry: "index.html", tags: ["Abstract", "Luma Originals"], trustedScripts: true, isBuiltIn: true))
        }
        guard save(notify: false) else { throw LumaError(error ?? "Luma could not save the library.") }
    }
}
final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Double) -> Void
    init(update: @escaping @Sendable (Double) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { if totalBytesExpectedToWrite > 0 { update(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) } }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

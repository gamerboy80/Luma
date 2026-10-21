import AppKit
import Combine
import Darwin
import Foundation

struct EditorProject: Identifiable, Codable, Hashable {
    var id: UUID
    var folderName: String
    var title: String
    var entry: String
    var lastOpened: Date?
    var scriptApprovalFingerprint: String?
    var scriptsEnabled: Bool
    var scriptsApproved: Bool { scriptApprovalFingerprint != nil }

    func previewWallpaper() -> Wallpaper {
        Wallpaper(id: id, title: title, kind: .scene, folder: folderName, entry: entry,
                  trustedScripts: scriptsEnabled, scriptApprovalFingerprint: scriptApprovalFingerprint)
    }
}

@MainActor final class EditorProjectStore: ObservableObject {
    @Published private(set) var projects: [EditorProject] = []
    @Published private(set) var recentProjectIDs: [UUID] = []
    private let base: URL
    private let indexURL: URL
    private var loadError: String?
    private var persistedIndexData: Data?
    let library: LibraryStore

    init(library: LibraryStore) {
        self.library = library
        base = library.root.appendingPathComponent("EditorProjects", isDirectory: true)
        indexURL = base.appendingPathComponent("projects.json")
        do {
            _ = try Safety.child("EditorProjects", under: library.root)
            if FileManager.default.fileExists(atPath: base.path) {
                let values = try base.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw LumaError("The editor project folder is not a safe Luma directory.") }
            }
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            if let data = try readIndexData() {
                persistedIndexData = data
                let index = try JSONDecoder().decode(EditorProjectIndex.self, from: data)
                projects = index.projects
                recentProjectIDs = index.recentProjectIDs
            }
            try validateIndex()
        } catch {
            loadError = error.localizedDescription
            projects = []; recentProjectIDs = []
            library.error = "Editor projects could not be loaded. The original index was preserved; recover it before editing: \(error.localizedDescription)"
        }
    }

    func create(title: String = "Untitled Scene") throws -> EditorProject {
        try requireWritable()
        let previousProjects = projects, previousRecents = recentProjectIDs
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120 else { throw LumaError("Use a project name between 1 and 120 characters.") }
        let id = UUID(), folderName = id.uuidString
        let folder = base.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            let scene: [String: Any] = ["general": ["clearcolor": "0.035 0.045 0.065", "orthogonalprojection": ["width": 1920, "height": 1080]], "objects": []]
            let project: [String: Any] = ["title": title, "type": "scene", "file": "scene.pkg"]
            try JSONSerialization.data(withJSONObject: project, options: [.sortedKeys, .fragmentsAllowed]).write(to: folder.appendingPathComponent("project.json"), options: .atomic)
            try SceneProjectPackage(entries: [SceneProjectPackage.Entry(name: "scene.json", bytes: JSONSerialization.data(withJSONObject: scene, options: [.sortedKeys, .fragmentsAllowed]))]).encoded().write(to: folder.appendingPathComponent("scene.pkg"), options: .atomic)
            let item = EditorProject(id: id, folderName: folderName, title: title, entry: "scene.pkg", lastOpened: Date(), scriptApprovalFingerprint: nil, scriptsEnabled: false)
            projects.insert(item, at: 0); markRecent(item.id); try persist(); return item
        } catch { projects = previousProjects; recentProjectIDs = previousRecents; try? FileManager.default.removeItem(at: folder); throw error }
    }

    func importProject(_ source: URL) throws -> EditorProject {
        try requireWritable()
        let previousProjects = projects, previousRecents = recentProjectIDs
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else { throw LumaError("The selected project no longer exists.") }
        let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard sourceValues.isSymbolicLink != true,
              (isDirectory.boolValue ? sourceValues.isDirectory == true : sourceValues.isRegularFile == true) else {
            throw LumaError("Choose a regular scene file or a real project folder. Symbolic links are not imported.")
        }
        let id = UUID(), folderName = id.uuidString, destination = base.appendingPathComponent(folderName, isDirectory: true)
        do {
            if isDirectory.boolValue {
                try Self.validateTree(source)
                try fm.copyItem(at: source, to: destination)
            } else {
                guard source.pathExtension.lowercased() == "pkg" || source.lastPathComponent.lowercased() == "scene.json" else { throw LumaError("Choose a scene.pkg, scene.json, or complete project folder.") }
                try fm.createDirectory(at: destination, withIntermediateDirectories: false)
                let entry = source.lastPathComponent.lowercased() == "scene.json" ? source.lastPathComponent : "scene.pkg"
                try fm.copyItem(at: source, to: destination.appendingPathComponent(entry))
                let project: [String: Any] = ["title": source.deletingPathExtension().lastPathComponent, "type": "scene", "file": entry]
                try JSONSerialization.data(withJSONObject: project, options: [.sortedKeys]).write(to: destination.appendingPathComponent("project.json"), options: .atomic)
            }
            let document = try SceneProjectDocument(folder: destination)
            let item = EditorProject(id: id, folderName: folderName, title: document.title, entry: document.entry, lastOpened: Date(), scriptApprovalFingerprint: nil, scriptsEnabled: false)
            projects.insert(item, at: 0); markRecent(id); try persist(); return item
        } catch { projects = previousProjects; recentProjectIDs = previousRecents; try? fm.removeItem(at: destination); throw error }
    }

    func duplicate(_ id: UUID) throws -> EditorProject {
        try requireWritable()
        let previousProjects = projects, previousRecents = recentProjectIDs
        guard let original = projects.first(where: { $0.id == id }) else { throw LumaError("This editor project is no longer in the project list.") }
        let newID = UUID(), folderName = newID.uuidString, destination = base.appendingPathComponent(folderName, isDirectory: true)
        let source = folder(for: original)
        try Self.validateTree(source)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            let copy = try SceneProjectDocument(folder: destination)
            copy.title = "\(original.title) Copy"; try copy.save()
            let item = EditorProject(id: newID, folderName: folderName, title: copy.title, entry: copy.entry, lastOpened: Date(), scriptApprovalFingerprint: nil, scriptsEnabled: false)
            projects.insert(item, at: 0); markRecent(newID); try persist(); return item
        } catch { projects = previousProjects; recentProjectIDs = previousRecents; try? FileManager.default.removeItem(at: destination); throw error }
    }

    func rename(_ id: UUID, to rawTitle: String) throws {
        try requireWritable()
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120 else { throw LumaError("Use a project name between 1 and 120 characters.") }
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw LumaError("This editor project is no longer in the project list.") }
        let previousProjects = projects, previousRecents = recentProjectIDs
        let document = try SceneProjectDocument(folder: folder(for: projects[index]))
        projects[index].title = title
        projects[index].scriptApprovalFingerprint = nil
        projects[index].scriptsEnabled = false
        do { try persist() }
        catch { projects = previousProjects; recentProjectIDs = previousRecents; throw error }
        document.title = title
        do {
            try document.save()
        } catch {
            let saveError = error.localizedDescription
            do { try restoreStoreSnapshot(projects: previousProjects, recents: previousRecents) }
            catch { throw LumaError("The project rename failed: \(saveError). Restoring its index also failed: \(error.localizedDescription). Reopen the project list and review its title.") }
            throw error
        }
    }

    func restoreStoreSnapshot(projects: [EditorProject], recents: [UUID]) throws {
        self.projects = projects
        self.recentProjectIDs = recents
        do { try persist() }
        catch {
            let message = "The editor project index could not be rolled back: \(error.localizedDescription). Reopen Luma and inspect the project list before editing."
            loadError = message
            throw LumaError(message)
        }
    }

    func update(_ id: UUID, _ change: (inout EditorProject) -> Void) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw LumaError("This editor project is no longer in the project list.") }
        try requireWritable()
        let previous = projects[index]
        change(&projects[index])
        do { try persist() } catch { projects[index] = previous; throw error }
    }

    func opened(_ id: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let previousProjects = projects, previousRecents = recentProjectIDs
        projects[index].lastOpened = Date(); markRecent(id)
        do { try persist() } catch {
            projects = previousProjects; recentProjectIDs = previousRecents
            library.error = "Could not save recent projects: \(error.localizedDescription)"
        }
    }

    func export(_ id: UUID, to parent: URL) throws -> URL {
        try requireWritable()
        guard let project = projects.first(where: { $0.id == id }) else { throw LumaError("This editor project is no longer in the project list.") }
        let source = folder(for: project)
        try Self.validateTree(source)
        let safeName = project.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var destination = parent.appendingPathComponent(safeName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) { destination = parent.appendingPathComponent("\(safeName) \(suffix)", isDirectory: true); suffix += 1 }
        let sourcePath = source.resolvingSymlinksInPath().path
        let destinationPath = destination.resolvingSymlinksInPath().path
        guard destinationPath != sourcePath, !destinationPath.hasPrefix(sourcePath + "/") else { throw LumaError("Export to a folder outside this project to avoid copying it into itself.") }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            _ = try SceneProjectDocument(folder: destination); return destination
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }

    var clearDataProjectCount: Int? { try? clearOwnership().count }

    func validateManagedProjectsForClear() throws {
        _ = try validatedProjectFoldersForClear()
    }

    func clearManagedProjects() throws {
        let ownedFolders = try validatedProjectFoldersForClear()

        for folder in ownedFolders where FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        if FileManager.default.fileExists(atPath: indexURL.path) { try FileManager.default.removeItem(at: indexURL) }
        if FileManager.default.fileExists(atPath: base.path), (try FileManager.default.contentsOfDirectory(atPath: base.path)).isEmpty {
            try FileManager.default.removeItem(at: base)
        }
        projects = []; recentProjectIDs = []
        persistedIndexData = nil
        loadError = "Luma data was cleared. Relaunch Luma to create new projects."
    }

    private func validatedProjectFoldersForClear() throws -> [URL] {
        let ownership = try clearOwnership()
        return try ownership.map { project -> URL in
            let folder = try Safety.child(project.folderName, under: base)
            if FileManager.default.fileExists(atPath: folder.path) { try Self.validateTree(folder) }
            return folder
        }
    }

    private func clearOwnership() throws -> [EditorProject] {
        // Clear Data must be retryable after a prior partial cleanup. The
        // project index remains the ownership record even when a referenced
        // project folder is missing or its document is malformed, so validate
        // the index and its UUID paths directly instead of requiring a fully
        // loadable editor store.
        try Safety.validateDirectoryIfPresent(library.root)
        _ = try Safety.child("EditorProjects", under: library.root)
        try Safety.validateDirectoryIfPresent(base)
        if FileManager.default.fileExists(atPath: base.path) {
            let values = try base.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw LumaError("The editor project folder is not a safe Luma directory. It was left untouched.") }
        }

        let ownership: [EditorProject]
        if let data = try verifyIndexSnapshot(allowMissingForClear: true) {
            let index = try JSONDecoder().decode(EditorProjectIndex.self, from: data)
            let ids = Set(index.projects.map(\.id))
            guard index.projects.count <= 10_000, ids.count == index.projects.count else {
                throw LumaError("The editor project index has duplicate IDs or too many entries. It was preserved because ownership is unclear.")
            }
            ownership = index.projects
        } else {
            // If this live store loaded successfully, its in-memory list came
            // from the last valid index. If loading failed, there is no safe
            // ownership data to use when the index is gone.
            guard loadError == nil else { throw LumaError("The editor project index is unreadable or missing. It was preserved because Luma cannot safely identify its owned project folders.") }
            ownership = projects
        }

        for project in ownership {
            guard project.folderName == project.id.uuidString else { throw LumaError("An editor project has an unsafe ownership record. Nothing was removed.") }
        }
        return ownership
    }

    private func requireWritable() throws {
        if let loadError { throw LumaError(loadError) }
        try Safety.validateDirectoryIfPresent(library.root)
        _ = try Safety.child("EditorProjects", under: library.root)
        try Safety.validateDirectoryIfPresent(base)
        _ = try verifyIndexSnapshot()
    }

    private func readIndexData() throws -> Data? {
        let safeIndexURL = try Safety.child("projects.json", under: base)
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: safeIndexURL.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 16 * 1024 * 1024 else {
            throw LumaError("The editor project index is not a regular file within the 16 MiB limit. It was preserved.")
        }
        return try Data(contentsOf: safeIndexURL)
    }

    private func verifyIndexSnapshot(allowMissingForClear: Bool = false) throws -> Data? {
        let current = try readIndexData()
        // A partial cleanup can remove the index before an empty-directory
        // removal fails. Its already-loaded UUID ownership remains sufficient
        // for retrying cleanup, but must never recreate the missing index.
        guard current == persistedIndexData || (allowMissingForClear && current == nil && loadError == nil) else {
            throw LumaError("The editor project index changed outside Luma. Reopen Luma before editing or clearing data; the newer file was preserved.")
        }
        return current
    }

    private func markRecent(_ id: UUID) { recentProjectIDs.removeAll { $0 == id }; recentProjectIDs.insert(id, at: 0); if recentProjectIDs.count > 20 { recentProjectIDs = Array(recentProjectIDs.prefix(20)) } }
    func folder(for project: EditorProject) -> URL { base.appendingPathComponent(project.folderName, isDirectory: true) }
    private func persist() throws {
        try requireWritable()
        let data = try JSONEncoder().encode(EditorProjectIndex(projects: projects, recentProjectIDs: recentProjectIDs))
        guard data.count <= 16 * 1024 * 1024 else { throw LumaError("The editor project index exceeds the 16 MiB limit.") }
        try data.write(to: indexURL, options: .atomic)
        persistedIndexData = data
    }
    private func validateIndex() throws {
        let ids = Set(projects.map(\.id))
        guard ids.count == projects.count, projects.count <= 10_000 else { throw LumaError("The editor project list contains duplicate IDs or too many entries.") }
        for project in projects {
            guard project.folderName == project.id.uuidString else { throw LumaError("An editor project folder name is invalid.") }
            let folder = try Safety.child(project.folderName, under: base)
            _ = try SceneProjectDocument(folder: folder)
        }
        recentProjectIDs = recentProjectIDs.filter { ids.contains($0) }
    }

    static func validateTree(_ root: URL) throws {
        try Safety.validateProjectTree(root)
    }

}

private struct EditorProjectIndex: Codable { var projects: [EditorProject]; var recentProjectIDs: [UUID] }

struct SceneProjectPackage {
    struct Entry { var name: String; var bytes: Data }
    var magic = "PKGV0012"
    var entries: [Entry]

    init(data: Data) throws {
        var cursor = 0
        func read32() throws -> Int {
            guard cursor <= data.count - 4 else { throw LumaError("The scene package header is truncated.") }
            let value = data[cursor..<cursor+4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
            cursor += 4; return Int(value)
        }
        func readString(_ size: Int) throws -> String {
            guard size > 0, size <= 4096, cursor <= data.count - size else { throw LumaError("The scene package contains an invalid entry name.") }
            defer { cursor += size }; return String(decoding: data[cursor..<cursor+size], as: UTF8.self)
        }
        let headerLength = try read32(); magic = try readString(headerLength)
        guard magic.hasPrefix("PKGV"), magic.utf8.count == 8 else { throw LumaError("Unknown scene package format.") }
        let count = try read32(); guard count <= 100_000 else { throw LumaError("The scene package has too many entries.") }
        var table: [(String, Int, Int)] = []; table.reserveCapacity(count)
        for _ in 0..<count {
            let name = try readString(read32()); let offset = try read32(); let size = try read32()
            _ = try Safety.child(name, under: URL(fileURLWithPath: "/scene"))
            table.append((name, offset, size))
        }
        let payloadStart = cursor
        entries = try table.map { name, offset, size in
            guard offset <= data.count - payloadStart, size <= data.count - payloadStart - offset else { throw LumaError("A scene package entry extends beyond its data.") }
            return Entry(name: name, bytes: Data(data[(payloadStart + offset)..<(payloadStart + offset + size)]))
        }
    }

    init(entries: [Entry]) { self.entries = entries }
    func encoded() throws -> Data {
        guard magic.utf8.count == 8, entries.count <= 100_000 else { throw LumaError("This scene package cannot be written safely.") }
        var table = Data(), payload = Data()
        func append32(_ value: Int, to data: inout Data) throws {
            guard value >= 0, value <= Int(UInt32.max) else { throw LumaError("A scene package entry is too large.") }
            var n = UInt32(value).littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) }
        }
        for entry in entries {
            _ = try Safety.child(entry.name, under: URL(fileURLWithPath: "/scene"))
            try append32(entry.name.utf8.count, to: &table); table.append(Data(entry.name.utf8))
            try append32(payload.count, to: &table); try append32(entry.bytes.count, to: &table); payload.append(entry.bytes)
        }
        var result = Data(); try append32(magic.utf8.count, to: &result); result.append(Data(magic.utf8)); try append32(entries.count, to: &result); result.append(table); result.append(payload); return result
    }
}

@MainActor final class SceneProjectDocument: ObservableObject {
    let folder: URL
    private(set) var entry: String
    @Published var title: String
    @Published private(set) var scene: [String: Any]
    private var package: SceneProjectPackage?
    private var sceneEntryName: String?
    private var originalEntryBytes = Data()
    private var originalProjectBytes = Data()
    private var isLooseScene = false
    private var undoStack: [Data] = []
    private var redoStack: [Data] = []
    private var undoBytes = 0
    private var redoBytes = 0
    private static let maxHistoryBytes = 128 * 1024 * 1024
    private let metadataWriter: (Data, URL) throws -> Void

    init(folder: URL, metadataWriter: @escaping (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .atomic) }) throws {
        self.folder = folder
        self.metadataWriter = metadataWriter
        try EditorProjectStore.validateTree(folder)
        let projectURL = try Safety.child("project.json", under: folder)
        let projectAttributes = try FileManager.default.attributesOfItem(atPath: projectURL.path)
        guard projectAttributes[.type] as? FileAttributeType == .typeRegular,
              let projectSize = projectAttributes[.size] as? NSNumber,
              projectSize.intValue >= 0, projectSize.intValue <= 8 * 1024 * 1024 else {
            throw LumaError("project.json is not a regular project file within the 8 MiB editor limit.")
        }
        let projectData = try Data(contentsOf: projectURL)
        guard projectData.count <= 8 * 1024 * 1024,
              let project = try JSONSerialization.jsonObject(with: projectData) as? [String: Any],
              (project["type"] as? String)?.lowercased() == "scene",
              let file = project["file"] as? String else { throw LumaError("This editor supports Wallpaper Engine scene projects with a valid project.json.") }
        entry = file; title = project["title"] as? String ?? folder.lastPathComponent
        let fileURL = try Safety.child(file, under: folder)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard fileAttributes[.type] as? FileAttributeType == .typeRegular,
              let fileSize = fileAttributes[.size] as? NSNumber,
              fileSize.intValue >= 0, fileSize.intValue <= 2 * 1024 * 1024 * 1024 else {
            throw LumaError("The scene entry is not a regular file within the 2 GiB editor limit.")
        }
        guard try !Self.sameFile(fileURL, projectURL) else {
            throw LumaError("The scene entry points to project.json. This project is malformed and cannot be edited safely.")
        }
        originalProjectBytes = projectData
        originalEntryBytes = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        if fileURL.pathExtension.lowercased() == "pkg" {
            let parsed = try SceneProjectPackage(data: originalEntryBytes)
            guard let sceneFile = parsed.entries.first(where: { $0.name.lowercased() == "scene.json" }) ?? parsed.entries.first(where: { $0.name.lowercased().hasSuffix("/scene.json") }) else { throw LumaError("This scene package has no scene.json document to edit.") }
            package = parsed; sceneEntryName = sceneFile.name
            scene = try Self.decodeScene(sceneFile.bytes)
        } else if fileURL.pathExtension.lowercased() == "json" {
            isLooseScene = true; sceneEntryName = file
            scene = try Self.decodeScene(originalEntryBytes)
        } else { throw LumaError("This scene entry cannot be edited. Choose a scene.pkg or scene.json project.") }
        try Self.validateScene(scene)
    }

    var objects: [[String: Any]] { scene["objects"] as? [[String: Any]] ?? scene["layers"] as? [[String: Any]] ?? [] }
    var canEditLayers: Bool { scene["objects"] is [Any] || scene["layers"] is [Any] }
    var resolution: (Int, Int) {
        let general = scene["general"] as? [String: Any] ?? [:]
        let projection = general["orthogonalprojection"] as? [String: Any] ?? [:]
        return (max(1, (projection["width"] as? NSNumber)?.intValue ?? 1920), max(1, (projection["height"] as? NSNumber)?.intValue ?? 1080))
    }

    func layerID(at index: Int) -> String {
        guard objects.indices.contains(index) else { return "" }
        let object = objects[index]
        if let id = object["id"] { return String(describing: id) }
        return "index:\(index)"
    }

    func updateLayer(at index: Int, key: String, value: Any) throws {
        guard objects.indices.contains(index), key.range(of: "^[A-Za-z][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil,
              JSONSerialization.isValidJSONObject(["value": value]) else { throw LumaError("The layer change is invalid.") }
        var all = objects, layer = all[index]; layer[key] = value; all[index] = layer
        try commitLayers(all)
    }

    func renameLayer(at index: Int, to value: String) throws { try updateLayer(at: index, key: "name", value: String(value.prefix(120))) }
    func setVisibility(at index: Int, visible: Bool) throws { try updateLayer(at: index, key: "visible", value: visible) }
    func setLocked(at index: Int, locked: Bool) throws { try updateLayer(at: index, key: "locked", value: locked) }
    func reorderLayer(from source: Int, to destination: Int) throws {
        var all = objects; guard all.indices.contains(source), destination >= 0, destination < all.count else { throw LumaError("The selected layer position is invalid.") }
        let value = all.remove(at: source); all.insert(value, at: destination)
        try commitLayers(all)
    }
    func duplicateLayer(at index: Int) throws {
        var all = objects; guard all.indices.contains(index), all.count < 5000 else { throw LumaError("This scene cannot contain another layer.") }
        var copy = all[index]
        if copy["id"] is NSNumber { copy["id"] = try nextLayerID() }
        else if let id = copy["id"] as? String { copy["id"] = "\(id)-copy-\(UUID().uuidString.prefix(8))" }
        copy["name"] = "\(copy["name"] as? String ?? "Layer") Copy"
        all.insert(copy, at: index + 1)
        try commitLayers(all)
    }
    func deleteLayer(at index: Int) throws {
        var all = objects; guard all.indices.contains(index) else { throw LumaError("The selected layer no longer exists.") }
        all.remove(at: index)
        try commitLayers(all)
    }
    func addTextLayer() throws {
        var all = objects; guard all.count < 5000 else { throw LumaError("This scene has reached its layer limit.") }
        let (width, height) = resolution, nextID = try nextLayerID()
        all.append(["id": nextID, "name": "Text", "text": "New Text", "font": "systemfont_arial", "pointsize": 64,
                    "origin": "\(width / 2) \(height / 2) 0", "scale": "1 1 1", "angles": "0 0 0", "size": "800 160",
                    "color": "1 1 1", "horizontalalign": "center", "verticalalign": "center", "anchor": "none", "visible": true])
        try commitLayers(all)
    }
    func replaceLayer(at index: Int, with value: [String: Any]) throws {
        guard objects.indices.contains(index), JSONSerialization.isValidJSONObject(value),
              (try JSONSerialization.data(withJSONObject: value)).count <= 1024 * 1024 else { throw LumaError("The layer JSON is invalid or too large.") }
        var all = objects; all[index] = value
        try commitLayers(all)
    }
    func updateGeneral(_ value: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(value), (try JSONSerialization.data(withJSONObject: value)).count <= 1024 * 1024 else { throw LumaError("Scene settings JSON is invalid or too large.") }
        var candidate = scene; candidate["general"] = value
        try Self.validateScene(candidate)
        try checkpoint(); scene = candidate
    }
    func transformLayers(indices: Set<Int>, dx: Double = 0, dy: Double = 0, widthDelta: Double = 0, heightDelta: Double = 0, rotationDelta: Double = 0, snapToGrid: Bool) throws {
        guard dx.isFinite, dy.isFinite, widthDelta.isFinite, heightDelta.isFinite, rotationDelta.isFinite,
              !indices.isEmpty, indices.allSatisfy({ objects.indices.contains($0) }) else { throw LumaError("The selected layer transform is invalid.") }
        let editableIndices = indices.filter { objects[$0]["locked"] as? Bool != true }
        guard !editableIndices.isEmpty else { throw LumaError("Unlock the selected layer before changing its transform.") }
        var all = objects
        func vector(_ value: Any?) -> [Double]? {
            if let string = value as? String {
                let values = string.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).compactMap { Double($0) }
                return values.count >= 2 ? values : nil
            }
            if let values = value as? [NSNumber], values.count >= 2 { return values.map(\.doubleValue) }
            return nil
        }
        func encoded(_ values: [Double], original: Any) -> Any {
            if original is [NSNumber] { return values }
            return values.map { String(format: "%.4f", $0).replacingOccurrences(of: "\\.0+$", with: "", options: .regularExpression) }.joined(separator: " ")
        }
        for index in editableIndices {
            var layer = all[index]
            if var origin = vector(layer["origin"]) {
                origin[0] += dx; origin[1] += dy
                if snapToGrid { origin[0] = (origin[0] / 16).rounded() * 16; origin[1] = (origin[1] / 16).rounded() * 16 }
                layer["origin"] = encoded(origin, original: layer["origin"]!)
            }
            if widthDelta != 0 || heightDelta != 0, var size = vector(layer["size"]) {
                size[0] = max(1, size[0] + widthDelta); size[1] = max(1, size[1] + heightDelta)
                layer["size"] = encoded(size, original: layer["size"]!)
            }
            if rotationDelta != 0, var angles = vector(layer["angles"]) {
                while angles.count < 3 { angles.append(0) }; angles[2] += rotationDelta
                layer["angles"] = encoded(angles, original: layer["angles"]!)
            }
            all[index] = layer
        }
        try commitLayers(all)
    }
    private func nextLayerID() throws -> Int {
        let maximum = objects.compactMap { ($0["id"] as? NSNumber)?.doubleValue }.max() ?? 0
        guard maximum.isFinite, maximum < 9_007_199_254_740_991 else { throw LumaError("The scene's numeric layer IDs are exhausted. Use a smaller ID before adding or duplicating a layer.") }
        return Int(max(0, maximum)) + 1
    }
    private func commitLayers(_ layers: [[String: Any]]) throws {
        var candidate = scene
        candidate[scene["objects"] != nil ? "objects" : "layers"] = layers
        try Self.validateScene(candidate)
        try checkpoint(); scene = candidate
    }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var retainedHistoryBytes: Int { undoBytes + redoBytes }
    func undo() throws {
        guard let prior = undoStack.last else { return }
        let restored = try Self.decodeScene(prior)
        let current = try JSONSerialization.data(withJSONObject: scene, options: [.fragmentsAllowed])
        undoStack.removeLast(); undoBytes -= prior.count
        redoStack.append(current); redoBytes += current.count
        scene = restored
        trimHistory()
    }
    func redo() throws {
        guard let next = redoStack.last else { return }
        let restored = try Self.decodeScene(next)
        let current = try JSONSerialization.data(withJSONObject: scene, options: [.fragmentsAllowed])
        redoStack.removeLast(); redoBytes -= next.count
        undoStack.append(current); undoBytes += current.count
        scene = restored
        trimHistory()
    }
    private func checkpoint() throws {
        let snapshot = try JSONSerialization.data(withJSONObject: scene, options: [.fragmentsAllowed])
        guard snapshot.count <= Self.maxHistoryBytes else { throw LumaError("This scene snapshot exceeds the editor's 128 MiB undo limit.") }
        undoStack.append(snapshot); undoBytes += snapshot.count
        redoStack.removeAll(); redoBytes = 0
        while undoStack.count > 100 { undoBytes -= undoStack.removeFirst().count }
        trimHistory()
    }
    private func trimHistory() {
        while undoBytes + redoBytes > Self.maxHistoryBytes {
            // Drop the oldest retained state first. The stack's last element is
            // the next state needed for undo/redo, so its first element is the
            // least useful one to retain.
            if !undoStack.isEmpty { undoBytes -= undoStack.removeFirst().count }
            else if !redoStack.isEmpty { redoBytes -= redoStack.removeFirst().count }
            else { break }
        }
    }
    func save() throws {
        try Self.validateScene(scene)
        let sceneURL = try Safety.child(entry, under: folder)
        guard try Data(contentsOf: sceneURL, options: .mappedIfSafe) == originalEntryBytes else {
            throw LumaError("The scene file changed outside this editor. Reopen the project before saving to preserve those changes.")
        }
        let projectURL = try Safety.child("project.json", under: folder)
        guard try !Self.sameFile(sceneURL, projectURL) else {
            throw LumaError("The scene entry aliases project.json. Reopen a valid project before saving.")
        }
        let currentProjectBytes = try Data(contentsOf: projectURL, options: .mappedIfSafe)
        guard currentProjectBytes == originalProjectBytes else {
            throw LumaError("The project metadata changed outside this editor. Reopen the project before saving to preserve those changes.")
        }
        guard var project = try JSONSerialization.jsonObject(with: currentProjectBytes) as? [String: Any],
              (project["type"] as? String)?.lowercased() == "scene", project["file"] as? String == entry else {
            throw LumaError("The project entry or type no longer matches the opened scene. Reopen the project before saving.")
        }
        project["title"] = title
        let encodedProject = try JSONSerialization.data(withJSONObject: project, options: [.sortedKeys, .fragmentsAllowed])
        let encodedScene = try JSONSerialization.data(withJSONObject: scene, options: [.sortedKeys, .fragmentsAllowed])
        let sceneBytesToWrite: Data
        if let package, let sceneEntryName {
            var updated = package
            guard let index = updated.entries.firstIndex(where: { $0.name == sceneEntryName }) else { throw LumaError("The scene package changed since it was opened.") }
            updated.entries[index].bytes = encodedScene
            sceneBytesToWrite = try updated.encoded()
            _ = try SceneProjectPackage(data: sceneBytesToWrite)
        } else if isLooseScene, let sceneEntryName {
            sceneBytesToWrite = encodedScene
            guard try Safety.child(sceneEntryName, under: folder).standardizedFileURL == sceneURL.standardizedFileURL else {
                throw LumaError("The loose scene entry changed. Reopen the project before saving.")
            }
        } else {
            throw LumaError("This project has no editable scene entry.")
        }

        // Both files are staged in memory and revalidated before either write.
        // If the second atomic replacement fails, restore the original scene
        // bytes so a reported failure never leaves a half-saved project.
        try sceneBytesToWrite.write(to: sceneURL, options: .atomic)
        do {
            guard try Data(contentsOf: projectURL, options: .mappedIfSafe) == originalProjectBytes else {
                throw LumaError("The project metadata changed while saving. The scene file will be restored.")
            }
            guard try Data(contentsOf: sceneURL, options: .mappedIfSafe) == sceneBytesToWrite else {
                throw LumaError("The scene file changed while saving. Reopen the project before continuing.")
            }
            try metadataWriter(encodedProject, projectURL)
        } catch {
            guard (try? Data(contentsOf: sceneURL, options: .mappedIfSafe)) == sceneBytesToWrite else {
                throw LumaError("The project metadata could not be saved, and the scene file changed concurrently. Luma preserved the newer scene file; reopen the project before continuing.")
            }
            do { try originalEntryBytes.write(to: sceneURL, options: .atomic) }
            catch {
                throw LumaError("Project metadata could not be saved, and restoring the scene file also failed: \(error.localizedDescription). Reopen the project and inspect both files before continuing.")
            }
            throw error
        }
        originalEntryBytes = sceneBytesToWrite
        originalProjectBytes = encodedProject
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) throws -> Bool {
        var left = stat(), right = stat()
        let leftResult = lhs.path.withCString { Darwin.lstat($0, &left) }
        let rightResult = rhs.path.withCString { Darwin.lstat($0, &right) }
        guard leftResult == 0, rightResult == 0 else {
            throw LumaError("Could not verify the project and scene file identities: \(String(cString: strerror(Darwin.errno))).")
        }
        return left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    private static func decodeScene(_ data: Data) throws -> [String: Any] {
        guard data.count <= 64 * 1024 * 1024 else { throw LumaError("The scene document exceeds the editor's 64 MB limit.") }
        guard let result = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else { throw LumaError("The scene JSON root must be an object.") }
        return result
    }
    private static func validateScene(_ scene: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(scene), let encoded = try? JSONSerialization.data(withJSONObject: scene), encoded.count <= 64 * 1024 * 1024 else { throw LumaError("The scene document is invalid or exceeds 64 MB.") }
        for key in ["objects", "layers"] where scene[key] != nil {
            guard let layers = scene[key] as? [[String: Any]], layers.count <= 5000 else { throw LumaError("The scene contains too many or malformed \(key).") }
            var ids = Set<String>()
            for layer in layers {
                guard let id = layer["id"] else { continue }
                guard id is String || id is NSNumber else { throw LumaError("Layer IDs must be strings or numbers.") }
                let text = String(describing: id)
                guard !text.isEmpty, text.utf8.count <= 128, ids.insert(text).inserted else { throw LumaError("Layer IDs must be unique and at most 128 bytes.") }
            }
        }
    }
}

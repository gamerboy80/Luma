import AppKit
import Combine
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
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let values = try indexURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LumaError("The editor project index is not a regular Luma file.") }
            }
            if let data = try? Data(contentsOf: indexURL) {
                let index = try JSONDecoder().decode(EditorProjectIndex.self, from: data)
                projects = index.projects
                recentProjectIDs = index.recentProjectIDs
            }
            try validateIndex()
        } catch { library.error = "Editor projects could not be loaded: \(error.localizedDescription)" }
    }

    func create(title: String = "Untitled Scene") throws -> EditorProject {
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
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }

    func importProject(_ source: URL) throws -> EditorProject {
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
        } catch { try? fm.removeItem(at: destination); throw error }
    }

    func duplicate(_ id: UUID) throws -> EditorProject {
        guard let original = projects.first(where: { $0.id == id }) else { throw LumaError("This editor project is no longer in the project list.") }
        let newID = UUID(), folderName = newID.uuidString, destination = base.appendingPathComponent(folderName, isDirectory: true)
        let source = folder(for: original)
        try Self.validateTree(source); try FileManager.default.copyItem(at: source, to: destination)
        do {
            let copy = try SceneProjectDocument(folder: destination)
            copy.title = "\(original.title) Copy"; try copy.save()
            let item = EditorProject(id: newID, folderName: folderName, title: copy.title, entry: copy.entry, lastOpened: Date(), scriptApprovalFingerprint: nil, scriptsEnabled: false)
            projects.insert(item, at: 0); markRecent(newID); try persist(); return item
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }

    func rename(_ id: UUID, to rawTitle: String) throws {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120 else { throw LumaError("Use a project name between 1 and 120 characters.") }
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw LumaError("This editor project is no longer in the project list.") }
        let document = try SceneProjectDocument(folder: folder(for: projects[index]))
        document.title = title; try document.save()
        projects[index].title = title
        projects[index].scriptApprovalFingerprint = nil
        projects[index].scriptsEnabled = false
        try persist()
    }

    func update(_ id: UUID, _ change: (inout EditorProject) -> Void) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw LumaError("This editor project is no longer in the project list.") }
        change(&projects[index]); try persist()
    }

    func opened(_ id: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].lastOpened = Date(); markRecent(id); try? persist()
    }

    func export(_ id: UUID, to parent: URL) throws -> URL {
        guard let project = projects.first(where: { $0.id == id }) else { throw LumaError("This editor project is no longer in the project list.") }
        let source = folder(for: project)
        try Self.validateTree(source)
        let safeName = project.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var destination = parent.appendingPathComponent(safeName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) { destination = parent.appendingPathComponent("\(safeName) \(suffix)", isDirectory: true); suffix += 1 }
        try FileManager.default.copyItem(at: source, to: destination)
        do { _ = try SceneProjectDocument(folder: destination); return destination }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
    }

    func clearManagedProjects() throws {
        if FileManager.default.fileExists(atPath: base.path) {
            let values = try base.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw LumaError("The editor project folder is not a safe Luma directory. It was left untouched.") }
        }
        let ownedFolders = try projects.map { project -> URL in
            guard project.folderName == project.id.uuidString else { throw LumaError("An editor project has an unsafe ownership record. Nothing was removed.") }
            let folder = try Safety.child(project.folderName, under: base)
            if FileManager.default.fileExists(atPath: folder.path) { try Self.validateTree(folder) }
            return folder
        }
        if FileManager.default.fileExists(atPath: indexURL.path) {
            let values = try indexURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LumaError("The editor project index is not a regular Luma file. It was left untouched.") }
        }
        for folder in ownedFolders where FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        if FileManager.default.fileExists(atPath: indexURL.path) { try FileManager.default.removeItem(at: indexURL) }
        if FileManager.default.fileExists(atPath: base.path), (try FileManager.default.contentsOfDirectory(atPath: base.path)).isEmpty {
            try FileManager.default.removeItem(at: base)
        }
        projects = []; recentProjectIDs = []
    }

    private func markRecent(_ id: UUID) { recentProjectIDs.removeAll { $0 == id }; recentProjectIDs.insert(id, at: 0); if recentProjectIDs.count > 20 { recentProjectIDs = Array(recentProjectIDs.prefix(20)) } }
    func folder(for project: EditorProject) -> URL { base.appendingPathComponent(project.folderName, isDirectory: true) }
    private func persist() throws { try JSONEncoder().encode(EditorProjectIndex(projects: projects, recentProjectIDs: recentProjectIDs)).write(to: indexURL, options: .atomic) }
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
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw LumaError("The project root must be a real directory, not a symbolic link.") }
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { throw LumaError("Cannot read the selected project folder.") }
        var count = 0
        for case let url as URL in e {
            count += 1; guard count <= 100_000 else { throw LumaError("This project contains too many files.") }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw LumaError("The project contains a symbolic link. Copy its target into the project first.") }
            let relative = String(url.path.dropFirst(root.path.count + 1)); _ = try Safety.child(relative, under: root)
        }
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
    private var isLooseScene = false
    private var undoStack: [Data] = []
    private var redoStack: [Data] = []

    init(folder: URL) throws {
        self.folder = folder
        try EditorProjectStore.validateTree(folder)
        let projectURL = try Safety.child("project.json", under: folder)
        let projectData = try Data(contentsOf: projectURL)
        guard projectData.count <= 8 * 1024 * 1024,
              let project = try JSONSerialization.jsonObject(with: projectData) as? [String: Any],
              (project["type"] as? String)?.lowercased() == "scene",
              let file = project["file"] as? String else { throw LumaError("This editor supports Wallpaper Engine scene projects with a valid project.json.") }
        entry = file; title = project["title"] as? String ?? folder.lastPathComponent
        let fileURL = try Safety.child(file, under: folder)
        if fileURL.pathExtension.lowercased() == "pkg" {
            let parsed = try SceneProjectPackage(data: Data(contentsOf: fileURL, options: .mappedIfSafe))
            guard let sceneFile = parsed.entries.first(where: { $0.name.lowercased() == "scene.json" }) ?? parsed.entries.first(where: { $0.name.lowercased().hasSuffix("/scene.json") }) else { throw LumaError("This scene package has no scene.json document to edit.") }
            package = parsed; sceneEntryName = sceneFile.name
            scene = try Self.decodeScene(sceneFile.bytes)
        } else if fileURL.pathExtension.lowercased() == "json" {
            isLooseScene = true; sceneEntryName = file
            scene = try Self.decodeScene(Data(contentsOf: fileURL))
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
        try checkpoint()
        var all = objects, layer = all[index]; layer[key] = value; all[index] = layer
        if scene["objects"] is [Any] { scene["objects"] = all } else { scene["layers"] = all }
        try Self.validateScene(scene)
    }

    func renameLayer(at index: Int, to value: String) throws { try updateLayer(at: index, key: "name", value: String(value.prefix(120))) }
    func setVisibility(at index: Int, visible: Bool) throws { try updateLayer(at: index, key: "visible", value: visible) }
    func setLocked(at index: Int, locked: Bool) throws { try updateLayer(at: index, key: "locked", value: locked) }
    func reorderLayer(from source: Int, to destination: Int) throws {
        var all = objects; guard all.indices.contains(source), destination >= 0, destination < all.count else { throw LumaError("The selected layer position is invalid.") }
        try checkpoint()
        let value = all.remove(at: source); all.insert(value, at: destination)
        if scene["objects"] is [Any] { scene["objects"] = all } else { scene["layers"] = all }
    }
    func duplicateLayer(at index: Int) throws {
        var all = objects; guard all.indices.contains(index), all.count < 5000 else { throw LumaError("This scene cannot contain another layer.") }
        try checkpoint()
        var copy = all[index]
        if let id = copy["id"] as? NSNumber { copy["id"] = max((all.compactMap { ($0["id"] as? NSNumber)?.intValue }.max() ?? 0) + 1, id.intValue + 1) }
        else if let id = copy["id"] as? String { copy["id"] = "\(id)-copy-\(UUID().uuidString.prefix(8))" }
        copy["name"] = "\(copy["name"] as? String ?? "Layer") Copy"
        all.insert(copy, at: index + 1)
        if scene["objects"] is [Any] { scene["objects"] = all } else { scene["layers"] = all }
    }
    func deleteLayer(at index: Int) throws {
        var all = objects; guard all.indices.contains(index) else { throw LumaError("The selected layer no longer exists.") }
        try checkpoint()
        all.remove(at: index)
        if scene["objects"] is [Any] { scene["objects"] = all } else { scene["layers"] = all }
    }
    func addTextLayer() throws {
        var all = objects; guard all.count < 5000 else { throw LumaError("This scene has reached its layer limit.") }
        try checkpoint()
        let (width, height) = resolution, nextID = (all.compactMap { ($0["id"] as? NSNumber)?.intValue }.max() ?? 0) + 1
        all.append(["id": nextID, "name": "Text", "text": "New Text", "font": "systemfont_arial", "pointsize": 64,
                    "origin": "\(width / 2) \(height / 2) 0", "scale": "1 1 1", "angles": "0 0 0", "size": "800 160",
                    "color": "1 1 1", "horizontalalign": "center", "verticalalign": "center", "anchor": "none", "visible": true])
        if scene["objects"] is [Any] { scene["objects"] = all } else { scene["layers"] = all }
    }
    func replaceLayer(at index: Int, with value: [String: Any]) throws {
        guard objects.indices.contains(index), JSONSerialization.isValidJSONObject(value),
              (try JSONSerialization.data(withJSONObject: value)).count <= 1024 * 1024 else { throw LumaError("The layer JSON is invalid or too large.") }
        try checkpoint()
        var all = objects; all[index] = value
        if scene["objects"] is [Any] { scene["objects"] = all } else { scene["layers"] = all }
    }
    func updateGeneral(_ value: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(value), (try JSONSerialization.data(withJSONObject: value)).count <= 1024 * 1024 else { throw LumaError("Scene settings JSON is invalid or too large.") }
        try checkpoint(); scene["general"] = value
    }
    func transformLayers(indices: Set<Int>, dx: Double = 0, dy: Double = 0, widthDelta: Double = 0, heightDelta: Double = 0, rotationDelta: Double = 0, snapToGrid: Bool) throws {
        guard dx.isFinite, dy.isFinite, widthDelta.isFinite, heightDelta.isFinite, rotationDelta.isFinite,
              !indices.isEmpty, indices.allSatisfy({ objects.indices.contains($0) }) else { throw LumaError("The selected layer transform is invalid.") }
        let editableIndices = indices.filter { objects[$0]["locked"] as? Bool != true }
        guard !editableIndices.isEmpty else { throw LumaError("Unlock the selected layer before changing its transform.") }
        try checkpoint()
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
        if scene["objects"] is [Any] { scene["objects"] = all } else { scene["layers"] = all }
    }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    func undo() throws {
        guard let prior = undoStack.popLast() else { return }
        redoStack.append(try JSONSerialization.data(withJSONObject: scene, options: [.fragmentsAllowed]))
        scene = try Self.decodeScene(prior)
    }
    func redo() throws {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(try JSONSerialization.data(withJSONObject: scene, options: [.fragmentsAllowed]))
        scene = try Self.decodeScene(next)
    }
    private func checkpoint() throws {
        undoStack.append(try JSONSerialization.data(withJSONObject: scene, options: [.fragmentsAllowed]))
        if undoStack.count > 100 { undoStack.removeFirst(undoStack.count - 100) }
        redoStack.removeAll()
    }
    func save() throws {
        try Self.validateScene(scene)
        let encodedScene = try JSONSerialization.data(withJSONObject: scene, options: [.sortedKeys, .fragmentsAllowed])
        if let package, let sceneEntryName {
            var updated = package
            guard let index = updated.entries.firstIndex(where: { $0.name == sceneEntryName }) else { throw LumaError("The scene package changed since it was opened.") }
            updated.entries[index].bytes = encodedScene
            let pkgURL = try Safety.child(entry, under: folder)
            let bytes = try updated.encoded()
            _ = try SceneProjectPackage(data: bytes)
            try bytes.write(to: pkgURL, options: .atomic)
        } else if isLooseScene, let sceneEntryName {
            try encodedScene.write(to: Safety.child(sceneEntryName, under: folder), options: .atomic)
        }
        let projectURL = try Safety.child("project.json", under: folder)
        var project = try JSONSerialization.jsonObject(with: Data(contentsOf: projectURL)) as? [String: Any] ?? [:]
        project["title"] = title
        try JSONSerialization.data(withJSONObject: project, options: [.sortedKeys, .fragmentsAllowed]).write(to: projectURL, options: .atomic)
    }

    private static func decodeScene(_ data: Data) throws -> [String: Any] {
        guard data.count <= 64 * 1024 * 1024 else { throw LumaError("The scene document exceeds the editor's 64 MB limit.") }
        guard let result = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else { throw LumaError("The scene JSON root must be an object.") }
        return result
    }
    private static func validateScene(_ scene: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(scene), let encoded = try? JSONSerialization.data(withJSONObject: scene), encoded.count <= 64 * 1024 * 1024 else { throw LumaError("The scene document is invalid or exceeds 64 MB.") }
        if let objects = scene["objects"] as? [Any] { guard objects.count <= 5000, objects.allSatisfy({ $0 is [String: Any] }) else { throw LumaError("The scene contains too many or malformed object layers.") } }
        if let layers = scene["layers"] as? [Any] { guard layers.count <= 5000, layers.allSatisfy({ $0 is [String: Any] }) else { throw LumaError("The scene contains too many or malformed layers.") } }
    }
}

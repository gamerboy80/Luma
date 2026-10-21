import Foundation
import AppKit

@main struct EditorTests {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            guard value() else { throw LumaError("EDITOR TEST FAILED: \(message)") }
        }
        func rejects(_ operation: () throws -> Void, _ message: String) throws {
            do { try operation() } catch { checks += 1; return }
            throw LumaError("EDITOR TEST FAILED: accepted \(message)")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LumaEditorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root.appendingPathComponent("Library", isDirectory: true))
        let store = EditorProjectStore(library: library)
        let project = try store.create(title: "Round Trip")
        try expect(store.projects.count == 1, "create project registers it")
        try expect(store.recentProjectIDs.first == project.id, "open project is recent")

        let projectFolder = store.folder(for: project)
        let packageURL = projectFolder.appendingPathComponent(project.entry)
        var package = try SceneProjectPackage(data: Data(contentsOf: packageURL))
        let unknownPayload = Data([3, 1, 4, 1, 5, 9])
        package.entries.append(.init(name: "plugins/custom.bin", bytes: unknownPayload))
        try package.encoded().write(to: packageURL, options: .atomic)

        let document = try SceneProjectDocument(folder: projectFolder)
        try document.addTextLayer()
        try document.renameLayer(at: 0, to: "Editable Text")
        try document.setLocked(at: 0, locked: true)
        try rejects({ try document.transformLayers(indices: [0], dx: 16, snapToGrid: false) }, "locked layer transform")
        try document.setLocked(at: 0, locked: false)
        try document.transformLayers(indices: [0], dx: 32, dy: -16, snapToGrid: false)
        try expect(document.canUndo, "editing adds undo history")
        let movedOrigin = document.objects[0]["origin"] as? String ?? ""
        try expect(movedOrigin.contains("992"), "move updates the x origin")
        try document.undo()
        try expect((document.objects[0]["origin"] as? String)?.contains("960") == true, "undo restores previous transform")
        try document.redo()
        try expect(document.objects[0]["origin"] as? String == movedOrigin, "redo restores moved transform")

        try document.setVisibility(at: 0, visible: false)
        try expect(document.objects[0]["visible"] as? Bool == false, "visibility edits update the scene layer")
        try document.duplicateLayer(at: 0)
        try expect(document.objects.count == 2, "layer duplicate inserts a copy")
        try expect(document.layerID(at: 0) != document.layerID(at: 1), "duplicate receives a distinct layer ID")
        try document.reorderLayer(from: 1, to: 0)
        try expect(document.objects.count == 2, "layer reorder preserves both layers")
        try document.deleteLayer(at: 0)
        try expect(document.objects.count == 1, "layer delete removes the selected layer")

        try document.updateGeneral(["clearcolor": "0 0 0", "unknownSetting": ["keep": true]])
        try document.save()
        let reloaded = try SceneProjectDocument(folder: projectFolder)
        try expect(reloaded.objects.count == 1, "save reloads layer data")
        try expect(reloaded.objects[0]["name"] as? String == "Editable Text", "layer fields persist")
        try expect((reloaded.scene["general"] as? [String: Any])?["unknownSetting"] != nil, "unknown scene JSON fields survive edits")
        let roundTripPackage = try SceneProjectPackage(data: Data(contentsOf: packageURL))
        try expect(roundTripPackage.entries.first(where: { $0.name == "plugins/custom.bin" })?.bytes == unknownPayload, "unknown PKGV entries survive saves")
        let externalEditDocument = try SceneProjectDocument(folder: projectFolder)
        var externalPackage = roundTripPackage
        externalPackage.entries.append(.init(name: "external/change.bin", bytes: Data([42])))
        let externalBytes = try externalPackage.encoded()
        try externalBytes.write(to: packageURL, options: .atomic)
        try rejects({ try externalEditDocument.save() }, "saving over an external scene edit")
        let preservedExternalBytes = try Data(contentsOf: packageURL)
        try expect(preservedExternalBytes == externalBytes, "external package edits are preserved")
        try roundTripPackage.encoded().write(to: packageURL, options: .atomic)

        var duplicate = try store.duplicate(project.id)
        try expect(duplicate.title == "Round Trip Copy", "duplicate project receives a new title")
        try expect(!duplicate.scriptsApproved && !duplicate.scriptsEnabled, "duplicate does not inherit script approval")
        try store.update(duplicate.id) { $0.scriptApprovalFingerprint = "stale-review"; $0.scriptsEnabled = true }
        try store.rename(duplicate.id, to: "Renamed Project")
        duplicate = store.projects.first { $0.id == duplicate.id }!
        try expect(duplicate.title == "Renamed Project", "rename updates the project browser index")
        try expect(!duplicate.scriptsApproved && !duplicate.scriptsEnabled, "rename revokes approval after changing reviewed JSON")
        let exportRoot = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let exported = try store.export(duplicate.id, to: exportRoot)
        _ = try SceneProjectDocument(folder: exported)
        try expect(FileManager.default.fileExists(atPath: exported.appendingPathComponent("scene.pkg").path), "export includes the playback package")

        let restoredStore = EditorProjectStore(library: LibraryStore(root: library.root))
        try expect(restoredStore.projects.count == 2, "project index reloads persisted projects")
        try expect(restoredStore.recentProjectIDs.first == duplicate.id, "recent order reloads")

        func maliciousPackage() -> Data {
            var data = Data()
            func number(_ value: Int) { var n = UInt32(value).littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
            let name = "../outside.json", payload = Data("{}".utf8)
            number(8); data.append(Data("PKGV0012".utf8)); number(1)
            number(name.utf8.count); data.append(Data(name.utf8)); number(0); number(payload.count); data.append(payload)
            return data
        }
        try rejects({ _ = try SceneProjectPackage(data: maliciousPackage()) }, "PKGV path traversal")
        let unsafeFolder = root.appendingPathComponent("unsafe", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: unsafeFolder.appendingPathComponent("link"), withDestinationURL: root)
        try rejects({ _ = try store.importProject(unsafeFolder) }, "project with a symbolic link")
        let unsafeRoot = root.appendingPathComponent("unsafe-root")
        try FileManager.default.createSymbolicLink(at: unsafeRoot, withDestinationURL: projectFolder)
        try rejects({ _ = try store.importProject(unsafeRoot) }, "symbolic-link project root")
        try rejects({ _ = try store.export(project.id, to: projectFolder) }, "exporting a project into itself")
        let beforeInvalidLayer = document.objects[0]
        try rejects({ try document.replaceLayer(at: 0, with: ["id": ["invalid": true]]) }, "invalid layer ID")
        try expect(NSDictionary(dictionary: document.objects[0]).isEqual(to: beforeInvalidLayer), "rejected layer edits leave the document unchanged")
        try document.replaceLayer(at: 0, with: ["id": Int.max, "text": "large ID"])
        try rejects({ try document.duplicateLayer(at: 0) }, "overflowing numeric layer ID")
        try expect(document.objects.count == 1, "failed duplication does not mutate the scene")

        // A failed index write must roll back the in-memory project/recents list.
        let indexURL = library.root.appendingPathComponent("EditorProjects/projects.json")
        let originalIndex = try Data(contentsOf: indexURL)
        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: false)
        let projectCount = store.projects.count, recents = store.recentProjectIDs
        try rejects({ _ = try store.create(title: "Failed Save") }, "index save failure")
        try expect(store.projects.count == projectCount && store.recentProjectIDs == recents, "failed index save rolls back project and recent entries")
        try FileManager.default.removeItem(at: indexURL)
        try originalIndex.write(to: indexURL)

        let corruptBytes = Data("{invalid json".utf8)
        try corruptBytes.write(to: indexURL)
        let corruptStore = EditorProjectStore(library: library)
        try rejects({ _ = try corruptStore.create() }, "creating over a corrupt project index")
        let preservedIndex = try Data(contentsOf: indexURL)
        try expect(preservedIndex == corruptBytes, "corrupt project index is preserved")
        try originalIndex.write(to: indexURL)
        let clearingStore = EditorProjectStore(library: library)
        try clearingStore.clearManagedProjects()
        try rejects({ _ = try clearingStore.create() }, "editing after Clear Data")
        print("PASS: \(checks) editor lifecycle, package round-trip, editing, history, and path safety checks")
    }
}

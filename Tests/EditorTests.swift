import Foundation
import AppKit
import Combine

@main struct EditorTests {
    @MainActor static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("EDITOR TEST FAILED: \(String(reflecting: error))\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func run() throws {
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

        let workspace = SceneEditorWorkspaceModel(store: store, library: library, project: project, assets: nil, preferences: AppPreferences())
        var workspaceNotifications = 0, clockNotifications = 0
        let workspaceObservation = workspace.objectWillChange.sink { workspaceNotifications += 1 }
        let clockObservation = workspace.previewClock.objectWillChange.sink { clockNotifications += 1 }
        for sample in 1...100 { workspace.previewTime = Double(sample) }
        try expect(workspaceNotifications == 0 && clockNotifications == 100, "renderer clock samples update only the timeline, without invalidating the full editor or rescanning assets")
        let slider = workspace.timelinePosition
        try expect(slider.wrappedValue == 60 && workspace.previewTime == 100, "displaying a clock beyond the slider range never seeks playback back to 60 seconds")
        slider.wrappedValue = 12.5
        try expect(workspace.previewTime == 12.5, "explicit timeline scrubbing still changes preview time")
        workspace.seek(.infinity)
        try expect(workspace.previewTime == 12.5, "invalid scrub input cannot corrupt preview time")
        workspaceObservation.cancel(); clockObservation.cancel()

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

        let metadataURL = projectFolder.appendingPathComponent("project.json")
        let originalMetadata = try Data(contentsOf: metadataURL)
        let metadataGuardDocument = try SceneProjectDocument(folder: projectFolder)
        var externallyChangedMetadata = try JSONSerialization.jsonObject(with: originalMetadata) as! [String: Any]
        externallyChangedMetadata["title"] = "Changed outside the editor"
        externallyChangedMetadata["file"] = "replacement.pkg"
        let externalMetadataBytes = try JSONSerialization.data(withJSONObject: externallyChangedMetadata, options: [.sortedKeys])
        try externalMetadataBytes.write(to: metadataURL, options: .atomic)
        try metadataGuardDocument.addTextLayer()
        try rejects({ try metadataGuardDocument.save() }, "saving after external project metadata changes")
        let metadataAfterConflict = try Data(contentsOf: metadataURL)
        let packageAfterConflict = try Data(contentsOf: packageURL)
        let expectedPackageAfterConflict = try roundTripPackage.encoded()
        try expect(metadataAfterConflict == externalMetadataBytes,
                   "a metadata conflict preserves the external project entry and title")
        try expect(packageAfterConflict == expectedPackageAfterConflict,
                   "a metadata conflict does not write the scene package")
        try originalMetadata.write(to: metadataURL, options: .atomic)

        let beforePartialSavePackage = try Data(contentsOf: packageURL)
        let partialSaveDocument = try SceneProjectDocument(folder: projectFolder, metadataWriter: { _, _ in
            throw LumaError("Injected metadata write failure.")
        })
        partialSaveDocument.title = "Partial save must roll back"
        try partialSaveDocument.addTextLayer()
        try rejects({ try partialSaveDocument.save() }, "failure of the second project save write")
        let afterPartialSavePackage = try Data(contentsOf: packageURL)
        let afterPartialSaveMetadata = try Data(contentsOf: metadataURL)
        try expect(afterPartialSavePackage == beforePartialSavePackage && afterPartialSaveMetadata == originalMetadata,
                   "a metadata write failure restores the original scene bytes and leaves project metadata intact")

        let selfReferencingFolder = root.appendingPathComponent("SelfReferencingProject", isDirectory: true)
        try FileManager.default.createDirectory(at: selfReferencingFolder, withIntermediateDirectories: false)
        try JSONSerialization.data(withJSONObject: ["type":"scene", "title":"Invalid", "file":"project.json", "objects":[]] as [String: Any])
            .write(to: selfReferencingFolder.appendingPathComponent("project.json"))
        try rejects({ _ = try SceneProjectDocument(folder: selfReferencingFolder) }, "a scene entry that aliases project.json")

        // A rename must leave both the index and project metadata unchanged if
        // the project folder cannot accept its atomic scene-file replacement.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: projectFolder.path)
        try rejects({ try store.rename(project.id, to: "Failed Rename") }, "rename whose project write fails")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: projectFolder.path)
        let titleAfterFailedRename = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as! [String: Any]
        try expect(store.projects.first(where: { $0.id == project.id })?.title == "Round Trip"
                   && titleAfterFailedRename["title"] as? String == "Round Trip",
                   "a failed rename rolls back both the editor index and project metadata")

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
        try rejects({ _ = try Safety.child("scene.pkg", under: unsafeRoot) }, "resolving a file beneath a symbolic-link root")
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

        // An index edited by another process must not be overwritten by an
        // already-open store or newly trusted as ownership during Clear Data.
        var externalIndex = try JSONSerialization.jsonObject(with: originalIndex) as! [String: Any]
        var externalProjects = externalIndex["projects"] as! [[String: Any]]
        externalProjects[0]["title"] = "Changed outside Luma"
        externalIndex["projects"] = externalProjects
        let externalIndexBytes = try JSONSerialization.data(withJSONObject: externalIndex, options: [.sortedKeys])
        let originalProjectMetadata = try Data(contentsOf: projectFolder.appendingPathComponent("project.json"))
        try externalIndexBytes.write(to: indexURL, options: .atomic)
        try rejects({ try store.rename(project.id, to: "Overwrite attempt") }, "renaming with an externally edited project index")
        try rejects({ _ = try store.create(title: "Stale store") }, "creating with an externally edited project index")
        try expect(store.clearDataProjectCount == nil, "clear review refuses a project index changed outside the loaded store")
        try rejects({ try store.clearManagedProjects() }, "clearing with an externally edited project index")
        let preservedExternalIndex = try Data(contentsOf: indexURL)
        let preservedProjectMetadata = try Data(contentsOf: projectFolder.appendingPathComponent("project.json"))
        try expect(preservedExternalIndex == externalIndexBytes && preservedProjectMetadata == originalProjectMetadata,
                   "stale editor operations preserve external index data and project files")
        try originalIndex.write(to: indexURL, options: .atomic)

        let corruptBytes = Data("{invalid json".utf8)
        try corruptBytes.write(to: indexURL)
        let corruptStore = EditorProjectStore(library: library)
        try rejects({ _ = try corruptStore.create() }, "creating over a corrupt project index")
        try expect(corruptStore.clearDataProjectCount == nil, "clear review cannot claim ownership from a corrupt index")
        try rejects({ try corruptStore.validateManagedProjectsForClear() }, "preflighting Clear Data with a corrupt index")
        try rejects({ try corruptStore.clearManagedProjects() }, "clearing with a corrupt project index")
        let preservedIndex = try Data(contentsOf: indexURL)
        try expect(preservedIndex == corruptBytes, "corrupt project index is preserved during edit and cleanup")
        try originalIndex.write(to: indexURL)
        let clearingStore = EditorProjectStore(library: library)
        try clearingStore.clearManagedProjects()
        try rejects({ _ = try clearingStore.create() }, "editing after Clear Data")

        // A valid index is still sufficient ownership evidence for retrying
        // Clear Data after a prior run removed one project folder but stopped
        // before deleting the index. Unknown, unindexed entries stay intact.
        let retryRoot = root.appendingPathComponent("ClearRetryLibrary", isDirectory: true)
        let retryLibrary = LibraryStore(root: retryRoot)
        let retryStore = EditorProjectStore(library: retryLibrary)
        let retryProject = try retryStore.create(title: "Partial Cleanup")
        let malformedProject = try retryStore.create(title: "Malformed Document")
        try Data("{invalid json".utf8).write(to: retryStore.folder(for: malformedProject).appendingPathComponent("project.json"), options: .atomic)
        let retryBase = retryRoot.appendingPathComponent("EditorProjects", isDirectory: true)
        let unknown = retryBase.appendingPathComponent("unindexed-user-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
        try FileManager.default.removeItem(at: retryStore.folder(for: retryProject))
        let recoveryStore = EditorProjectStore(library: LibraryStore(root: retryRoot))
        try expect(recoveryStore.projects.isEmpty, "missing indexed folder prevents normal project editing")
        try expect(recoveryStore.clearDataProjectCount == 2, "clear review counts valid indexed ownership despite missing or malformed project content")
        try recoveryStore.validateManagedProjectsForClear()
        try recoveryStore.clearManagedProjects()
        try expect(!FileManager.default.fileExists(atPath: retryBase.appendingPathComponent("projects.json").path), "Clear Data retry removes validated stale ownership index")
        try expect(!FileManager.default.fileExists(atPath: retryStore.folder(for: malformedProject).path), "Clear Data retry removes malformed but safely indexed project data")
        try expect(FileManager.default.fileExists(atPath: unknown.path), "Clear Data retry preserves unindexed project entries")

        let historyFolder = root.appendingPathComponent("HistoryBudget", isDirectory: true)
        try FileManager.default.createDirectory(at: historyFolder, withIntermediateDirectories: false)
        let largeLayer: [String: Any] = ["id": 1, "name": "Large fixture", "visible": true, "retained": String(repeating: "x", count: 22 * 1024 * 1024)]
        try JSONSerialization.data(withJSONObject: ["objects": [largeLayer]] as [String: Any]).write(to: historyFolder.appendingPathComponent("scene.json"))
        try JSONSerialization.data(withJSONObject: ["title": "History Budget", "type": "scene", "file": "scene.json"] as [String: Any]).write(to: historyFolder.appendingPathComponent("project.json"))
        let historyDocument = try SceneProjectDocument(folder: historyFolder)
        for index in 0..<6 { try historyDocument.setVisibility(at: 0, visible: index.isMultiple(of: 2)) }
        try expect(historyDocument.canUndo && historyDocument.retainedHistoryBytes <= 128 * 1024 * 1024,
                   "large editor undo snapshots stay within the 128 MiB retained-history budget")
        print("PASS: \(checks) editor lifecycle, package round-trip, editing, history, and path safety checks")
    }
}

import AppKit
import AVKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

private let editorAccent = Color(red: 0.43, green: 0.88, blue: 0.75)
private let editorPanel = Color(red: 0.075, green: 0.086, blue: 0.105)

struct SceneEditorHomeView: View {
    @ObservedObject var store: EditorProjectStore
    @ObservedObject var library: LibraryStore
    let assets: URL?
    let preferences: AppPreferences
    @State private var editingProject: EditorProject?
    @State private var search = ""
    @State private var renameProject: EditorProject?
    @State private var renameValue = ""
    @State private var exportStatus: String?

    private var filtered: [EditorProject] { store.projects.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) } }
    private var recent: [EditorProject] { store.recentProjectIDs.compactMap { id in filtered.first { $0.id == id } } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 20)).foregroundStyle(editorAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Scene Editor").font(.system(size: 19, weight: .semibold))
                    Text("Create and edit local Wallpaper Engine scene projects").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Search projects", text: $search).textFieldStyle(.roundedBorder).frame(width: 190)
                Button { createProject() } label: { Label("New Scene", systemImage: "plus") }.buttonStyle(.borderedProminent).tint(editorAccent).foregroundStyle(.black)
                Button { importProject() } label: { Label("Import", systemImage: "square.and.arrow.down") }
            }.padding(22)
            if let exportStatus { Label(exportStatus, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 22) }
            Divider().opacity(0.45)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !recent.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("RECENT PROJECTS").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                                ForEach(recent) { project in
                                    Button { open(project) } label: {
                                        VStack(alignment: .leading, spacing: 10) {
                                            ZStack { RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.28)); Image(systemName: "square.stack.3d.up").font(.system(size: 27, weight: .light)).foregroundStyle(editorAccent.opacity(0.7)) }.frame(height: 96)
                                            Text(project.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                            Text(project.lastOpened.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Scene project").font(.system(size: 10)).foregroundStyle(.secondary)
                                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("ALL PROJECTS").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary); Spacer(); Text("\(filtered.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                        if filtered.isEmpty {
                            ContentUnavailableView(search.isEmpty ? "No editor projects yet" : "No matching projects", systemImage: "square.stack.3d.up", description: Text(search.isEmpty ? "Create a new scene or import a Wallpaper Engine project folder." : "Try a different project name."))
                                .frame(maxWidth: .infinity, minHeight: 200)
                        } else {
                            VStack(spacing: 1) {
                                ForEach(filtered) { project in
                                    HStack(spacing: 12) {
                                        Image(systemName: "cube.transparent").font(.system(size: 17)).foregroundStyle(editorAccent).frame(width: 34, height: 34).background(editorAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                                        VStack(alignment: .leading, spacing: 3) { Text(project.title).font(.system(size: 12, weight: .medium)); Text("Scene · \(project.entry)").font(.system(size: 10)).foregroundStyle(.secondary) }
                                        Spacer()
                                        Button("Open") { open(project) }.buttonStyle(.bordered)
                                        Menu {
                                            Button("Duplicate") { perform { _ = try store.duplicate(project.id) } }
                                            Button("Rename…") { renameProject = project; renameValue = project.title }
                                            Button("Export Project…") { export(project) }
                                        } label: { Image(systemName: "ellipsis").frame(width: 30, height: 28) }.menuStyle(.borderlessButton).fixedSize()
                                    }.padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle()).background(.white.opacity(0.018))
                                }
                            }.clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                    }
                    Text("Projects are copied into Luma’s managed EditorProjects folder. Editing a project here never changes its source folder or the wallpaper library copy.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(22)
            }
        }.background(editorPanel)
            .sheet(item: $editingProject) { project in
                SceneEditorWorkspace(store: store, project: project, assets: assets, preferences: preferences)
                    .frame(minWidth: 1180, minHeight: 760)
                    .preferredColorScheme(.dark)
            }
            .alert("Rename Project", isPresented: Binding(get: { renameProject != nil }, set: { if !$0 { renameProject = nil } })) {
                TextField("Project name", text: $renameValue)
                Button("Cancel", role: .cancel) { renameProject = nil }
                Button("Rename") { if let project = renameProject { perform { try store.rename(project.id, to: renameValue) } }; renameProject = nil }
            } message: { Text("The project folder and its assets keep their current location.") }
    }

    private func createProject() { perform { editingProject = try store.create() } }
    private func open(_ project: EditorProject) { store.opened(project.id); editingProject = project }
    private func importProject() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose a complete Wallpaper Engine scene project folder, scene.pkg, or scene.json. Luma creates a safe copy."
        if panel.runModal() == .OK, let url = panel.url {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            perform { editingProject = try store.importProject(url) }
        }
    }
    private func export(_ project: EditorProject) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.message = "Choose a folder for a copy of this project."
        if panel.runModal() == .OK, let url = panel.url {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            perform {
                let result = try store.export(project.id, to: url)
                let message = "Exported to \(result.lastPathComponent)"
                exportStatus = message
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    if exportStatus == message { exportStatus = nil }
                }
            }
        }
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { library.error = error.localizedDescription } }
}

@MainActor final class SceneEditorWorkspaceModel: ObservableObject {
    @Published var document: SceneProjectDocument?
    @Published var project: EditorProject
    @Published var selectedLayers: Set<Int> = []
    @Published var rendererLayers: [[String: Any]] = []
    @Published var scriptDiagnostics: [String] = []
    @Published var skippedScriptCount = 0
    @Published var previewAntiAliasing = "off"
    @Published var previewParticles = "high"
    @Published var previewPostProcessing = "high"
    @Published var previewGeneration = 0
    @Published var previewTime = 0.0
    @Published var rendererAvailable = false
    @Published var isPlaying = true
    @Published var isSnapping = true
    @Published var status = "Loading scene preview…"
    @Published var error: String?
    @Published var documentRevision = 0
    var host: SceneHost?
    let store: EditorProjectStore
    let library: LibraryStore
    let assets: URL?
    let preferences: AppPreferences
    let projectID: UUID
    private var scriptToggleRequest = UUID()
    private var lastDiagnosticPoll = Date.distantPast
    private var rendererGeneration: UInt64 = 0
    var title: String { document?.title ?? project.title }

    init(store: EditorProjectStore, library: LibraryStore, project: EditorProject, assets: URL?, preferences: AppPreferences) {
        self.store = store; self.library = library; self.project = project; self.projectID = project.id; self.assets = assets; self.preferences = preferences
        do { document = try SceneProjectDocument(folder: store.folder(for: project)) }
        catch { self.error = error.localizedDescription; self.status = "Project could not be opened" }
    }

    func attach(_ host: SceneHost) {
        rendererGeneration &+= 1
        let generation = rendererGeneration
        self.host = host
        host.ready = { [weak self, weak host] in
            guard let self, let host else { return }
            self.status = "Preview ready"
            Task {
                await host.editorSeek(self.previewTime)
                guard self.host === host, self.rendererGeneration == generation else { return }
                host.editorSetPreviewQuality(antiAliasing: self.previewAntiAliasing, particles: self.previewParticles, postProcessing: self.previewPostProcessing)
                host.setPlaying(self.isPlaying)
                await self.refreshRenderer()
            }
        }
        host.failed = { [weak self] message in self?.status = "Preview error: \(message)" }
        host.diagnostic = { [weak self] message in self?.status = message }
    }
    func detach(_ host: SceneHost) { if self.host === host { rendererGeneration &+= 1; self.host = nil; rendererAvailable = false; rendererLayers = [] } }
    func refreshRenderer() async {
        guard let host else { return }
        let generation = rendererGeneration
        let available = await host.editorAvailable()
        let layers = available ? (try? await host.editorLayers()) ?? [] : []
        let time = await host.editorTime()
        let diagnostics = await host.editorScriptDiagnostics()
        let skipped = await host.editorSkippedScriptCount()
        guard self.host === host, rendererGeneration == generation else { return }
        rendererAvailable = available; rendererLayers = layers; previewTime = time
        scriptDiagnostics = diagnostics; skippedScriptCount = skipped
        lastDiagnosticPoll = Date()
    }
    func tick() async {
        guard let host else { return }
        let generation = rendererGeneration
        let time = isPlaying ? await host.editorTime() : previewTime
        guard self.host === host, rendererGeneration == generation else { return }
        if isPlaying { previewTime = time }
        guard Date().timeIntervalSince(lastDiagnosticPoll) >= 1 else { return }
        let diagnostics = await host.editorScriptDiagnostics()
        let skipped = await host.editorSkippedScriptCount()
        guard self.host === host, rendererGeneration == generation else { return }
        scriptDiagnostics = diagnostics; skippedScriptCount = skipped
        lastDiagnosticPoll = Date()
    }
    func select(_ index: Int, extending: Bool) {
        guard document?.objects.indices.contains(index) == true else { selectedLayers = []; return }
        if extending { if selectedLayers.contains(index) { selectedLayers.remove(index) } else { selectedLayers.insert(index) } }
        else { selectedLayers = [index] }
    }
    func selectRendererIDs(_ ids: [String], extending: Bool) {
        guard let document else { return }
        guard let id = ids.first, let index = document.objects.indices.first(where: { document.layerID(at: $0) == id }) else { return }
        select(index, extending: extending)
    }
    func hitTest(x: Double, y: Double, extending: Bool) {
        guard let host else { return }
        let generation = rendererGeneration
        Task { [weak self, weak host] in
            guard let self, let host else { return }
            do {
                let ids = try await host.editorHitTest(x: x, y: y)
                guard self.host === host, self.rendererGeneration == generation else { return }
                self.selectRendererIDs(ids, extending: extending)
            } catch {
                guard self.host === host, self.rendererGeneration == generation else { return }
                self.status = error.localizedDescription
            }
        }
    }
    func layerJSON(_ index: Int) -> String { guard let document, document.objects.indices.contains(index), JSONSerialization.isValidJSONObject(document.objects[index]), let bytes = try? JSONSerialization.data(withJSONObject: document.objects[index], options: [.prettyPrinted, .sortedKeys]), let string = String(data: bytes, encoding: .utf8) else { return "{}" }; return string }
    func generalJSON() -> String { guard let general = document?.scene["general"] as? [String: Any], JSONSerialization.isValidJSONObject(general), let bytes = try? JSONSerialization.data(withJSONObject: general, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }; return String(decoding: bytes, as: UTF8.self) }

    func applyLayerJSON(_ text: String, at index: Int) {
        do {
            guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw LumaError("A layer must be a JSON object.") }
            try document?.replaceLayer(at: index, with: value); try commitChanges()
        } catch { self.error = error.localizedDescription }
    }
    func applyGeneralJSON(_ text: String) {
        do { guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw LumaError("Scene settings must be a JSON object.") }; try document?.updateGeneral(value); try commitChanges() }
        catch { self.error = error.localizedDescription }
    }
    func addText() { do { try document?.addTextLayer(); selectedLayers = [max(0, (document?.objects.count ?? 1) - 1)]; try commitChanges() } catch { self.error = error.localizedDescription } }
    func duplicate(_ index: Int) { do { try document?.duplicateLayer(at: index); selectedLayers = [index + 1]; try commitChanges() } catch { self.error = error.localizedDescription } }
    func selectAll() { selectedLayers = Set(document?.objects.indices ?? 0..<0) }
    func duplicateSelection() { guard selectedLayers.count == 1, let index = selectedLayers.first else { status = "Select one layer to duplicate"; return }; duplicate(index) }
    func removeSelection() { do { for index in selectedLayers.sorted(by: >) { try document?.deleteLayer(at: index) }; selectedLayers = []; try commitChanges() } catch { self.error = error.localizedDescription } }
    func reorder(_ index: Int, direction: Int) {
        do { guard let document else { return }; let target = max(0, min(document.objects.count - 1, index + direction)); try document.reorderLayer(from: index, to: target); selectedLayers = [target]; try commitChanges() } catch { self.error = error.localizedDescription }
    }
    func toggleVisibility(_ index: Int) { do { let visible = (document?.objects[index]["visible"] as? Bool) != false; try document?.setVisibility(at: index, visible: !visible); try commitChanges() } catch { self.error = error.localizedDescription } }
    func toggleLock(_ index: Int) { do { let locked = (document?.objects[index]["locked"] as? Bool) == true; try document?.setLocked(at: index, locked: !locked); try commitChanges() } catch { self.error = error.localizedDescription } }
    func transformSelected(dx: Double = 0, dy: Double = 0, widthDelta: Double = 0, heightDelta: Double = 0, rotation: Double = 0) {
        do { try document?.transformLayers(indices: selectedLayers, dx: dx, dy: dy, widthDelta: widthDelta, heightDelta: heightDelta, rotationDelta: rotation, snapToGrid: isSnapping); try commitChanges() } catch { status = error.localizedDescription }
    }
    func undo() { do { try document?.undo(); try commitChanges() } catch { self.error = error.localizedDescription } }
    func redo() { do { try document?.redo(); try commitChanges() } catch { self.error = error.localizedDescription } }
    func save() { do { try document?.save(); status = "Project saved" } catch { self.error = error.localizedDescription } }

    private func commitChanges() throws {
        guard let document else { return }
        let hadApproval = project.scriptsApproved || project.scriptsEnabled
        scriptToggleRequest = UUID()
        let previousProjects = store.projects
        let previousRecents = store.recentProjectIDs
        try store.update(projectID) { item in item.title = document.title; item.entry = document.entry; item.scriptApprovalFingerprint = nil; item.scriptsEnabled = false }
        do {
            try document.save()
        } catch {
            let saveError = error.localizedDescription
            do { try store.restoreStoreSnapshot(projects: previousProjects, recents: previousRecents) }
            catch { throw LumaError("The project edit could not be saved: \(saveError). Restoring its editor index also failed: \(error.localizedDescription). Reopen this project and review its contents.") }
            throw error
        }
        project = store.projects.first(where: { $0.id == projectID }) ?? project
        status = hadApproval ? "Project saved · script approval cleared because project contents changed" : "Project saved"
        previewGeneration += 1; documentRevision += 1; rendererAvailable = false; rendererLayers = []; objectWillChange.send()
    }

    func toggleScripts(_ enabled: Bool) {
        let request = UUID(); scriptToggleRequest = request
        guard enabled else { do { try store.update(projectID) { $0.scriptsEnabled = false }; project = store.projects.first { $0.id == projectID } ?? project; previewGeneration += 1 } catch { self.error = error.localizedDescription }; return }
        guard let fingerprint = project.scriptApprovalFingerprint else { return }
        let folder = store.folder(for: project); status = "Checking the reviewed script source…"
        Task {
            do {
                let review = try await Task.detached(priority: .userInitiated) { try SceneScriptReview.inspect(folder: folder) }.value
                guard request == scriptToggleRequest, project.scriptApprovalFingerprint == fingerprint else { return }
                guard review.canApprove, review.fingerprint == fingerprint else {
                    try store.update(projectID) { $0.scriptsEnabled = false; $0.scriptApprovalFingerprint = nil }
                    project = store.projects.first { $0.id == projectID } ?? project
                    status = "Project contents changed. Review SceneScript again before enabling it."; previewGeneration += 1; return
                }
                try store.update(projectID) { $0.scriptsEnabled = true }; project = store.projects.first { $0.id == projectID } ?? project
                status = "Reviewed SceneScript enabled"; previewGeneration += 1
            } catch { self.error = error.localizedDescription }
        }
    }
    func approveScripts(_ fingerprint: String) {
        scriptToggleRequest = UUID()
        do { try store.update(projectID) { $0.scriptApprovalFingerprint = fingerprint; $0.scriptsEnabled = false }; project = store.projects.first { $0.id == projectID } ?? project; status = "Scripts reviewed and approved. They remain off until enabled."; previewGeneration += 1 }
        catch { self.error = error.localizedDescription }
    }
    func revokeApproval() { scriptToggleRequest = UUID(); do { try store.update(projectID) { $0.scriptApprovalFingerprint = nil; $0.scriptsEnabled = false }; project = store.projects.first { $0.id == projectID } ?? project; status = "Script approval revoked"; previewGeneration += 1 } catch { self.error = error.localizedDescription } }

    func importAssets() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie, .audio, .data]; panel.message = "Copies assets into this project. Existing source files remain untouched."
        guard panel.runModal() == .OK else { return }
        do {
            let projectFolder = store.folder(for: project)
            let assetsFolder = try Safety.child("assets", under: projectFolder)
            try FileManager.default.createDirectory(at: assetsFolder, withIntermediateDirectories: true)
            for source in panel.urls {
                let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
                let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else { throw LumaError("Only regular files can be imported as project assets.") }
                var name = source.lastPathComponent, destination = assetsFolder.appendingPathComponent(name); var suffix = 2
                while FileManager.default.fileExists(atPath: destination.path) { let ext = source.pathExtension; name = ext.isEmpty ? "\(source.deletingPathExtension().lastPathComponent) \(suffix)" : "\(source.deletingPathExtension().lastPathComponent) \(suffix).\(ext)"; destination = assetsFolder.appendingPathComponent(name); suffix += 1 }
                _ = try Safety.child("assets/\(name)", under: projectFolder)
                try FileManager.default.copyItem(at: source, to: destination)
            }
            try store.update(projectID) { $0.scriptApprovalFingerprint = nil; $0.scriptsEnabled = false }; project = store.projects.first { $0.id == projectID } ?? project
            status = "Assets copied into the project · script approval cleared"; previewGeneration += 1
        } catch { self.error = "Asset import failed: \(error.localizedDescription)" }
    }
    var assetFiles: [URL] {
        let root = store.folder(for: project)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { url in
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard relative != "project.json", relative != project.entry, !relative.hasPrefix(".DS_Store") else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])).map { $0.isRegularFile == true && $0.isDirectory != true && $0.isSymbolicLink != true } ?? false
        }.sorted { assetDisplayName($0, relativeTo: root).localizedStandardCompare(assetDisplayName($1, relativeTo: root)) == .orderedAscending }
    }
    func playPause() { isPlaying.toggle(); host?.setPlaying(isPlaying) }
    func applyPreviewQuality() { host?.editorSetPreviewQuality(antiAliasing: previewAntiAliasing, particles: previewParticles, postProcessing: previewPostProcessing) }
    func seek(_ time: Double) {
        previewTime = time
        guard let host else { return }
        let generation = rendererGeneration
        Task {
            guard self.host === host, self.rendererGeneration == generation else { return }
            await host.editorSeek(time)
            guard self.host === host, self.rendererGeneration == generation else { return }
        }
    }
    func step(_ frame: Int, fps: Int) {
        guard let host else { return }
        let generation = rendererGeneration
        host.editorStep(frame, fps: fps)
        Task {
            try? await Task.sleep(for: .milliseconds(40))
            guard self.host === host, self.rendererGeneration == generation else { return }
            let time = await host.editorTime()
            guard self.host === host, self.rendererGeneration == generation else { return }
            previewTime = time
        }
    }
}

struct SceneEditorWorkspace: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SceneEditorWorkspaceModel
    @State private var selectedPanel = "Layer"
    @State private var showDeleteConfirmation = false
    @State private var showScriptReview = false
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @State private var panGestureStart: CGSize?
    @State private var zoomGestureStart: Double?
    @State private var timelineFPS = 30
    @State private var timelinePosition = 0.0
    @State private var sceneJSON = "{}"
    @State private var selectedAsset: URL?
    @State private var assetPreviewPlayer: AVPlayer?

    init(store: EditorProjectStore, project: EditorProject, assets: URL?, preferences: AppPreferences) {
        _model = StateObject(wrappedValue: SceneEditorWorkspaceModel(store: store, library: store.library, project: project, assets: assets, preferences: preferences))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.45)
            HStack(spacing: 0) {
                leftPanel.frame(width: 238)
                Divider().opacity(0.45)
                centerPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().opacity(0.45)
                inspector.frame(width: 330)
            }
            Divider().opacity(0.45)
            HStack(spacing: 8) { Circle().fill(model.error == nil ? editorAccent : .orange).frame(width: 5, height: 5); Text(model.error ?? model.status).font(.system(size: 10)).lineLimit(1); Spacer(); if model.rendererAvailable { Text("WebWallGL editor API connected").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary) }; Text(model.title).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }.padding(.horizontal, 13).frame(height: 28)
        }.background(editorPanel)
            .sheet(isPresented: $showScriptReview) { EditorScriptReviewSheet(folder: model.store.folder(for: model.project), onApprove: model.approveScripts).frame(minWidth: 760, minHeight: 520).preferredColorScheme(.dark) }
            .alert("Scene Editor", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
            .confirmationDialog("Delete selected layers?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) { Button("Delete Layers", role: .destructive) { model.removeSelection() }; Button("Cancel", role: .cancel) {} } message: { Text("This changes the editor project. Undo can restore deleted layers until the editor is closed.") }
            .task(id: model.previewGeneration) { await startTimer() }
            .onAppear { sceneJSON = model.generalJSON() }
            .onChange(of: model.documentRevision) { _, _ in sceneJSON = model.generalJSON() }
            .onChange(of: selectedAsset) { _, url in
                assetPreviewPlayer?.pause()
                assetPreviewPlayer = url.flatMap { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) ? AVPlayer(url: $0) : nil }
            }
            .onExitCommand { dismiss() }
            .background(KeyboardShortcuts(model: model, requestDelete: { showDeleteConfirmation = true }))
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: { Image(systemName: "chevron.left"); Text("Projects") }.buttonStyle(.plain).foregroundStyle(.secondary)
            Divider().frame(height: 22)
            VStack(alignment: .leading, spacing: 2) { Text(model.title).font(.system(size: 13, weight: .semibold)); Text("Wallpaper Engine scene project").font(.system(size: 9)).foregroundStyle(.secondary) }
            Button { NSWorkspace.shared.activateFileViewerSelecting([model.store.folder(for: model.project)]) } label: { Image(systemName: "folder") }.help("Show project files in Finder")
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.help("Undo · ⌘Z")
                .disabled(model.document?.canUndo != true)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.help("Redo · ⇧⌘Z")
                .disabled(model.document?.canRedo != true)
            Button { model.save() } label: { Label("Save", systemImage: "checkmark.circle") }.keyboardShortcut("s", modifiers: .command)
            Divider().frame(height: 22)
            Button { showScriptReview = true } label: { Label("Review Scripts", systemImage: "checkmark.shield") }
            Toggle("Run SceneScript", isOn: Binding(get: { model.project.scriptsEnabled }, set: { model.toggleScripts($0) }))
                .toggleStyle(.switch).controlSize(.small).disabled(!model.project.scriptsApproved)
            if model.project.scriptsApproved { Button("Revoke", role: .destructive) { model.revokeApproval() }.help("Disable scripts and revoke this project's review approval") }
        }.buttonStyle(.bordered).controlSize(.small).padding(.horizontal, 12).frame(height: 48).background(.white.opacity(0.018))
    }

    private var leftPanel: some View {
        VStack(spacing: 0) {
            HStack { Text("LAYERS").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary); Spacer(); Menu {
                Button("Text Layer") { model.addText() }
                Button("Image Layer") {}.disabled(true).help("The pinned renderer exposes addLayer but this build has no verified image-layer payload schema.")
                Button("Video Layer") {}.disabled(true).help("The pinned renderer exposes addLayer but this build has no verified video-layer payload schema.")
                Button("Particle Layer") {}.disabled(true).help("Existing particle layers can be edited in their scene JSON. New particle templates are not exposed by this bundled editor API.")
                Button("Model Layer") {}.disabled(true).help("New model import is not exposed by this bundled editor API.")
            } label: { Image(systemName: "plus.circle.fill").foregroundStyle(editorAccent) }.menuStyle(.borderlessButton).fixedSize().help("Add supported layer") }.padding(11)
            Divider().opacity(0.35)
            if let document = model.document, document.canEditLayers {
                List(selection: Binding(get: { model.selectedLayers }, set: { model.selectedLayers = $0 })) {
                    ForEach(Array(document.objects.enumerated()), id: \.offset) { index, layer in
                        layerRow(index, layer)
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
            } else {
                ContentUnavailableView("No editable layer list", systemImage: "square.stack.3d.up", description: Text("This renderer project uses a scene structure Luma cannot safely edit yet."))
            }
            Divider().opacity(0.35)
            HStack { Text("ASSETS").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary); Spacer(); Button { model.importAssets() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("Copy files into project assets") }.padding(11)
            if model.assetFiles.isEmpty { Text("No imported assets").font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 12) }
            else {
                ScrollView { VStack(alignment: .leading, spacing: 5) { ForEach(model.assetFiles, id: \.path) { url in
                    Button { selectedAsset = url } label: { HStack(spacing: 7) { Image(systemName: assetIcon(url)).foregroundStyle(editorAccent); Text(assetDisplayName(url, relativeTo: model.store.folder(for: model.project))).lineLimit(1); Spacer() }.font(.system(size: 10)).padding(.horizontal, 10).padding(.vertical, 4).background(selectedAsset == url ? .white.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 5)) }.buttonStyle(.plain)
                } } }.frame(maxHeight: 110)
                if let selectedAsset, let image = NSImage(contentsOf: selectedAsset), ["png", "jpg", "jpeg", "heic", "webp"].contains(selectedAsset.pathExtension.lowercased()) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 76).background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 5)).padding(.horizontal, 8).padding(.bottom, 8)
                } else if let assetPreviewPlayer, selectedAsset != nil {
                    VideoPlayer(player: assetPreviewPlayer).frame(height: 76).clipShape(RoundedRectangle(cornerRadius: 5)).padding(.horizontal, 8).padding(.bottom, 8)
                } else if let selectedAsset {
                    Text("\(assetDisplayName(selectedAsset, relativeTo: model.store.folder(for: model.project))) · \(assetSize(selectedAsset))").font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 10).padding(.bottom, 8)
                }
            }
        }.background(.white.opacity(0.012))
    }

    @ViewBuilder private func layerRow(_ index: Int, _ layer: [String: Any]) -> some View {
        let name = layer["name"] as? String ?? "Layer \(index + 1)"
        HStack(spacing: 6) {
            Image(systemName: layerIcon(layer)).frame(width: 15).foregroundStyle(model.selectedLayers.contains(index) ? editorAccent : Color.secondary)
            Text(name).lineLimit(1).font(.system(size: 10, weight: model.selectedLayers.contains(index) ? .semibold : .regular))
            Spacer(minLength: 1)
            Button { model.toggleVisibility(index) } label: { Image(systemName: (layer["visible"] as? Bool) == false ? "eye.slash" : "eye").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Toggle visibility")
            Button { model.toggleLock(index) } label: { Image(systemName: (layer["locked"] as? Bool) == true ? "lock.fill" : "lock.open").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Toggle lock")
        }.contentShape(Rectangle()).onTapGesture { model.select(index, extending: NSEvent.modifierFlags.contains(.shift)) }
            .contextMenu {
                Button("Move Up") { model.reorder(index, direction: -1) }
                Button("Move Down") { model.reorder(index, direction: 1) }
                Button("Duplicate") { model.duplicate(index) }
                Button("Delete", role: .destructive) { if !model.selectedLayers.contains(index) { model.select(index, extending: false) }; showDeleteConfirmation = true }
                Divider()
                Button("Group Selection") {}.disabled(true).help("The scene format's container and parenting rules are not decoded by the pinned renderer editor API.")
            }.tag(index)
            .listRowBackground(model.selectedLayers.contains(index) ? editorAccent.opacity(0.11) : Color.clear)
    }

    private var centerPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Button { model.playPause() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill") }.help(model.isPlaying ? "Pause preview" : "Play preview")
                Button { model.step(-1, fps: timelineFPS) } label: { Image(systemName: "backward.end.fill") }.help("Previous frame")
                Button { model.step(1, fps: timelineFPS) } label: { Image(systemName: "forward.end.fill") }.help("Next frame")
                Divider().frame(height: 18)
                Button { zoom = 1; pan = .zero } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Fit scene to view")
                Slider(value: $zoom, in: 0.25...3).frame(width: 95).help("Viewport zoom")
                Text("\(Int(zoom * 100))%").font(.system(size: 9, design: .monospaced)).frame(width: 42, alignment: .trailing)
                Toggle("Snap", isOn: $model.isSnapping).toggleStyle(.button).controlSize(.mini)
                Spacer()
                Text("\(model.document?.resolution.0 ?? 1920) × \(model.document?.resolution.1 ?? 1080)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).padding(.horizontal, 10).frame(height: 38).background(.white.opacity(0.015))
            ZStack {
                Color(red: 0.035, green: 0.04, blue: 0.05)
                if let document = model.document {
                    SceneEditorPreview(folder: document.folder, assets: model.assets, wallpaper: model.project.previewWallpaper(), preferences: model.preferences, model: model)
                        .id(model.previewGeneration).scaleEffect(zoom).offset(pan).clipped()
                        .overlay { SceneSelectionOverlay(model: model).allowsHitTesting(true) }
                        .gesture(DragGesture(minimumDistance: 12).onChanged { value in
                            if panGestureStart == nil { panGestureStart = pan }
                            guard let start = panGestureStart else { return }
                            pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                        }.onEnded { _ in panGestureStart = nil }, including: .subviews)
                        .gesture(MagnificationGesture().onChanged { value in
                            if zoomGestureStart == nil { zoomGestureStart = zoom }
                            zoom = max(0.25, min(3, (zoomGestureStart ?? zoom) * value))
                        }.onEnded { _ in zoomGestureStart = nil }, including: .subviews)
                } else { ContentUnavailableView("Preview unavailable", systemImage: "exclamationmark.triangle", description: Text(model.error ?? "The project could not be loaded.")) }
                if !model.rendererAvailable && model.document != nil { Text("Loading preview…").font(.system(size: 10)).padding(7).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12).allowsHitTesting(false) }
            }.clipped()
            Divider().opacity(0.35)
            timelinePanel
        }
    }

    private var timelinePanel: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text("TIMELINE").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                Text(String(format: "%06.2f s", model.previewTime)).font(.system(size: 10, design: .monospaced)).frame(width: 78)
                Slider(value: $timelinePosition, in: 0...60, onEditingChanged: { editing in if !editing { model.seek(timelinePosition) } }).onChange(of: timelinePosition) { _, value in model.seek(value) }
                Picker("Frame Rate", selection: $timelineFPS) { ForEach([15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) } }.labelsHidden().frame(width: 85)
            }
            HStack(spacing: 7) {
                Text("Scene clock").font(.system(size: 9)).foregroundStyle(.secondary)
                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                if let index = model.selectedLayers.sorted().first, let layer = model.document?.objects[index] {
                    Text(layer["name"] as? String ?? "Layer \(index + 1)").font(.system(size: 9)).lineLimit(1)
                    let animationKeys = layer.keys.filter { ["animation", "animations", "animationlayers"].contains($0.lowercased()) }
                    if !animationKeys.isEmpty { Text("Existing animation data: \(animationKeys.joined(separator: ", "))").font(.system(size: 8, design: .monospaced)).foregroundStyle(editorAccent) }
                }
                Spacer()
                Text("Keyframe editing is unavailable in this pinned renderer API").font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 12).padding(.vertical, 9).frame(height: 66).background(.white.opacity(0.018))
            .onChange(of: model.previewTime) { _, value in timelinePosition = min(60, value) }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $selectedPanel) { Text("Layer").tag("Layer"); Text("Scene").tag("Scene"); Text("Animation").tag("Animation"); Text("Scripts").tag("Scripts") }.pickerStyle(.segmented).padding(10)
            Divider().opacity(0.35)
            switch selectedPanel {
            case "Scene": sceneInspector
            case "Animation": animationInspector
            case "Scripts": scriptsInspector
            default: layerInspector
            }
        }.background(.white.opacity(0.012))
    }

    private var layerInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.selectedLayers.count == 1, let index = model.selectedLayers.first, let layer = model.document?.objects[index] {
                HStack { VStack(alignment: .leading, spacing: 3) { Text(layer["name"] as? String ?? "Layer \(index + 1)").font(.system(size: 13, weight: .semibold)); Text(layerKind(layer)).font(.system(size: 10)).foregroundStyle(.secondary) }; Spacer(); Button { model.duplicate(index) } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate layer") }
                Text("Properties and transform").font(.system(size: 10, weight: .medium)).foregroundStyle(editorAccent)
                Text("Edit this layer's complete JSON. Unknown material, effect, playback, font and renderer fields are retained when unchanged.").font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LayerJSONEditor(model: model, index: index, layer: layer).frame(maxHeight: .infinity)
            } else if model.selectedLayers.count > 1 {
                ContentUnavailableView("\(model.selectedLayers.count) layers selected", systemImage: "square.3.layers.3d", description: Text("Drag the selection box to move all selected layers. Apply properties to one layer at a time."))
            } else {
                ContentUnavailableView("Select a layer", systemImage: "cursorarrow.click", description: Text("Select a layer in the tree or click a layer in the scene preview."))
            }
            Spacer(minLength: 4)
        }.padding(12)
    }

    private var sceneInspector: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("SCENE SETTINGS").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(editorAccent)
            let resolution = model.document?.resolution ?? (1920, 1080)
            Text(String(format: "Projection  %d × %d · %.2f:1", resolution.0, resolution.1, Double(resolution.0) / Double(max(1, resolution.1)))).font(.system(size: 10, design: .monospaced))
            Text("Edit resolution, background, and other renderer general settings in the scene JSON. Unknown fields are preserved when not changed.").font(.system(size: 9)).foregroundStyle(.secondary)
            Group {
                Picker("Anti-aliasing", selection: $model.previewAntiAliasing) { Text("Off").tag("off"); Text("FXAA").tag("fxaa"); Text("MSAA 2×").tag("msaa2"); Text("MSAA 4×").tag("msaa4") }
                Picker("Particles", selection: $model.previewParticles) { ForEach(["off", "low", "medium", "high"], id: \.self) { Text($0.capitalized).tag($0) } }
                Picker("Post-processing", selection: $model.previewPostProcessing) { ForEach(["off", "low", "medium", "high"], id: \.self) { Text($0.capitalized).tag($0) } }
            }.pickerStyle(.menu).font(.system(size: 9))
            Text("Preview quality only · output uses Luma’s \(model.preferences.sceneFPS) fps and \(model.preferences.retina ? "Retina" : "standard") render settings from Preferences.")
                .font(.system(size: 8)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $sceneJSON).font(.system(size: 10, design: .monospaced)).scrollContentBackground(.hidden).padding(5).background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 7)).frame(maxHeight: .infinity)
            Button("Apply Scene Settings") { model.applyGeneralJSON(sceneJSON) }.buttonStyle(.borderedProminent).tint(editorAccent).foregroundStyle(.black)
            Text("Audio spectrum and Now Playing inputs remain governed by the existing Luma runtime.").font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(12)
            .onChange(of: model.previewAntiAliasing) { _, _ in model.applyPreviewQuality() }
            .onChange(of: model.previewParticles) { _, _ in model.applyPreviewQuality() }
            .onChange(of: model.previewPostProcessing) { _, _ in model.applyPreviewQuality() }
    }

    private var animationInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ANIMATION PREVIEW").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(editorAccent)
            Text("The bundled WebWallGL editor API supports scene clock seeking, frame stepping, and playback speed. Existing Wallpaper Engine animation data continues to play in the preview.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Text("Playback"); Spacer(); Button { model.playPause() } label: { Label(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill") } }
            HStack { Text("Time scale"); Spacer(); ForEach([0.25, 0.5, 1.0, 2.0], id: \.self) { speed in Button("\(speed, specifier: "%g")×") { model.host?.editorSetTimeScale(speed) }.buttonStyle(.borderless) } }
            Divider()
            Text("Keyframe authoring and per-property interpolation need an animation document schema. The pinned bundle exports setAnimationLayers, but provides no schema or documentation for its layer argument, so Luma does not write guessed keyframes.").font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }.padding(12)
    }

    private var scriptsInspector: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("SCENESCRIPT").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(editorAccent)
            Text("Review is tied to this project's script fingerprint. Editing scene data clears approval. Scripts stay off until you approve them and enable this separate toggle.")
                .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Review Scripts…") { showScriptReview = true }
                if model.project.scriptsApproved { Button("Revoke Approval", role: .destructive) { model.revokeApproval() } }
            }
            Toggle("Run SceneScript", isOn: Binding(get: { model.project.scriptsEnabled }, set: { model.toggleScripts($0) }))
                .toggleStyle(.switch).disabled(!model.project.scriptsApproved)
            Divider()
            HStack {
                Text("Runtime diagnostics").font(.system(size: 10, weight: .medium))
                Spacer()
                if model.skippedScriptCount > 0 { Text("\(model.skippedScriptCount) skipped").font(.system(size: 8, design: .monospaced)).foregroundStyle(.orange) }
            }
            if model.scriptDiagnostics.isEmpty {
                Text(model.project.scriptsEnabled ? "No script errors reported by the renderer." : "Enable reviewed scripts to collect runtime diagnostics.")
                    .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView { VStack(alignment: .leading, spacing: 6) { ForEach(Array(model.scriptDiagnostics.enumerated()), id: \.offset) { _, message in
                    Text(message).font(.system(size: 9, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(7).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                } } }
            }
            Text("Edit inline script properties in the layer JSON inspector. Loose script files can be edited in the project folder, then reviewed again. Packed package scripts are read-only in this editor.")
                .font(.system(size: 8)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }.padding(12)
    }

    private func startTimer() async {
        while !Task.isCancelled {
            await model.tick(); try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

private struct LayerJSONEditor: View {
    @ObservedObject var model: SceneEditorWorkspaceModel
    let index: Int
    let layer: [String: Any]
    @State private var json = ""
    @State private var name = ""
    @State private var textValue = ""
    @State private var font = ""
    @State private var pointSize = 64.0
    @State private var opacity = 1.0
    @State private var positionX = "0"
    @State private var positionY = "0"
    @State private var width = "160"
    @State private var height = "100"
    @State private var rotation = "0"
    @State private var transformBaseline = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField("Name", text: $name).onChange(of: name) { _, value in patchDraft("name", value) }
            Text("Transform · scene units").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            Grid(horizontalSpacing: 6, verticalSpacing: 5) {
                GridRow {
                    TextField("X", text: $positionX).textFieldStyle(.roundedBorder)
                    TextField("Y", text: $positionY).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    TextField("Width", text: $width).textFieldStyle(.roundedBorder)
                    TextField("Height", text: $height).textFieldStyle(.roundedBorder)
                }
                GridRow { TextField("Rotation °", text: $rotation).textFieldStyle(.roundedBorder).gridCellColumns(2) }
            }.font(.system(size: 9))
            if layer["text"] is String {
                Text("Text").font(.system(size: 9)).foregroundStyle(.secondary)
                TextEditor(text: $textValue).font(.system(size: 10)).frame(height: 56).scrollContentBackground(.hidden).padding(4).background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6)).onChange(of: textValue) { _, value in patchDraft("text", value) }
                TextField("Font", text: $font).onChange(of: font) { _, value in patchDraft("font", value) }
                VStack(alignment: .leading, spacing: 3) { Text("Point size · \(Int(pointSize))").font(.system(size: 9)).foregroundStyle(.secondary); Slider(value: $pointSize, in: 6...300, step: 1).onChange(of: pointSize) { _, value in patchDraft("pointsize", Int(value)) } }
            }
            if layer["alpha"] is NSNumber || layer["opacity"] is NSNumber {
                VStack(alignment: .leading, spacing: 3) { Text("Opacity").font(.system(size: 9)).foregroundStyle(.secondary); Slider(value: $opacity, in: 0...1).onChange(of: opacity) { _, value in patchDraft(layer["alpha"] != nil ? "alpha" : "opacity", value) } }
            }
            Text("Full layer data").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            TextEditor(text: $json).font(.system(size: 9, design: .monospaced)).scrollContentBackground(.hidden).padding(5).background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 7)).frame(maxHeight: .infinity)
            Button("Apply Layer") { applyLayer() }.buttonStyle(.borderedProminent).tint(editorAccent).foregroundStyle(.black)
        }.onAppear { refresh() }.onChange(of: model.selectedLayers) { _, _ in refresh() }
            .onChange(of: model.documentRevision) { _, _ in refresh() }
    }
    private func refresh() {
        json = model.layerJSON(index); name = layer["name"] as? String ?? ""; textValue = layer["text"] as? String ?? ""; font = layer["font"] as? String ?? ""
        pointSize = (layer["pointsize"] as? NSNumber)?.doubleValue ?? 64
        opacity = (layer["alpha"] as? NSNumber)?.doubleValue ?? (layer["opacity"] as? NSNumber)?.doubleValue ?? 1
        let origin = vector(layer["origin"]) ?? [0, 0]
        let size = vector(layer["size"]) ?? [160, 100]
        let angles = vector(layer["angles"]) ?? [0, 0, 0]
        positionX = numberText(origin[0]); positionY = numberText(origin[1])
        width = numberText(size[0]); height = numberText(size[1]); rotation = numberText(angles.count > 2 ? angles[2] : 0)
        transformBaseline = [positionX, positionY, width, height, rotation].joined(separator: "|")
    }
    private func patchDraft(_ key: String, _ value: Any) {
        guard var object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        object[key] = value
        updateJSON(object)
    }
    private func updateJSON(_ value: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(value), let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return }
        json = String(decoding: bytes, as: UTF8.self)
    }
    private func applyLayer() {
        guard var object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { model.applyLayerJSON(json, at: index); return }
        let current = [positionX, positionY, width, height, rotation].joined(separator: "|")
        if current != transformBaseline {
            guard let x = Double(positionX), let y = Double(positionY), let w = Double(width), let h = Double(height), let angle = Double(rotation),
                  [x, y, w, h, angle].allSatisfy(\.isFinite), abs(x) <= 10_000_000, abs(y) <= 10_000_000,
                  w > 0, h > 0, w <= 1_000_000, h <= 1_000_000, abs(angle) <= 1_000_000 else {
                model.error = "Enter finite transform values within the supported scene limits."; return
            }
            object["origin"] = replacingVector(object["origin"], defaults: [0, 0], updates: [x, y])
            object["size"] = replacingVector(object["size"], defaults: [160, 100], updates: [w, h])
            object["angles"] = replacingVector(object["angles"], defaults: [0, 0, 0], updates: [nil, nil, angle])
        }
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) else { model.error = "The layer inspector could not serialize these values."; return }
        model.applyLayerJSON(text, at: index)
    }
    private func vector(_ value: Any?) -> [Double]? {
        if let text = value as? String {
            let values = text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).compactMap { Double($0) }
            return values.count >= 2 ? values : nil
        }
        if let values = value as? [NSNumber], values.count >= 2 { return values.map(\.doubleValue) }
        return nil
    }
    private func replacingVector(_ original: Any?, defaults: [Double], updates: [Double?]) -> Any {
        var values = vector(original) ?? defaults
        if values.count < updates.count { values.append(contentsOf: repeatElement(0, count: updates.count - values.count)) }
        for (index, value) in updates.enumerated() { if let value { values[index] = value } }
        if original is [NSNumber] { return values }
        return values.map(numberText).joined(separator: " ")
    }
    private func numberText(_ value: Double) -> String {
        String(format: "%.3f", value).replacingOccurrences(of: "\\.0+$", with: "", options: .regularExpression).replacingOccurrences(of: "(\\.\\d*?)0+$", with: "$1", options: .regularExpression).replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
    }
}

private struct SceneEditorPreview: NSViewRepresentable {
    let folder: URL
    let assets: URL?
    let wallpaper: Wallpaper
    let preferences: AppPreferences
    let model: SceneEditorWorkspaceModel
    final class Coordinator { weak var host: SceneHost?; weak var model: SceneEditorWorkspaceModel? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> EditorPreviewContainer {
        let container = EditorPreviewContainer(); container.wantsLayer = true; container.layer?.masksToBounds = true
        let host = SceneHost(folder: folder, assets: assets, wallpaper: wallpaper, configuration: DisplayConfiguration(), preferences: preferences)
        context.coordinator.host = host; context.coordinator.model = model; model.attach(host)
        host.webView.frame = container.bounds; host.webView.autoresizingMask = [.width, .height]; container.addSubview(host.webView); container.host = host; container.model = model
        return container
    }
    func updateNSView(_ nsView: EditorPreviewContainer, context: Context) { nsView.model = model; nsView.host = context.coordinator.host }
    static func dismantleNSView(_ nsView: EditorPreviewContainer, coordinator: Coordinator) { if let host = coordinator.host { coordinator.model?.detach(host); host.stop() }; coordinator.host = nil }
}

private final class EditorPreviewContainer: NSView {
    weak var host: SceneHost?
    weak var model: SceneEditorWorkspaceModel?
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let host, let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        host.pointer(x: Double(point.x / max(bounds.width, 1)), y: Double(point.y / max(bounds.height, 1)))
        model.hitTest(x: Double(point.x), y: Double(point.y), extending: event.modifierFlags.contains(.shift))
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        host?.pointer(x: Double(point.x / max(bounds.width, 1)), y: Double(point.y / max(bounds.height, 1)))
    }
    override func mouseExited(with event: NSEvent) { host?.pointer(x: -1, y: -1) }
}

private struct SceneSelectionOverlay: View {
    @ObservedObject var model: SceneEditorWorkspaceModel
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if model.isSnapping {
                    Path { path in path.move(to: CGPoint(x: geometry.size.width / 2, y: 0)); path.addLine(to: CGPoint(x: geometry.size.width / 2, y: geometry.size.height)); path.move(to: CGPoint(x: 0, y: geometry.size.height / 2)); path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2)) }
                        .stroke(editorAccent.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 5])).allowsHitTesting(false)
                }
                if let document = model.document, !model.selectedLayers.isEmpty {
                    let layers = model.selectedLayers.compactMap { document.objects.indices.contains($0) ? document.objects[$0] : nil }
                    if let rect = selectionRect(layers: layers, size: geometry.size, resolution: document.resolution) {
                        Rectangle().stroke(editorAccent, lineWidth: 1.3).frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                            .contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 3).onEnded { value in
                                let dx = value.translation.width * CGFloat(document.resolution.0) / max(geometry.size.width, 1)
                                let dy = -value.translation.height * CGFloat(document.resolution.1) / max(geometry.size.height, 1)
                                model.transformSelected(dx: dx, dy: dy)
                            })
                        ForEach(0..<4, id: \.self) { corner in
                            Circle().fill(.white).overlay(Circle().stroke(editorAccent, lineWidth: 1.5)).frame(width: 8, height: 8)
                                .position(handlePoint(corner, rect: rect))
                                .gesture(DragGesture(minimumDistance: 2).onEnded { value in
                                    let signX = (corner == 0 || corner == 2) ? -1.0 : 1.0
                                    let signY = (corner == 0 || corner == 1) ? -1.0 : 1.0
                                    model.transformSelected(widthDelta: Double(value.translation.width * signX * 2 * CGFloat(document.resolution.0) / max(geometry.size.width, 1)), heightDelta: Double(-value.translation.height * signY * 2 * CGFloat(document.resolution.1) / max(geometry.size.height, 1)))
                                })
                        }
                        Circle().fill(editorAccent).frame(width: 7, height: 7).position(x: rect.midX, y: max(10, rect.minY - 18))
                            .gesture(DragGesture(minimumDistance: 3).onEnded { model.transformSelected(rotation: Double($0.translation.width) * 0.5) })
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.allowsHitTesting(model.selectedLayers.isEmpty ? false : true)
    }
    private func selectionRect(layers: [[String: Any]], size: CGSize, resolution: (Int, Int)) -> CGRect? {
        var rects: [CGRect] = []
        for layer in layers {
            guard let origin = vector(layer["origin"]), origin.count >= 2 else { continue }
            let dimension = vector(layer["size"]) ?? [160, 100]
            let scale = vector(layer["scale"]) ?? [1, 1]
            let width = max(18, abs(dimension[0] * (scale.first ?? 1) * Double(size.width) / Double(resolution.0)))
            let height = max(18, abs(dimension[1] * (scale.dropFirst().first ?? 1) * Double(size.height) / Double(resolution.1)))
            let x = origin[0] * Double(size.width) / Double(resolution.0)
            let y = (Double(resolution.1) - origin[1]) * Double(size.height) / Double(resolution.1)
            rects.append(CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height))
        }
        return rects.reduce(nil as CGRect?) { partial, next in partial.map { $0.union(next) } ?? next }
    }
    private func vector(_ value: Any?) -> [Double]? {
        if let text = value as? String { let values = text.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }; return values.count >= 2 ? values : nil }
        if let values = value as? [NSNumber] { return values.map(\.doubleValue) }
        return nil
    }
    private func handlePoint(_ i: Int, rect: CGRect) -> CGPoint {
        switch i { case 0: CGPoint(x: rect.minX, y: rect.minY); case 1: CGPoint(x: rect.maxX, y: rect.minY); case 2: CGPoint(x: rect.minX, y: rect.maxY); default: CGPoint(x: rect.maxX, y: rect.maxY) }
    }
}

private struct EditorScriptReviewSheet: View {
    let folder: URL
    let onApprove: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var review: SceneScriptReview?
    @State private var selected = 0
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 3) { Text("SceneScript Review").font(.system(size: 16, weight: .semibold)); Text("Review is required before this editor preview can run scripts.").font(.system(size: 10)).foregroundStyle(.secondary) }; Spacer(); Button("Close") { dismiss() } }.padding(16)
            Divider()
            if loading { ProgressView("Reading project scripts and JSON…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let review {
                HStack(spacing: 0) {
                    List(selection: $selected) { ForEach(Array(review.sources.enumerated()), id: \.offset) { index, source in VStack(alignment: .leading, spacing: 2) { Text(source.file).font(.system(size: 10, weight: .medium)).lineLimit(1); Text(source.location).font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1) }.tag(index) } }.frame(width: 255)
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        if review.sources.indices.contains(selected) { Text(review.sources[selected].location).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary); TextEditor(text: .constant(review.sources[selected].code)).font(.system(size: 10, design: .monospaced)).disabled(true).scrollContentBackground(.hidden) }
                        else { ContentUnavailableView("No SceneScript source found", systemImage: "checkmark.shield", description: Text("This scene does not contain scripts recognized by Luma's review scanner.")) }
                        if !review.issues.isEmpty { Text(review.issues.joined(separator: "\n")).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(5) }
                    }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack { Text(review.canApprove ? "Complete review · \(review.sources.count) source(s)" : "Approval unavailable · review incomplete").font(.system(size: 10)).foregroundStyle(review.canApprove ? Color.secondary : Color.orange); Spacer(); Button("Approve Scripts") { onApprove(review.fingerprint); dismiss() }.buttonStyle(.borderedProminent).tint(editorAccent).foregroundStyle(.black).disabled(!review.canApprove) }.padding(12)
            } else { ContentUnavailableView("Review failed", systemImage: "exclamationmark.triangle", description: Text(error ?? "The project could not be inspected.")) }
        }.background(editorPanel).task {
            do { review = try await Task.detached(priority: .userInitiated) { try SceneScriptReview.inspect(folder: folder) }.value }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

private struct KeyboardShortcuts: NSViewRepresentable {
    let model: SceneEditorWorkspaceModel
    let requestDelete: () -> Void
    func makeNSView(context: Context) -> NSView { let view = ShortcutView(); view.model = model; view.requestDelete = requestDelete; return view }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? ShortcutView)?.model = model; (nsView as? ShortcutView)?.requestDelete = requestDelete }
    private final class ShortcutView: NSView {
        weak var model: SceneEditorWorkspaceModel?
        var requestDelete: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard let model else { return super.performKeyEquivalent(with: event) }
            if event.keyCode == 51 || event.keyCode == 117 { if !model.selectedLayers.isEmpty { requestDelete?() }; return true }
            guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
            if event.charactersIgnoringModifiers == "z" { if event.modifierFlags.contains(.shift) { model.redo() } else { model.undo() }; return true }
            if event.charactersIgnoringModifiers == "s" { model.save(); return true }
            if event.charactersIgnoringModifiers == "a" { model.selectAll(); return true }
            if event.charactersIgnoringModifiers == "d" { model.duplicateSelection(); return true }
            return super.performKeyEquivalent(with: event)
        }
    }
}

private func layerKind(_ layer: [String: Any]) -> String {
    let keys = Set(layer.keys.map { $0.lowercased() })
    if keys.contains("text") || keys.contains("font") || keys.contains("pointsize") { return "Text" }
    if keys.contains("particle") || keys.contains("particlesystem") { return "Particle" }
    if keys.contains("model") || keys.contains("modelpath") { return "Model" }
    if keys.contains("video") { return "Video" }
    if keys.contains("image") || keys.contains("texture") { return "Image / Material" }
    if keys.contains("effects") { return "Effect" }
    if keys.contains("shape") { return "Shape" }
    return "Scene layer"
}
private func layerIcon(_ layer: [String: Any]) -> String {
    switch layerKind(layer) { case "Text": "textformat"; case "Particle": "sparkles"; case "Model": "cube.transparent"; case "Video": "play.rectangle"; case "Image / Material": "photo"; case "Effect": "camera.filters"; case "Shape": "square.dashed"; default: "square" }
}
private func assetIcon(_ url: URL) -> String {
    if ["png", "jpg", "jpeg", "heic", "webp"].contains(url.pathExtension.lowercased()) { return "photo" }
    if ["mp4", "mov", "m4v", "webm"].contains(url.pathExtension.lowercased()) { return "play.rectangle" }
    if ["wav", "mp3", "ogg"].contains(url.pathExtension.lowercased()) { return "waveform" }
    return "doc"
}
private func assetDisplayName(_ url: URL, relativeTo root: URL) -> String {
    let prefix = root.standardizedFileURL.path + "/"
    let path = url.standardizedFileURL.path
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
}
private func assetSize(_ url: URL) -> String {
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
}

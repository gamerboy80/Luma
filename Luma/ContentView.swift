import SwiftUI
import AppKit
import AVKit
import WebKit

private let accent = Color(red: 0.43, green: 0.88, blue: 0.75)
private let panel = Color(red: 0.075, green: 0.086, blue: 0.105)

enum Destination: String, CaseIterable {
    case library = "My Library", favorites = "Favorites", wallperVideos = "Wallper Videos", editor = "Scene Editor", workshop = "Steam Workshop", displays = "Displays", playlists = "Playlists", lockscreen = "Lock Screen", settings = "Settings"
    var icon: String { switch self { case .library:"square.grid.2x2";case .favorites:"heart";case .wallperVideos:"film.stack";case .editor:"slider.horizontal.3";case .workshop:"gamecontroller";case .displays:"display.2";case .playlists:"rectangle.stack";case .lockscreen:"lock.display";case .settings:"gearshape" } }
}
struct ContentView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var destination: Destination = .library
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 11) { Image(systemName:"waveform.path").font(.system(size:27,weight:.medium)).foregroundStyle(accent); VStack(alignment:.leading,spacing:2) { Text("LUMA").font(.system(size:22,weight:.bold,design:.rounded)).tracking(4); Text("A little more alive.").font(.system(size:10)).foregroundStyle(.secondary) } }.padding(.top,24).padding(.horizontal,20)
                VStack(alignment:.leading,spacing:6) {
                    Text("YOUR SPACE").font(.system(size:9,weight:.semibold)).tracking(2).foregroundStyle(.secondary).padding(.leading,17).padding(.bottom,8)
                    ForEach(Destination.allCases, id:\.self) { item in
                        if item != .wallperVideos || model.wallperVideos.isAvailable {
                            Button { destination = item } label: { HStack(spacing:11) { Image(systemName:item.icon).frame(width:19);Text(item.rawValue).font(.system(size:12,weight:destination == item ? .semibold:.regular));Spacer();if destination == item { Circle().fill(accent).frame(width:5,height:5) } }.foregroundStyle(destination == item ? accent:Color.secondary).padding(.horizontal,14).padding(.vertical,11).background(destination == item ? accent.opacity(0.1):Color.clear,in:RoundedRectangle(cornerRadius:8)) }.buttonStyle(.plain)
                        }
                    }
                }.padding(.horizontal,12)
                Spacer()
                VStack(alignment:.leading,spacing:9) { HStack { Circle().fill(accent).frame(width:5,height:5);Text("MADE FOR YOUR MAC").font(.system(size:8,weight:.semibold)).tracking(1.5) };Text("Local playback.\nA desktop that moves with you.").font(.system(size:10)).foregroundStyle(.secondary).lineSpacing(4) }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(accent.opacity(0.035),in:RoundedRectangle(cornerRadius:10)).padding(12)
            }.frame(width:202).background(Color(red:0.055,green:0.064,blue:0.078))
            Rectangle().fill(.white.opacity(0.055)).frame(width:1)
            VStack(spacing:0) {
                topBar
                Group {
                    switch destination {
                    case .library,.favorites: LibraryView(model:model,library:model.library,favoritesOnly:destination == .favorites)
                    case .wallperVideos: WallperVideosView(catalog:model.wallperVideos,library:model.library)
                    case .editor: SceneEditorHomeView(store:model.editorProjects, library:model.library, assets:model.desktop.assetsURL, preferences:model.library.state.preferences)
                    case .workshop: WorkshopView(workshop:model.workshop,steam:model.steam,library:model.library)
                    case .displays: DisplaysView(library:model.library,desktop:model.desktop)
                    case .playlists: PlaylistView(library:model.library,desktop:model.desktop)
                    case .lockscreen: LockScreenView(model:model,library:model.library,native:model.native,overlay:model.lockOverlay)
                    case .settings: PreferencesView(model:model,library:model.library)
                    }
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
                StatusFooter(library:model.library,desktop:model.desktop)
            }.background(panel)
        }.frame(minWidth:980,minHeight:670)
        .background(LibraryWindowMarker())
        .onAppear {
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.model = model
                delegate.openLibraryWindow = { openWindow(id: "library") }
                delegate.windowLifecycleDidChange()
            }
        }
        .task { await model.wallperVideos.refresh() }
        .alert("Luma",isPresented:Binding(get:{model.library.error != nil || model.wallperVideos.pendingAlert != nil},set:{if !$0 {model.library.error = nil;model.wallperVideos.pendingAlert = nil}})) { Button("OK") { model.library.error = nil;model.wallperVideos.pendingAlert = nil } } message: { Text(model.library.error ?? model.wallperVideos.pendingAlert ?? "") }
    }
    var topBar: some View {
        HStack { Text(destination.rawValue).font(.system(size:13,weight:.semibold));Spacer();Image(systemName:"internaldrive").foregroundStyle(accent);Text("ON THIS MAC").font(.system(size:9,weight:.medium)).tracking(1.3).foregroundStyle(.secondary);Rectangle().fill(.white.opacity(0.1)).frame(width:1,height:15).padding(.horizontal,10);Menu { Button("Video or Image…") { model.library.chooseImport() };Button("Wallpaper Engine Folder…") { model.library.chooseImport(folders:true) } } label: { Label("Import",systemImage:"plus").font(.system(size:11,weight:.semibold)) }.menuStyle(.borderlessButton).fixedSize() }.padding(.horizontal,30).frame(height:58).background(.white.opacity(0.015)).overlay(alignment:.bottom){Divider().opacity(0.4)}
    }
}
struct WallperVideosView: View {
    @ObservedObject var catalog: WallperVideosCatalog
    @ObservedObject var library: LibraryStore
    @State private var selection: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Wallper Videos").font(.system(size: 30, weight: .semibold, design: .rounded))
                        Text("Import copies from ~/Library/Application Support/Wallper/Videos. Your Wallper originals stay in place.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await catalog.refresh() } } label: {
                        Label(catalog.isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise").font(.system(size: 11))
                    }.buttonStyle(.bordered).disabled(catalog.isRefreshing)
                    Button { Task { await catalog.importSelected(selection, library: library) } } label: {
                        Label(catalog.isImporting ? "Importing…" : "Import Selected (\(selection.count))", systemImage: "square.and.arrow.down").font(.system(size: 11, weight: .semibold))
                    }.buttonStyle(.borderedProminent).tint(accent).disabled(selection.isEmpty || catalog.isImporting)
                }
                if let message = catalog.errorMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Some Wallper files need attention", systemImage: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                        Text(message).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                }
                if catalog.videos.isEmpty {
                    ContentUnavailableView(catalog.folderExists ? "No readable videos yet" : "Wallper Videos folder not found", systemImage: "film", description: Text(catalog.folderExists ? "Refresh after making supported videos readable in the Wallper Videos folder." : "Luma looks for supported videos in ~/Library/Application Support/Wallper/Videos."))
                        .frame(height: 280)
                } else {
                    HStack {
                        Text("\(catalog.videos.count) VIDEOS").font(.system(size: 9, weight: .medium)).tracking(1.1).foregroundStyle(.secondary)
                        Spacer()
                        Button(selection.count == catalog.videos.count ? "Deselect All" : "Select All") {
                            selection = selection.count == catalog.videos.count ? [] : Set(catalog.videos.map(\.id))
                        }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(accent)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 18)], spacing: 22) {
                        ForEach(catalog.videos) { video in
                            WallperVideoCard(video: video, selected: selection.contains(video.id)) {
                                if !selection.insert(video.id).inserted { selection.remove(video.id) }
                            }
                        }
                    }
                }
                if !catalog.importResults.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("IMPORT RESULTS").font(.system(size: 9, weight: .semibold)).tracking(1.1).foregroundStyle(.secondary)
                        ForEach(catalog.importResults) { result in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: result.status == .imported ? "checkmark.circle.fill" : result.status == .duplicate ? "arrow.triangle.2.circlepath" : "exclamationmark.circle.fill")
                                    .foregroundStyle(result.status == .failed ? Color.orange : accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.filename).font(.system(size: 11, weight: .medium))
                                    Text(result.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                }
            }.padding(30)
        }
        .task { await catalog.refresh() }
    }
}

private struct WallperVideoCard: View {
    let video: WallperVideoFile
    let selected: Bool
    let toggle: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let thumbnail {
                            Image(nsImage: thumbnail).resizable().scaledToFill()
                        } else {
                            Rectangle().fill(Color(red: 0.025, green: 0.05, blue: 0.08)).overlay {
                                Image(systemName: "play.rectangle.fill").font(.system(size: 34, weight: .light)).foregroundStyle(accent.opacity(0.75))
                            }
                        }
                    }.frame(height: 145).frame(maxWidth: .infinity).clipped()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18)).symbolRenderingMode(.palette).foregroundStyle(selected ? accent : .white, .black.opacity(0.3)).padding(10)
                }.clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? accent : .white.opacity(0.07), lineWidth: selected ? 2 : 1))
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.filename).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(video.relativePath == video.filename ? Self.fileSize(video.byteCount) : "\(video.relativePath) · \(Self.fileSize(video.byteCount))")
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: video.id) {
            let url = video.url
            let data = await Task.detached(priority: .utility) { () -> Data? in
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 720, height: 450)
                guard let cgImage = try? generator.copyCGImage(at: CMTime(seconds: 0.25, preferredTimescale: 600), actualTime: nil) else { return nil }
                return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
            }.value
            if !Task.isCancelled, let data { thumbnail = NSImage(data: data) }
        }
    }

    private static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
struct StatusFooter: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var desktop: DesktopEngine
    var body: some View { HStack(spacing:8) { Circle().fill(library.state.preferences.paused ? Color.orange:accent).frame(width:5,height:5);Text(library.activity ?? desktop.message).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1);Spacer();if library.activity != nil { ProgressView(value:library.progress).frame(width:100);Button("Cancel") { library.cancelDownload() }.font(.system(size:10)) };Button(library.state.preferences.paused ? "Resume":"Pause") { desktop.togglePause() }.font(.system(size:10)).buttonStyle(.plain).foregroundStyle(accent) }.padding(.horizontal,25).frame(height:34).overlay(alignment:.top){Divider().opacity(0.4)} }
}
struct LibraryView: View {
    let model: AppModel
    @ObservedObject var library: LibraryStore
    var favoritesOnly: Bool
    @State private var search = ""
    @State private var filter = "All"
    @State private var sort = "Newest"
    @State private var selected: Wallpaper?
    @State private var urlSheet = false
    @State private var videoURL = ""
    var wallpapers: [Wallpaper] {
        let result = library.state.wallpapers.filter { item in (!favoritesOnly || item.favorite) && (filter == "All" || item.kind.rawValue.capitalized == filter) && (search.isEmpty || ([item.title] + item.tags).joined(separator:" ").localizedCaseInsensitiveContains(search)) }
        return result.sorted { sort == "Name" ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.added > $1.added }
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                HStack(alignment:.top) { VStack(alignment:.leading,spacing:8) { Text(favoritesOnly ? "Your favorites.":"Make room for wonder.").font(.system(size:30,weight:.semibold,design:.rounded));Text(favoritesOnly ? "The wallpapers you keep coming back to.":"Videos, living scenes, and a desktop that feels like you.").font(.system(size:12)).foregroundStyle(.secondary) };Spacer();Button { urlSheet = true } label:{Label("From URL",systemImage:"link").font(.system(size:11))}.buttonStyle(.bordered).tint(accent) }
                HStack { HStack { Image(systemName:"magnifyingglass").foregroundStyle(.secondary);TextField("Search your wallpapers",text:$search).textFieldStyle(.plain).font(.system(size:12));if !search.isEmpty { Button { search = "" } label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain).foregroundStyle(.secondary) } }.padding(11).background(.white.opacity(0.04),in:RoundedRectangle(cornerRadius:9));Picker("Sort",selection:$sort) { Text("Newest").tag("Newest");Text("Name").tag("Name") }.labelsHidden().frame(width:112) }
                HStack(spacing:8) { ForEach(["All","Video","Scene","Web","Image"],id:\.self) { type in Button { filter = type } label: { Text(type).font(.system(size:10,weight:.medium)).padding(.horizontal,14).padding(.vertical,7).background(filter == type ? accent:Color.white.opacity(0.04),in:Capsule()).foregroundStyle(filter == type ? Color.black:Color.secondary) }.buttonStyle(.plain) };Spacer();Text("\(wallpapers.count) WALLPAPERS").font(.system(size:9,weight:.medium)).tracking(1.1).foregroundStyle(.secondary) }
                if wallpapers.isEmpty { ContentUnavailableView(favoritesOnly ? "Nothing saved yet":"A fresh canvas",systemImage:favoritesOnly ? "heart":"photo.on.rectangle.angled",description:Text("Import your own media or discover a wallpaper in Steam Workshop.")).frame(height:320) }
                LazyVGrid(columns:[GridItem(.adaptive(minimum:220),spacing:18)],spacing:22) {
                    ForEach(wallpapers) { wallpaper in
                        WallpaperCard(wallpaper:wallpaper,folder:library.folder(wallpaper),favorite:{library.edit(wallpaper.id){$0.favorite.toggle()}},select:{selected = wallpaper})
                            .contextMenu { Button("Apply to All Displays") { model.desktop.apply(wallpaper,to:nil) };Button("Add / Remove from Playlist") { if library.state.preferences.playlistIDs.contains(wallpaper.id) { library.state.preferences.playlistIDs.removeAll{$0 == wallpaper.id} } else { library.state.preferences.playlistIDs.append(wallpaper.id) };library.save() };Button("Reveal Files") { NSWorkspace.shared.activateFileViewerSelecting([library.folder(wallpaper)]) };if !wallpaper.isBuiltIn { Button("Delete Local Copy",role:.destructive) { library.remove(wallpaper) } } }
                    }
                }
                HStack(spacing:10) { Image(systemName:"sparkles").foregroundStyle(accent);Text("Start with a Luma Original, or import any video you love.").font(.system(size:11)).foregroundStyle(.secondary);Spacer() }.padding(16).background(accent.opacity(0.04),in:RoundedRectangle(cornerRadius:10))
            }.padding(30)
        }
        .sheet(item:$selected) { wallpaper in WallpaperDetail(model:model,library:library,wallpaperID:wallpaper.id) }
        .sheet(isPresented:$urlSheet) { VStack(alignment:.leading,spacing:18) { Text("Download a video").font(.title2.bold());Text("Paste a direct HTTPS link to a video file. The download stays on this Mac.").foregroundStyle(.secondary);TextField("https://example.com/wallpaper.mp4",text:$videoURL).textFieldStyle(.roundedBorder);HStack { Button("Cancel") {urlSheet=false};Spacer();Button("Download") {library.download(videoURL);urlSheet=false}.buttonStyle(.borderedProminent).tint(accent) } }.padding(28).frame(width:520) }
    }
}
struct WallpaperCard: View {
    let wallpaper: Wallpaper
    let folder: URL
    var favorite: () -> Void
    var select: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Button(action:select) { ZStack(alignment:.bottomLeading) { WallpaperArtwork(wallpaper:wallpaper,folder:folder).frame(height:145).clipped();LinearGradient(colors:[.clear,.black.opacity(0.55)],startPoint:.center,endPoint:.bottom);HStack(spacing:5) {Image(systemName:wallpaper.kind == .scene ? "cube.transparent":wallpaper.kind == .video ? "play.fill":"sparkles");Text(wallpaper.kind == .web && wallpaper.isBuiltIn ? "LUMA ORIGINAL":wallpaper.kind.rawValue.uppercased())}.font(.system(size:8,weight:.semibold)).tracking(0.8).foregroundStyle(.white.opacity(0.9)).padding(12) }.clipShape(RoundedRectangle(cornerRadius:10)) }.buttonStyle(.plain)
            HStack { VStack(alignment:.leading,spacing:4) {Text(wallpaper.title).font(.system(size:12,weight:.semibold)).lineLimit(1);Text(wallpaper.isBuiltIn ? "Abstract · Procedural":wallpaper.details).font(.system(size:9)).foregroundStyle(.secondary).lineLimit(1)};Spacer();Button(action:favorite){Image(systemName:wallpaper.favorite ? "heart.fill":"heart").foregroundStyle(wallpaper.favorite ? accent:Color.secondary).font(.system(size:12))}.buttonStyle(.plain) }
        }
    }
}
struct WallpaperArtwork: View {
    let wallpaper: Wallpaper
    let folder: URL
    var body: some View {
        GeometryReader { proxy in
            if let preview = wallpaper.preview, let url = try? Safety.child(preview,under:folder), let image = NSImage(contentsOf:url) { Image(nsImage:image).resizable().scaledToFill().frame(width:proxy.size.width,height:proxy.size.height).clipped() }
            else { ZStack { Color(red:0.025,green:0.05,blue:0.08);EllipticalGradient(colors:[color.opacity(0.8),color.opacity(0.2),.clear],center:.init(x:0.25,y:0.65),startRadiusFraction:0,endRadiusFraction:0.65).rotationEffect(.degrees(-22));EllipticalGradient(colors:[color2.opacity(0.65),.clear],center:.init(x:0.85,y:0.2),startRadiusFraction:0,endRadiusFraction:0.7);Image(systemName:wallpaper.kind == .scene ? "cube.transparent":"waveform.path").font(.system(size:37,weight:.ultraLight)).foregroundStyle(.white.opacity(0.35)) }.frame(width:proxy.size.width,height:proxy.size.height) }
        }
    }
    var color: Color { wallpaper.title.contains("Ember") ? .orange:wallpaper.title.contains("Midnight") ? .indigo:accent }
    var color2: Color { wallpaper.title.contains("Ember") ? .red:.blue }
}
struct WallpaperDetail: View {
    let model: AppModel
    @ObservedObject var library: LibraryStore
    let wallpaperID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var display = "all"
    @State private var properties = "{}"
    @State private var scriptReview = false
    @State private var enablingScripts = false
    @State private var enableScriptsTask: Task<Void, Never>?
    @State private var scriptMessage = ""
    @State private var validation = ""
    var wallpaper: Wallpaper? {library.state.wallpapers.first{$0.id == wallpaperID}}
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            if let wallpaper {
                HStack { VStack(alignment:.leading,spacing:5){Text(wallpaper.title).font(.title2.bold());Text(wallpaper.details).font(.caption).foregroundStyle(.secondary)};Spacer();Button {dismiss()} label:{Image(systemName:"xmark")}.buttonStyle(.plain) }
                WallpaperPreview(model:model,wallpaper:wallpaper).frame(height:330).clipShape(RoundedRectangle(cornerRadius:12))
                if wallpaper.kind == .scene {
                    HStack {
                        Toggle("Run SceneScript",isOn:Binding(get:{wallpaper.runsSceneScript},set:{changeScriptPlayback($0,wallpaper:wallpaper)}))
                            .disabled(!wallpaper.scriptsApproved || enablingScripts)
                        Spacer()
                        if enablingScripts {ProgressView().controlSize(.small)}
                        if wallpaper.scriptsApproved {
                            Button("Revoke Approval", role: .destructive) { revokeScriptApproval(wallpaper) }
                        }
                        Button("Review Scripts…") {scriptMessage = "";scriptReview = true}
                    }.font(.caption)
                    Text(wallpaper.scriptsApproved ? "Approved. Use the toggle to turn scripts on or off. Changed source requires a new review." : "Review and approve this scene's scripts to unlock the toggle. Approval leaves scripts off.").font(.caption2).foregroundStyle(.secondary)
                    if !scriptMessage.isEmpty {Text(scriptMessage).font(.caption2).foregroundStyle(.orange)}
                    DisclosureGroup("User properties (JSON)") { TextEditor(text:$properties).font(.system(size:11,design:.monospaced)).frame(height:85);Button("Save Properties") {saveProperties(wallpaper)};Text(validation).font(.caption2).foregroundStyle(.orange) }
                    .font(.caption)
                }
                HStack {
                    Picker("Apply to",selection:$display) {Text("All Displays").tag("all");ForEach(model.desktop.screens,id:\.persistentID){screen in Text(screen.localizedName).tag(screen.persistentID)}}.frame(width:260)
                    Spacer()
                    Button("Add to Playlist") {if !library.state.preferences.playlistIDs.contains(wallpaper.id){library.state.preferences.playlistIDs.append(wallpaper.id);library.save()}}
                    Button("Set Wallpaper") {saveProperties(wallpaper);model.desktop.apply(library.state.wallpapers.first{$0.id == wallpaper.id} ?? wallpaper,to:display == "all" ? nil:display);dismiss()}.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                }
            }
        }.padding(26).frame(width:760).onAppear {if let wallpaper {properties = wallpaper.propertiesJSON}}
        .sheet(isPresented:$scriptReview) {if let wallpaper {ScriptReviewView(library:library,wallpaper:wallpaper)}}
        .onDisappear {enableScriptsTask?.cancel()}
    }
    func changeScriptPlayback(_ enabled: Bool, wallpaper: Wallpaper) {
        enableScriptsTask?.cancel()
        scriptMessage = ""
        guard enabled else {library.edit(wallpaper.id){$0.trustedScripts = false};return}
        guard let approved = wallpaper.scriptApprovalFingerprint else {return}
        enablingScripts = true
        enableScriptsTask = Task { @MainActor in
            defer {enablingScripts = false}
            do {
                let folder = library.folder(wallpaper)
                let current = try await Task.detached(priority:.userInitiated){try SceneScriptReview.inspect(folder:folder)}.value
                try Task.checkCancellation()
                guard library.state.wallpapers.first(where:{$0.id == wallpaper.id})?.scriptApprovalFingerprint == approved else {return}
                guard current.canApprove, current.fingerprint == approved else {
                    library.edit(wallpaper.id){$0.trustedScripts = false;$0.scriptApprovalFingerprint = nil}
                    scriptMessage = "Scene source changed or could not be read. Review Scripts again before enabling."
                    return
                }
                library.edit(wallpaper.id){$0.trustedScripts = true}
            } catch is CancellationError {} catch {scriptMessage = error.localizedDescription}
        }
    }
    func revokeScriptApproval(_ wallpaper: Wallpaper) {
        enableScriptsTask?.cancel()
        enableScriptsTask = nil
        enablingScripts = false
        library.edit(wallpaper.id) { item in
            item.trustedScripts = false
            item.scriptApprovalFingerprint = nil
        }
        scriptMessage = "Script approval revoked. Scripts are off."
    }
    func saveProperties(_ wallpaper: Wallpaper) {
        guard let data = properties.data(using:.utf8), let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any], object.values.allSatisfy({$0 is String || $0 is NSNumber}) else {validation = "Use a JSON object with string, number, or boolean values.";return}
        library.edit(wallpaper.id){$0.propertiesJSON = properties};validation = "Saved"
    }
}
struct WallpaperPreview: View {
    let model: AppModel
    let wallpaper: Wallpaper
    @State private var player: AVPlayer?
    var body: some View {
        Group {
            if wallpaper.kind == .video {VideoPlayer(player:player)}
            else if wallpaper.kind == .image {WallpaperArtwork(wallpaper:wallpaper,folder:model.library.folder(wallpaper))}
            else {ScenePreview(folder:model.library.folder(wallpaper),assets:model.desktop.assetsURL,wallpaper:wallpaper,preferences:model.library.state.preferences).id(wallpaper.runsSceneScript)}
        }.onAppear {if wallpaper.kind == .video,let url = try? model.library.mediaURL(wallpaper){let p=AVPlayer(url:url);p.isMuted=true;player=p;p.play()}}.onDisappear{player?.pause();player=nil}
    }
}
struct ScenePreview: NSViewRepresentable {
    let folder: URL
    let assets: URL?
    let wallpaper: Wallpaper
    let preferences: AppPreferences
    class Coordinator {var host:SceneHost?}
    func makeCoordinator()->Coordinator {Coordinator()}
    func makeNSView(context:Context)->NSView {
        let container=PreviewContainer();container.wantsLayer=true;container.layer?.masksToBounds=true
        let host=SceneHost(folder:folder,assets:assets,wallpaper:wallpaper,configuration:DisplayConfiguration(),preferences:preferences)
        context.coordinator.host=host;host.webView.frame=container.bounds;host.webView.autoresizingMask=[.width,.height];container.addSubview(host.webView)
        let label=NSTextField(labelWithString:"Loading wallpaper…");label.frame=CGRect(x:16,y:16,width:650,height:40);label.textColor = .secondaryLabelColor;container.addSubview(label)
        host.ready={label.isHidden=true};host.failed={label.stringValue=$0;label.isHidden=false}
        return container
    }
    func updateNSView(_ nsView:NSView,context:Context){}
    static func dismantleNSView(_ nsView:NSView,coordinator:Coordinator){coordinator.host?.stop();coordinator.host=nil}
}
final class PreviewContainer:NSView {
    override var isFlipped:Bool {true}
    override func layout(){super.layout();for view in subviews where view is WKWebView {view.frame=bounds}}
}

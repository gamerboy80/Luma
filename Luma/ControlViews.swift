import SwiftUI
import AppKit
import ServiceManagement

private let tintColor = Color(red:0.43,green:0.88,blue:0.75)

struct WorkshopView: View {
    @ObservedObject var workshop:WorkshopService
    @ObservedObject var steam:SteamCMD
    @ObservedObject var library:LibraryStore
    @State private var showSetup=false
    @State private var secret=""
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20){
                HStack {VStack(alignment:.leading,spacing:7){Text("Find your next atmosphere.").font(.system(size:28,weight:.semibold,design:.rounded));Text("Wallpaper Engine Workshop · Search, download, make it yours.").font(.system(size:12)).foregroundStyle(.secondary)};Spacer();Button("SteamCMD Setup"){showSetup.toggle()}.buttonStyle(.bordered)}
                HStack {TextField("Search Workshop, paste a link, or enter an item ID",text:$workshop.query).textFieldStyle(.roundedBorder).onSubmit{workshop.search()};Picker("Type",selection:$workshop.type){ForEach(["All","Scene","Video","Web"],id:\.self){Text($0)}}.labelsHidden().frame(width:100);Button("Search"){workshop.search()}.buttonStyle(.borderedProminent).tint(tintColor).disabled(workshop.searching)}
                DisclosureGroup("Search connection") {VStack(alignment:.leading,spacing:9){SecureField("Steam Web API key (kept in memory)",text:$workshop.apiKey).textFieldStyle(.roundedBorder);HStack {Link("Get an API key",destination:URL(string:"https://steamcommunity.com/dev/apikey")!);Spacer();Button("Browse Workshop in Browser"){workshop.browseInSteam()}};Text("A key enables text search. Item links and IDs can be looked up without one. Downloading requires a Steam account that owns Wallpaper Engine.").font(.caption).foregroundStyle(.secondary)}.padding(.top,8)}.font(.caption)
                if let error=workshop.error {Label(error,systemImage:"exclamationmark.circle").font(.caption).foregroundStyle(.orange)}
                if workshop.searching {ProgressView("Searching Steam…").padding()}
                if workshop.items.isEmpty && !workshop.searching {ContentUnavailableView("Millions of places to be",systemImage:"globe.americas",description:Text("Search with an API key, or paste a Workshop link above.\nHave a local Steam library? Import its project folders.")).frame(height:220)}
                LazyVGrid(columns:[GridItem(.adaptive(minimum:220),spacing:16)],spacing:20){ForEach(workshop.items){item in
                    VStack(alignment:.leading,spacing:9){
                        AsyncImage(url:URL(string:item.preview_url ?? "")){image in image.resizable().scaledToFill()} placeholder:{ZStack{Color.white.opacity(0.04);Image(systemName:"photo").foregroundStyle(.secondary)}}.frame(height:140).frame(maxWidth:.infinity).clipped().clipShape(RoundedRectangle(cornerRadius:9))
                        Text(item.title ?? "Workshop \(item.id)").font(.system(size:12,weight:.semibold)).lineLimit(2).frame(height:32,alignment:.topLeading)
                        HStack {Text(item.kind).font(.caption2).foregroundStyle(.secondary);Spacer();Link("View",destination:URL(string:"https://steamcommunity.com/sharedfiles/filedetails/?id=\(item.id)")!);Button("Download"){steam.download(item);showSetup=true}.disabled(steam.running || item.kind == "Application")}.font(.caption)
                    }.padding(10).background(.white.opacity(0.025),in:RoundedRectangle(cornerRadius:12))
                }}
                if !workshop.items.isEmpty && workshop.items.count < workshop.total {Button("Load More"){workshop.search(nextPage:true)}.disabled(workshop.searching).frame(maxWidth:.infinity)}
                if showSetup || steam.running {steamConsole}
            }.padding(30)
        }
    }
    var steamConsole:some View {
        VStack(alignment:.leading,spacing:12){
            HStack {Label("SteamCMD",systemImage:"terminal").font(.headline);Spacer();if steam.running {ProgressView().controlSize(.small);Button("Cancel Download",role:.destructive){steam.cancel()}}}
            HStack {Text(steam.folderURL?.path ?? "No SteamCMD folder selected").font(.caption).foregroundStyle(.secondary).lineLimit(1);Spacer();Button("Check Installation"){steam.checkInstallation()}.disabled(steam.running || steam.folderURL == nil);Button("Choose Folder…"){steam.chooseFolder()}.disabled(steam.running)}
            TextField("Steam account name",text:$steam.username).textFieldStyle(.roundedBorder).disabled(steam.running)
            Text("\(steam.status)").font(.caption).foregroundStyle(tintColor).textSelection(.enabled)
            ScrollViewReader {proxy in ScrollView {Text(steam.console).font(.system(size:10,design:.monospaced)).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled);Color.clear.frame(height:1).id("end")}.frame(height:165).padding(12).background(.black.opacity(0.35),in:RoundedRectangle(cornerRadius:8)).onChange(of:steam.console){_,_ in proxy.scrollTo("end",anchor:.bottom)}}
            if steam.running {HStack {SecureField("Password / Steam Guard code requested above",text:$secret).textFieldStyle(.roundedBorder).onSubmit{sendSecret()};Button("Send"){sendSecret()}};Text("Input is sent only to the running SteamCMD process. Passwords and codes are never saved by Luma.").font(.caption2).foregroundStyle(.secondary)}
            HStack {Link("Install SteamCMD",destination:URL(string:"https://developer.valvesoftware.com/wiki/SteamCMD")!);Spacer();Button("Export Terminal Download…"){if let id=Safety.workshopID(workshop.query) ?? workshop.items.first?.id {steam.exportTerminalDownload(itemID:id)}};Button("Import Downloaded Folder…"){library.chooseImport(folders:true)}}.font(.caption)
            Text("If SteamCMD cannot run inside the sandbox or needs Rosetta, use the Terminal download and import the completed project. Steam's availability and account restrictions still apply.").font(.caption2).foregroundStyle(.secondary)
        }.padding(18).background(.white.opacity(0.035),in:RoundedRectangle(cornerRadius:12))
    }
    func sendSecret(){steam.sendSecret(secret);secret=""}
}

struct DisplaysView:View {
    @ObservedObject var library:LibraryStore
    @ObservedObject var desktop:DesktopEngine
    var body:some View {
        ScrollView {VStack(alignment:.leading,spacing:22){Text("Every screen, your way.").font(.system(size:28,weight:.semibold,design:.rounded));Text("Independent playback, framing, and sound for each connected display.").font(.subheadline).foregroundStyle(.secondary)
            ForEach(desktop.screens,id:\.persistentID){screen in
                VStack(alignment:.leading,spacing:16){
                    HStack {Image(systemName:"display").font(.system(size:34,weight:.ultraLight)).foregroundStyle(tintColor);VStack(alignment:.leading,spacing:4){Text(screen.localizedName).font(.headline);Text("\(Int(screen.frame.width * screen.backingScaleFactor)) × \(Int(screen.frame.height * screen.backingScaleFactor)) · \(screen.backingScaleFactor,specifier:"%.0f")×").font(.caption).foregroundStyle(.secondary)};Spacer();Toggle("Enabled",isOn:binding(screen,\.enabled)).toggleStyle(.switch).fixedSize()}
                    Picker("Wallpaper",selection:binding(screen,\.wallpaperID)){Text("None").tag(nil as UUID?);ForEach(library.state.wallpapers){Text($0.title).tag(Optional($0.id))}}
                    Picker("Fit",selection:binding(screen,\.fit)){ForEach(FitMode.allCases,id:\.self){Text($0.rawValue.capitalized).tag($0)}}.pickerStyle(.segmented)
                    slider("Zoom",value:binding(screen,\.scale),range:1...2)
                    slider("Horizontal",value:binding(screen,\.offsetX),range:-0.5...0.5)
                    slider("Vertical",value:binding(screen,\.offsetY),range:-0.5...0.5)
                    slider("Volume",value:binding(screen,\.volume),range:0...1)
                    slider("Video speed",value:binding(screen,\.speed),range:0.25...2)
                    HStack {Toggle("Pause this display",isOn:binding(screen,\.paused));Spacer();Button("Reset Framing"){desktop.configure(screen.persistentID){$0.scale=1;$0.offsetX=0;$0.offsetY=0;$0.fit = .cover}};Button("Reload"){desktop.retry(screen.persistentID)}}.font(.caption)
                    if let reasons=desktop.pauseReasons[screen.persistentID],!reasons.isEmpty {Label(reasons.joined(separator:" · "),systemImage:"pause.circle").font(.caption).foregroundStyle(.orange)}
                }.padding(22).background(.white.opacity(0.035),in:RoundedRectangle(cornerRadius:14))
            }
        }.padding(30)}
    }
    func binding<T>(_ screen:NSScreen,_ path:WritableKeyPath<DisplayConfiguration,T>)->Binding<T>{Binding(get:{(library.state.displays[screen.persistentID] ?? DisplayConfiguration())[keyPath:path]},set:{value in desktop.configure(screen.persistentID){$0[keyPath:path]=value}})}
    func slider(_ title:String,value:Binding<Double>,range:ClosedRange<Double>)->some View{HStack {Text(title).frame(width:95,alignment:.leading);Slider(value:value,in:range);Text(String(format:"%.2f",value.wrappedValue)).monospacedDigit().frame(width:40)}.font(.caption)}
}
struct PlaylistView:View {
    @ObservedObject var library:LibraryStore
    @ObservedObject var desktop:DesktopEngine
    var body:some View {
        Form {
            Section {Text("Let the day unfold.").font(.title.bold());Text("Rotate a selection, or choose a wallpaper for day and night.").foregroundStyle(.secondary)}
            Section("Rotation") {Toggle("Enable playlist",isOn:pref(\.playlistEnabled));Toggle("Shuffle",isOn:pref(\.playlistShuffle));Stepper("Change every \(Int(library.state.preferences.playlistSeconds/60)) minutes",value:pref(\.playlistSeconds),in:60...86400,step:60);Button("Next Wallpaper"){desktop.nextWallpaper()};ForEach(library.state.wallpapers){item in Toggle(item.title,isOn:Binding(get:{library.state.preferences.playlistIDs.contains(item.id)},set:{included in if included{library.state.preferences.playlistIDs.append(item.id)}else{library.state.preferences.playlistIDs.removeAll{$0==item.id}};library.save()}))}}
            Section("Day & Night") {Toggle("Follow time of day",isOn:pref(\.scheduleEnabled));Text("Day & Night takes priority over rotation while enabled.").font(.caption).foregroundStyle(.secondary);Picker("Day wallpaper",selection:pref(\.dayWallpaperID)){Text("None").tag(nil as UUID?);ForEach(library.state.wallpapers){Text($0.title).tag(Optional($0.id))}};Stepper("Day starts at \(library.state.preferences.dayHour):00",value:pref(\.dayHour),in:0...23);Picker("Night wallpaper",selection:pref(\.nightWallpaperID)){Text("None").tag(nil as UUID?);ForEach(library.state.wallpapers){Text($0.title).tag(Optional($0.id))}};Stepper("Night starts at \(library.state.preferences.nightHour):00",value:pref(\.nightHour),in:0...23)}
        }.formStyle(.grouped)
    }
    func pref<T>(_ path:WritableKeyPath<AppPreferences,T>)->Binding<T>{Binding(get:{library.state.preferences[keyPath:path]},set:{library.state.preferences[keyPath:path]=$0;library.save()})}
}
struct LockScreenView:View {
    let model:AppModel
    @ObservedObject var library:LibraryStore
    @ObservedObject var native:NativeLockScreen
    @ObservedObject var overlay:ExperimentalLockScreenOverlay
    @State private var selection:UUID?
    @State private var overlaySelection:UUID?
    @State private var preview:LockPreview?
    private enum LockPreview:Identifiable {
        case wallpaper(Wallpaper), still(URL)
        var id:String { switch self { case .wallpaper(let wallpaper): "wallpaper-\(wallpaper.id)"; case .still(let url): "still-\(url.path)" } }
    }
    private var selectedWallpaper:Wallpaper? { library.state.wallpapers.first(where:{$0.id == selection}) }
    private var selectedOverlayWallpaper:Wallpaper? { library.state.wallpapers.first(where:{$0.id == overlaySelection && $0.kind == .scene}) }
    private var overlayScenes:[Wallpaper] { library.state.wallpapers.filter{$0.kind == .scene} }
    var body:some View {
        Form {
            Section {Label("Beyond the desktop.",systemImage:"lock.display").font(.title.bold());Text("Try an experimental live scene overlay at screen lock, or prepare a static image for System Settings. macOS does not provide a supported API to set a lock-screen-only image separately from the desktop.").foregroundStyle(.secondary)}
            Section("Live Scene Overlay · Experimental") {
                if overlayScenes.isEmpty {
                    ContentUnavailableView("No scenes in your library",systemImage:"rectangle.stack.badge.play",description:Text("Import a Wallpaper Engine scene before enabling the live lock-screen overlay."))
                        .frame(minHeight:100)
                } else {
                    Picker("Scene",selection:$overlaySelection) {
                        Text("Choose a scene").tag(nil as UUID?)
                        ForEach(overlayScenes) { wallpaper in Text(wallpaper.title).tag(Optional(wallpaper.id)) }
                    }
                    .disabled(overlay.enabled)
                }
                Toggle("Enable live lock-screen overlay",isOn:Binding(get:{overlay.enabled},set:{enabled in
                    if enabled {
                        guard let wallpaper=selectedOverlayWallpaper else { library.error="Choose a Wallpaper Engine scene in the Live Scene Overlay section first.";return }
                        overlay.enable(for:wallpaper)
                    } else { overlay.disable() }
                })).disabled(overlaySelection == nil && !overlay.enabled)
                HStack {
                    Button("Preview Scene") { if let wallpaper=selectedOverlayWallpaper { preview = .wallpaper(wallpaper) } }
                        .disabled(selectedOverlayWallpaper == nil)
                    Button("Disable Overlay",role:.destructive) { overlay.disable() }.disabled(!overlay.enabled)
                }
                Text(overlay.status).font(.caption).textSelection(.enabled)
                Text("This uses private SkyLight window and space APIs. macOS can change or block them, and WebKit/WebGL animation may pause or disappear while locked. Luma only enables it when the required APIs resolve; lock, sleep, wake, disable, and normal app exit each stop or resume the renderer and remove the temporary space.").font(.caption).foregroundStyle(.secondary)
                Text("SceneScript keeps the existing Review Scripts approval and Run SceneScript toggle. A content change rebuilds the renderer, which rechecks the approved fingerprint before executing scripts.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Static Fallback") {
                Button("Prepare Static Fallback…") {
                    if let wallpaper=selectedWallpaper { native.prepareStaticFallback(wallpaper,assets:model.desktop.assetsURL) }
                }.disabled(selection == nil || native.busy)
                if native.busy { ProgressView(value:native.progress) }
                if let url=native.staticFallbackURL {
                    LabeledContent("Source",value:native.staticFallbackSource)
                    HStack {
                        Button("Preview Still") { preview = .still(url) }
                        Button("Open Wallpaper Settings") { native.openSettings() }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button("Remove Still",role:.destructive) { do { try native.removeStaticFallback() } catch { library.error=error.localizedDescription } }
                    }
                }
                Text("For a scene, Luma prefers a source image, then a representative frame from a video, then a captured frame of the rendered scene. The PNG is a preview/export: macOS has no supported public API to set a separate lock-screen-only photo, so Luma does not apply it or change your desktop wallpaper. Selecting it in System Settings may also change the desktop. If you selected this PNG there, choose another wallpaper before removing the file in Luma; Luma cannot track or restore that manual selection.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Native Wallpaper") {
                Picker("Wallpaper",selection:$selection){Text("Choose a video, image, or scene").tag(nil as UUID?);ForEach(library.state.wallpapers.filter{$0.kind == .video || $0.kind == .scene || $0.kind == .image}){Text($0.title).tag(Optional($0.id))}}
                Picker("Scene lock screen", selection: $native.sceneMode) { ForEach(SceneLockScreenMode.allCases) { Text($0.title).tag($0) } }
                Text("If loop rendering fails, Luma tries a scene video or image, then a captured still, then the project preview. Capture mode tries the still first. Still fallbacks remain visually static.").font(.caption).foregroundStyle(.secondary)
                Stepper("Scene loop: \(native.sceneSeconds) seconds",value:$native.sceneSeconds,in:5...120,step:5)
                Text("Exported scenes preserve their rendered appearance. Cursor interaction, clocks, and audio response are frozen into the recorded loop; a seamless boundary depends on the scene.").font(.caption).foregroundStyle(.secondary)
                Toggle("Also update the native wallpaper selection",isOn:$native.selectAutomatically)
                Text("When macOS links the desktop and idle wallpaper, this also changes the native desktop still. Luma preserves that link and unrelated settings. Leave this off to select the Luma collection in System Settings yourself.").font(.caption).foregroundStyle(.secondary)
                HStack {Button("Connect Wallpaper Folder…"){native.chooseRoot()};Spacer();Button("Install for Lock Screen…"){if let wallpaper=library.state.wallpapers.first(where:{$0.id == selection}){native.install(wallpaper,assets:model.desktop.assetsURL)}}.buttonStyle(.borderedProminent).tint(tintColor).disabled(selection == nil || native.busy)}
                if native.busy {ProgressView(value:native.progress);Button("Cancel"){native.cancel()}}
                Text(native.status).font(.caption).textSelection(.enabled)
                if let receipt=native.receipt {LabeledContent("Last installed",value:receipt.title); if let source = receipt.sourceDescription { LabeledContent("Source used", value: source) }}
            }
            Section("Compatibility & Recovery") {
                Text("Requires macOS 26 or newer. This integration uses the Aerials catalog format, which Apple does not document as a custom wallpaper API. Luma verifies HEVC temporal groups, uses fresh asset IDs, and backs up the catalog before changing it.").font(.caption).foregroundStyle(.secondary)
                Text("The older Aerial collection route remains separate from the live overlay and static PNG fallback. macOS controls wallpaper motion and sleep; FileVault's preboot login screen is separate.").font(.caption).foregroundStyle(.secondary)
                HStack {Button("Open Wallpaper Settings"){native.openSettings()};Button("Reveal Backups"){NSWorkspace.shared.open(library.root.appendingPathComponent("NativeBackups"))};Spacer();Button("Restore Previous Wallpaper & Remove Luma Collection",role:.destructive){native.removeInstalled()}.disabled(native.busy || !native.hasManagedChanges)}
                Text("If macOS keeps an old catalog in memory, log out and back in after installing. Luma does not repeatedly restart wallpaper services or override a later choice made in System Settings.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).onAppear {
            if let id=overlay.wallpaperID {
                overlaySelection=id
                selection=id
            } else if overlaySelection == nil {
                overlaySelection=overlayScenes.first?.id
            }
        }
            .sheet(item:$preview) { item in
                switch item {
                case .wallpaper(let wallpaper): WallpaperPreview(model:model,wallpaper:wallpaper).frame(minWidth:720,minHeight:420).padding(18)
                case .still(let url):
                    VStack(alignment:.leading,spacing:12) {
                        Text("Static Lock-Screen Fallback").font(.headline)
                        if let image=NSImage(contentsOf:url) { Image(nsImage:image).resizable().aspectRatio(contentMode:.fit).frame(maxWidth:.infinity,maxHeight:.infinity) }
                        else { ContentUnavailableView("Still Image Unavailable",systemImage:"photo") }
                        Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(22).frame(minWidth:720,minHeight:460)
                }
            }
    }
}
struct PreferencesView:View {
    let model:AppModel
    @ObservedObject var library:LibraryStore
    @State private var loginEnabled=LaunchAtLoginBaseline.isRegistered
    @State private var loginServiceMessage:String?
    @State private var showingClearData = false
    var body:some View {
        Form {
            Section("Playback & Performance") {
                Toggle("Restore wallpapers when Luma opens",isOn:pref(\.restoreAtLaunch))
                Toggle("Pause on battery",isOn:pref(\.pauseOnBattery))
                Toggle("Pause in Low Power Mode",isOn:pref(\.pauseOnLowPower))
                Toggle("Pause behind fullscreen apps",isOn:pref(\.pauseWhenFullscreen))
                Toggle("Pause when the CPU is busy",isOn:pref(\.pauseWhenBusy))
                if library.state.preferences.pauseWhenBusy {Slider(value:pref(\.cpuThreshold),in:50...99){Text("CPU threshold")};Text("Threshold: \(Int(library.state.preferences.cpuThreshold))%").font(.caption)}
                Toggle("Retina rendering for scenes",isOn:pref(\.retina))
                Picker("Scene frame rate",selection:pref(\.sceneFPS)){Text("24 fps").tag(24);Text("30 fps").tag(30);Text("60 fps").tag(60)}
                Toggle("Mouse parallax for scenes",isOn:pref(\.mouseParallax))
                Toggle("Sync a still frame to the native desktop",isOn:pref(\.syncDesktopStill))
                Text("Still-frame sync helps the menu bar match your wallpaper. Your previous desktop image is restored when you stop Luma, provided the selection still belongs to Luma.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Wallpaper Engine") {Button("Choose Shared Engine Assets…"){model.chooseAssets()};Text(model.desktop.assetsURL?.path ?? "Optional: select the assets folder from your own Wallpaper Engine installation for built-in textures, fonts, and shaders.").font(.caption).foregroundStyle(.secondary).textSelection(.enabled);Text("Scenes run through bundled WebWallGL. Layers, particles, effects, models and SceneScript are supported by that renderer; individual projects may use features it cannot reproduce. System-audio capture and Now Playing synchronization are not connected in this build.").font(.caption).foregroundStyle(.secondary)}
            Section("General") {
                Toggle("Launch Luma at login",isOn:$loginEnabled).onChange(of:loginEnabled){_,value in
                    do {
                        try LaunchAtLoginBaseline.setEnabled(value)
                        loginEnabled = LaunchAtLoginBaseline.isRegistered
                        loginServiceMessage = LaunchAtLoginBaseline.requiresApproval
                            ? "macOS registered Luma. Allow it in System Settings → General → Login Items to finish setup."
                            : nil
                    } catch {
                        loginEnabled = LaunchAtLoginBaseline.isRegistered
                        loginServiceMessage = error.localizedDescription
                        library.error = error.localizedDescription
                    }
                }
                if LaunchAtLoginBaseline.requiresApproval {
                    Text("macOS requires approval. Allow Luma in System Settings → General → Login Items.").font(.caption).foregroundStyle(.orange)
                } else if let loginServiceMessage {
                    Text(loginServiceMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button("Reveal Library Files"){NSWorkspace.shared.open(library.root)}
                Button("Stop Desktop Wallpapers"){model.desktop.stopAll()}
                Button("Clear Luma Data…",role:.destructive){showingClearData = true}
            }
            Section("Catalog") {Text("Static inspection found Wallper's CDN roots and backend host, but not a verifiable search route, request schema, or signature requirements. Luma skips the connection instead of sending guessed requests. Local imports and direct video URLs remain available.").font(.caption).foregroundStyle(.secondary);Link("Visit Wallper",destination:URL(string:"https://www.wallper.app/")!)}
            Section("Diagnostics") {Text(model.desktop.diagnostics.suffix(12).joined(separator:"\n").isEmpty ? "No playback warnings.":model.desktop.diagnostics.suffix(12).joined(separator:"\n")).font(.system(size:10,design:.monospaced)).textSelection(.enabled);Button("Copy Diagnostics"){NSPasteboard.general.clearContents();NSPasteboard.general.setString(model.desktop.diagnostics.joined(separator:"\n"),forType:.string)}}
            Section("Luma 1.0") {Text("SwiftUI · AppKit · AVFoundation · WebWallGL").font(.caption).foregroundStyle(.secondary);Link("WebWallGL · MIT License",destination:URL(string:"https://github.com/oneincase/webwallgl")!)}
        }.formStyle(.grouped)
        .onAppear { synchronizeLoginAtLogin() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in synchronizeLoginAtLogin() }
        .sheet(isPresented:$showingClearData) {
            ClearDataReviewView(model:model)
                .frame(width:620,height:570)
        }
    }
    func pref<T>(_ path:WritableKeyPath<AppPreferences,T>)->Binding<T>{Binding(get:{library.state.preferences[keyPath:path]},set:{library.state.preferences[keyPath:path]=$0;library.save()})}
    private func synchronizeLoginAtLogin() {
        loginEnabled = LaunchAtLoginBaseline.isRegistered
        loginServiceMessage = LaunchAtLoginBaseline.requiresApproval
            ? "macOS registered Luma, but it still needs approval in System Settings → General → Login Items."
            : nil
    }
}

private struct ClearDataReviewView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?
    @State private var isClearing = false
    private var plan: ClearDataPlan { model.clearDataPlan() }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            VStack(alignment:.leading,spacing:6) {
                Text("Clear Luma Data").font(.title2.bold())
                Text("Review the files and system settings below. Nothing changes until you press Clear Data and Quit. Luma removes its managed data, restores recorded changes, and stays installed. It will not recreate its library during shutdown.").font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    GroupBox("Files and settings to remove or reset") {
                        VStack(alignment:.leading,spacing:9) {
                            ForEach(plan.remove,id:\.self) { item in Label(item,systemImage:"trash").font(.caption).frame(maxWidth:.infinity,alignment:.leading) }
                        }.padding(.top,5)
                    }
                    GroupBox("Changes Luma will restore") {
                        VStack(alignment:.leading,spacing:9) {
                            ForEach(plan.restore,id:\.self) { item in Label(item,systemImage:"arrow.uturn.backward").font(.caption).frame(maxWidth:.infinity,alignment:.leading) }
                        }.padding(.top,5)
                    }
                    Text("SteamCMD, its installation folder, Steam library files, retained failed Workshop downloads, and unrecognized files are preserved.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let failure { Label(failure,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isClearing)
                Spacer()
                Button("Clear Data and Quit",role:.destructive) {
                    isClearing = true; failure = nil
                    Task {
                        do {
                            try await model.clearLumaData()
                            dismiss()
                            DispatchQueue.main.async { NSApp.terminate(nil) }
                        }
                        catch { failure = error.localizedDescription; isClearing = false }
                    }
                }.keyboardShortcut(.defaultAction).disabled(isClearing)
                if isClearing { ProgressView().controlSize(.small) }
            }
        }.padding(22)
    }
}

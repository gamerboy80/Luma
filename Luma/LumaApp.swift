import SwiftUI
import AppKit
import Combine
import ServiceManagement

struct ClearDataPlan {
    var remove: [String]
    var restore: [String]
}

@MainActor enum LaunchAtLoginBaseline {
    private static let originalKey = "luma.clearData.launchAtLoginOriginal"
    private static let appliedKey = "luma.clearData.launchAtLoginApplied"
    private static var defaults: UserDefaults { .standard }
    private static var service: SMAppService { .mainApp }
    static var isRegistered: Bool { service.status == .enabled || service.status == .requiresApproval }
    static var requiresApproval: Bool { service.status == .requiresApproval }
    static func captureIfNeeded() {
        guard defaults.object(forKey: originalKey) == nil else { return }
        defaults.set(isRegistered, forKey: originalKey)
    }
    static func setEnabled(_ enabled: Bool) throws {
        let current = isRegistered
        if let lastApplied = defaults.object(forKey: appliedKey) as? Bool, current != lastApplied {
            defaults.set(current, forKey: originalKey)
        } else if defaults.object(forKey: originalKey) == nil {
            defaults.set(current, forKey: originalKey)
        }
        if current != enabled {
            if enabled { try service.register() } else { try service.unregister() }
        }
        guard isRegistered == enabled else {
            throw LumaError(enabled
                ? "macOS did not register Luma at login. Check System Settings → General → Login Items and try again."
                : "macOS still lists Luma as a login item. Try turning it off again in System Settings → General → Login Items.")
        }
        defaults.set(enabled, forKey: appliedKey)
    }
    static var clearDataDescription: String? {
        guard let previous = defaults.object(forKey: originalKey) as? Bool,
              let lastApplied = defaults.object(forKey: appliedKey) as? Bool,
              isRegistered == lastApplied, previous != lastApplied else { return nil }
        return previous ? "Re-enable Luma at login, matching its state before Luma changed that setting." : "Disable Luma at login, matching its state before Luma changed that setting."
    }
    static func restore() throws {
        guard let previous = defaults.object(forKey: originalKey) as? Bool,
              let lastApplied = defaults.object(forKey: appliedKey) as? Bool else { return }
        guard isRegistered == lastApplied else {
            defaults.set(isRegistered, forKey: originalKey)
            defaults.removeObject(forKey: appliedKey)
            return
        }
        if previous != lastApplied {
            if previous { try service.register() } else { try service.unregister() }
        }
    }
    static func clearTrackingAfterClear() {
        defaults.removeObject(forKey: originalKey)
        defaults.removeObject(forKey: appliedKey)
    }
}

@MainActor final class AppModel: ObservableObject {
    let library: LibraryStore
    let editorProjects: EditorProjectStore
    let desktop: DesktopEngine
    let workshop = WorkshopService()
    let steam = SteamCMD()
    let native: NativeLockScreen
    let lockOverlay: ExperimentalLockScreenOverlay
    let wallperVideos: WallperVideosCatalog
    private var assetsAccess: URL?
    init() {
        LaunchAtLoginBaseline.captureIfNeeded()
        let library = LibraryStore(); self.library = library
        wallperVideos = WallperVideosCatalog()
        editorProjects = EditorProjectStore(library: library)
        let desktop = DesktopEngine(library: library); self.desktop = desktop
        native = NativeLockScreen(library: library)
        if let bookmark = Bookmark.savedData(forKey: "engine-assets"), let url = try? Bookmark.resolve(bookmark) {
            if url.startAccessingSecurityScopedResource() { assetsAccess = url }
            desktop.assetsURL = url
        }
        lockOverlay = ExperimentalLockScreenOverlay(library: library, assets: { desktop.assetsURL })
        steam.downloaded = { [weak self] folder, id in
            guard let self else { throw LumaError("Luma closed before the downloaded wallpaper could be imported.") }
            try await self.library.importURL(folder, workshopID: id)
        }
    }
    func chooseAssets() {
        do {
            guard let url = try Bookmark.chooseFolder(message: "Choose the assets folder from your own Wallpaper Engine installation (steamapps/common/wallpaper_engine/assets). These resources are used only on this Mac.", defaultsKey: "engine-assets") else { return }
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("materials").path) else { library.error = "Choose the assets folder containing materials, shaders, and fonts."; return }
            assetsAccess?.stopAccessingSecurityScopedResource()
            if url.startAccessingSecurityScopedResource() { assetsAccess = url }
            desktop.assetsURL = url
            for screen in desktop.screens { desktop.retry(screen.persistentID) }
        } catch { library.error = error.localizedDescription }
    }
    func clearDataPlan() -> ClearDataPlan {
        let fm = FileManager.default
        let root = library.root
        let customCount = library.state.wallpapers.filter { !$0.isBuiltIn }.count
        var remove = ["\(root.appendingPathComponent("Media").path) — removes \(customCount) imported or downloaded wallpaper folders and Luma Original copies listed in Luma's library. Unrecognized entries are preserved.",
                      "\(root.appendingPathComponent("library.json").path) — removes preferences, favorites, playlists, and display assignments. Luma quits after clearing and does not recreate its library during shutdown; reopening it later creates a fresh default library.",
                      "The Luma application support folder is removed only if it is empty after the listed cleanup. Unrecognized files are preserved. The Luma app itself stays installed."]
        let desktopStills = root.appendingPathComponent("DesktopStills", isDirectory: true)
        if fm.fileExists(atPath: desktopStills.path) { remove.append("\(desktopStills.path) — removes recorded Luma desktop stills and its ownership record after restoring the previous wallpaper. Other files are preserved.") }
        let nativeCache = root.appendingPathComponent("NativeCache", isDirectory: true)
        if fm.fileExists(atPath: nativeCache.path) { remove.append("\(nativeCache.path) — removes temporary export folders carrying Luma's ownership marker. Other entries are preserved.") }
        let editorProjects = root.appendingPathComponent("EditorProjects", isDirectory: true)
        if fm.fileExists(atPath: editorProjects.path) { remove.append("\(editorProjects.path) — removes \(self.editorProjects.projects.count) editor projects created or imported into Luma and their copied assets. Unknown entries are preserved.") }
        let fallbackImage = root.appendingPathComponent("LockScreenFallbacks/lock-screen-still.png")
        if fm.fileExists(atPath: fallbackImage.path) { remove.append("\(fallbackImage.path) — removes the static lock-screen preview created by Luma after disabling the experimental overlay.") }
        let nativeBackups = root.appendingPathComponent("NativeBackups", isDirectory: true)
        if fm.fileExists(atPath: nativeBackups.path) { remove.append("\(nativeBackups.path) — removes Luma's recorded wallpaper catalog snapshots and selection backups after restoration. Other entries are preserved.") }
        let receipt = root.appendingPathComponent("native-receipt.json")
        if fm.fileExists(atPath: receipt.path) { remove.append("\(receipt.path) — Luma's native wallpaper install record.") }
        remove.append("Luma's saved SteamCMD, Wallpaper Engine assets, and native wallpaper folder bookmarks in Luma's settings.")
        if FileManager.default.fileExists(atPath: Bookmark.legacyPreferencesURL.path) {
            remove.append("The same three Luma bookmark values in the old Luma preferences file; other values in that file are preserved.")
        }
        remove.append("Luma's Steam Web API key and Workshop search state from memory.")

        var restore = desktop.clearDataRestorePlan() + native.clearDataRestorePlan()
        if lockOverlay.enabled { restore.append("Stop Luma's experimental lock-screen windows and remove the private SkyLight space.") }
        if let login = LaunchAtLoginBaseline.clearDataDescription { restore.append(login) }
        if restore.isEmpty { restore.append("No recorded desktop image, native wallpaper selection, or launch-at-login change needs restoring.") }
        return ClearDataPlan(remove: remove, restore: restore)
    }
    func clearLumaData() async throws {
        guard !steam.running, !native.busy, library.activity == nil, !library.hasDownloadInProgress else {
            throw LumaError("Wait for downloads, imports, or native wallpaper exports to finish before clearing Luma data.")
        }
        desktop.beginClearData()
        do {
            try lockOverlay.stopForClearData()
            try native.restoreManagedChangesForClearData()
            try native.removeStaticFallback()
            try editorProjects.clearManagedProjects()
            try await desktop.prepareForClearData()
            try LaunchAtLoginBaseline.restore()
            try Bookmark.clearSavedBookmarks()

            assetsAccess?.stopAccessingSecurityScopedResource(); assetsAccess = nil; desktop.assetsURL = nil
            steam.resetConfiguration()
            workshop.resetForClearData()
            native.resetForClearData()
            try library.resetForClearData()
            LaunchAtLoginBaseline.clearTrackingAfterClear()
        } catch {
            desktop.resumeAfterClearDataFailure()
            throw error
        }
    }
    func shutdown() { lockOverlay.shutdown(); desktop.shutdown(); steam.cancel(); native.cancel(); assetsAccess?.stopAccessingSecurityScopedResource() }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    var openLibraryWindow: (() -> Void)?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var hasShownMainWindow = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let center = NotificationCenter.default
        let windowEvents: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification
        ]
        for event in windowEvents {
            lifecycleObservers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleDockPolicyUpdate()
            })
        }
        for event in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            lifecycleObservers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleDockPolicyUpdate()
            })
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) { scheduleDockPolicyUpdate() }
    func windowLifecycleDidChange() { scheduleDockPolicyUpdate() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers.removeAll()
        model?.shutdown()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.setActivationPolicy(.regular)
        sender.unhide(nil)
        if !flag {
            if let window = sender.windows.first(where: { $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized) }) {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            } else {
                openLibraryWindow?()
            }
        }
        return true
    }

    private func scheduleDockPolicyUpdate() {
        DispatchQueue.main.async { [weak self] in self?.updateDockPolicy() }
    }

    private func updateDockPolicy() {
        let hasVisibleLumaWindow = !NSApp.isHidden && NSApp.windows.contains {
            $0.styleMask.contains(.titled) && $0.isVisible && !$0.isMiniaturized
        }
        if hasVisibleLumaWindow { hasShownMainWindow = true }
        // Leave the initial Dock policy alone until SwiftUI has actually shown
        // the first window; the WindowGroup may be created after launch callbacks.
        guard hasShownMainWindow else { return }
        let desired: NSApplication.ActivationPolicy = hasVisibleLumaWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)
    }
}

@main struct LumaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Luma", id: "library") {
            ContentView(model: model).preferredColorScheme(.dark)
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            LibraryCommands()
            CommandGroup(replacing: .newItem) {
                Button("Import Wallpaper…") { model.library.chooseImport() }.keyboardShortcut("o")
                Button("Import Project Folder…") { model.library.chooseImport(folders: true) }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Wallpaper") {
                Button(model.library.state.preferences.paused ? "Resume All" : "Pause All") { model.desktop.togglePause() }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Next in Playlist") { model.desktop.nextWallpaper() }.keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                Button("Stop Desktop Wallpapers") { model.desktop.stopAll() }
            }
        }
        Settings { PreferencesView(model: model, library: model.library).frame(width: 650, height: 640).preferredColorScheme(.dark) }
        MenuBarExtra("Luma", systemImage: "waveform.path") { MenuContent(model: model, library: model.library, desktop: model.desktop) }
    }
}
struct MenuContent: View {
    let model: AppModel
    @ObservedObject var library: LibraryStore
    @ObservedObject var desktop: DesktopEngine
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Luma · Live Wallpapers")
        Button("Open Library") { LumaWindowPresenter.openLibrary(openWindow) }
        Divider()
        Button(library.state.preferences.paused ? "Resume Wallpapers" : "Pause Wallpapers") { desktop.togglePause() }
        Button("Next in Playlist") { desktop.nextWallpaper() }.disabled(library.state.preferences.playlistIDs.isEmpty)
        ForEach(desktop.screens, id: \.persistentID) { screen in
            Menu(screen.localizedName) {
                let configuration = library.state.displays[screen.persistentID] ?? DisplayConfiguration()
                Button(configuration.paused ? "Resume" : "Pause") { desktop.configure(screen.persistentID) { $0.paused.toggle() } }
                Button("Reload") { desktop.retry(screen.persistentID) }
            }
        }
        Button("Stop Desktop Wallpapers") { desktop.stopAll() }
        Divider()
        Button("Quit Luma") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct LibraryCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Open Library") { LumaWindowPresenter.openLibrary(openWindow) }.keyboardShortcut("1", modifiers: .command)
        }
    }
}

@MainActor enum LumaWindowPresenter {
    static func openLibrary(_ openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        let existing = NSApp.windows.first { $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized) }
        if let existing {
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "library")
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            if let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized) }) {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

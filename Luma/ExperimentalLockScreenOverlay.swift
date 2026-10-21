import AppKit
import Combine
import Darwin
import Foundation
import CryptoKit

/// A private-API experiment. macOS does not promise that a third-party window
/// will remain visible or animate on the authenticated lock screen.
@MainActor final class ExperimentalLockScreenOverlay: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var status = "Live lock-screen overlay is off."
    @Published private(set) var details = ""
    @Published private(set) var wallpaperID: UUID?

    private static let enabledKey = "luma.experimentalLockOverlay.enabled"
    private static let wallpaperKey = "luma.experimentalLockOverlay.wallpaperID"
    private let library: LibraryStore
    private let assets: () -> URL?
    private var privateSpace: SkyLightLockSpace?
    private var surfaces: [String: LockSceneSurface] = [:]
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var subscriptions = Set<AnyCancellable>()
    private var locked = false
    private var sleeping = false
    private var shuttingDown = false
    private var activeWallpaper: Wallpaper?
    private var activeConfigurationIdentity: String?
    private var sessionTask: Task<Void, Never>?
    private var lastDiagnostic = ""

    init(library: LibraryStore, assets: @escaping () -> URL?) {
        self.library = library
        self.assets = assets
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        wallpaperID = UUID(uuidString: UserDefaults.standard.string(forKey: Self.wallpaperKey) ?? "")
        locked = Self.sessionLocked() ?? false

        let distributed = DistributedNotificationCenter.default()
        observe(Notification.Name("com.apple.screenIsLocked"), center: distributed) { [weak self] in self?.screenLocked() }
        observe(Notification.Name("com.apple.screenIsUnlocked"), center: distributed) { [weak self] in self?.screenUnlocked() }
        observe(NSApplication.didChangeScreenParametersNotification, center: .default) { [weak self] in self?.rebuildForScreenChange() }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.sessionDidBecomeActiveNotification, center: workspace) { [weak self] in self?.screenUnlocked() }
        observe(NSWorkspace.willSleepNotification, center: workspace) { [weak self] in self?.sleeping = true; self?.updateVisibility() }
        observe(NSWorkspace.screensDidSleepNotification, center: workspace) { [weak self] in self?.sleeping = true; self?.updateVisibility() }
        observe(NSWorkspace.didWakeNotification, center: workspace) { [weak self] in self?.sleeping = false; self?.updateVisibility() }
        observe(NSWorkspace.screensDidWakeNotification, center: workspace) { [weak self] in self?.sleeping = false; self?.updateVisibility() }

        library.$state.sink { [weak self] _ in
            Task { @MainActor in self?.refreshSelectedWallpaper() }
        }.store(in: &subscriptions)

        if enabled { restoreAfterLaunch() }
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in action() }
        }
        observers.append((center, token))
    }

    func enable(for wallpaper: Wallpaper) {
        guard wallpaper.kind == .scene else { status = "Choose a Wallpaper Engine scene for the live overlay."; return }
        shuttingDown = false
        do {
            try build(for: wallpaper)
            enabled = true
            wallpaperID = wallpaper.id
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
            UserDefaults.standard.set(wallpaper.id.uuidString, forKey: Self.wallpaperKey)
            status = "Experimental overlay is armed for \(wallpaper.title). It appears only while macOS is locked."
            updateVisibility()
        } catch {
            cleanupRuntime()
            enabled = false
            wallpaperID = nil
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            UserDefaults.standard.removeObject(forKey: Self.wallpaperKey)
            status = "Live overlay unavailable: \(error.localizedDescription) Use Prepare Static Fallback instead."
        }
    }

    func disable() {
        enabled = false
        wallpaperID = nil
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        UserDefaults.standard.removeObject(forKey: Self.wallpaperKey)
        let cleanupError = cleanupRuntime()
        status = cleanupError.map { "Overlay disabled, but SkyLight cleanup reported: \($0)" } ?? "Live lock-screen overlay is off; its windows and private space were removed."
    }

    func stopForClearData() throws {
        enabled = false
        wallpaperID = nil
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        UserDefaults.standard.removeObject(forKey: Self.wallpaperKey)
        if let cleanupError = cleanupRuntime() { throw LumaError("Could not clean up the live lock-screen overlay: \(cleanupError)") }
        status = "Live lock-screen overlay is off."
    }

    /// Called from application termination. Preserve the user's opt-in so a normal
    /// relaunch can restore it, while removing all owned windows and spaces now.
    func shutdown() {
        shuttingDown = true
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        subscriptions.removeAll()
        _ = cleanupRuntime()
    }

    private func restoreAfterLaunch() {
        guard let id = wallpaperID, let wallpaper = library.state.wallpapers.first(where: { $0.id == id }), wallpaper.kind == .scene else {
            enabled = false
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            UserDefaults.standard.removeObject(forKey: Self.wallpaperKey)
            status = "The saved live overlay wallpaper is no longer in the library. Choose a scene to enable it again."
            return
        }
        do {
            try build(for: wallpaper)
            status = "Experimental overlay restored for \(wallpaper.title). It appears only while macOS is locked."
            updateVisibility()
        } catch {
            enabled = false
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            UserDefaults.standard.removeObject(forKey: Self.wallpaperKey)
            status = "Could not restore the experimental overlay: \(error.localizedDescription) Use Prepare Static Fallback instead."
        }
    }

    private func refreshSelectedWallpaper() {
        guard !shuttingDown, enabled, let id = wallpaperID else { return }
        guard let wallpaper = library.state.wallpapers.first(where: { $0.id == id }), wallpaper.kind == .scene else {
            disable()
            status = "The scene was removed from Luma's library; the overlay was disabled."
            return
        }
        guard renderIdentity(activeWallpaper) != renderIdentity(wallpaper)
                || activeConfigurationIdentity != configurationIdentity() else { return }
        do {
            try build(for: wallpaper)
            status = "Overlay refreshed for the current scene and script approval."
            updateVisibility()
        } catch {
            disable()
            status = "Overlay stopped after the scene changed: \(error.localizedDescription) Use Prepare Static Fallback instead."
        }
    }

    private func renderIdentity(_ wallpaper: Wallpaper?) -> String? {
        guard let wallpaper else { return nil }
        return [wallpaper.id.uuidString, wallpaper.folder, wallpaper.entry, wallpaper.preview ?? "", wallpaper.propertiesJSON,
                String(wallpaper.trustedScripts), wallpaper.scriptApprovalFingerprint ?? ""].joined(separator: "\u{1f}")
    }

    private func configurationIdentity() -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let preferences = (try? encoder.encode(library.state.preferences)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "invalid"
        let displays = library.state.displays.keys.sorted().compactMap { key -> String? in
            guard let config = library.state.displays[key], let data = try? encoder.encode(config) else { return nil }
            return "\(key):\(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())"
        }.joined(separator: "|")
        return "\(preferences)|\(displays)|\(assets()?.standardizedFileURL.path ?? "")"
    }

    private func build(for wallpaper: Wallpaper) throws {
        let oldError = cleanupRuntime()
        if let oldError { throw LumaError("The previous overlay could not be removed: \(oldError)") }
        guard !NSScreen.screens.isEmpty else { throw LumaError("No displays are available for the lock-screen overlay.") }
        lastDiagnostic = ""
        let space = try SkyLightLockSpace()
        privateSpace = space
        var newSurfaces: [String: LockSceneSurface] = [:]
        do {
            for screen in NSScreen.screens {
                let config = library.state.displays[screen.persistentID] ?? DisplayConfiguration()
                let host = SceneHost(folder: library.folder(wallpaper), assets: assets(), wallpaper: wallpaper,
                                    configuration: config, preferences: library.state.preferences)
                let surface = LockSceneSurface(screen: screen, host: host)
                newSurfaces[screen.persistentID] = surface
                try space.attach(surface.window)
                host.setPlaying(false)
                host.failed = { [weak self] message in self?.rendererFailed(message) }
                host.ready = { [weak self] in self?.updateDetails() }
                host.diagnostic = { [weak self] message in self?.lastDiagnostic = message; self?.updateDetails() }
            }
            surfaces = newSurfaces
            activeWallpaper = wallpaper
            activeConfigurationIdentity = configurationIdentity()
            updateVisibility()
        } catch {
            for surface in newSurfaces.values { surface.stop() }
            surfaces.removeAll()
            activeWallpaper = nil
            activeConfigurationIdentity = nil
            let cleanupError = space.remove()
            privateSpace = cleanupError == nil ? nil : space
            throw LumaError(cleanupError.map { "\(error.localizedDescription) SkyLight cleanup also failed: \($0)" } ?? error.localizedDescription)
        }
    }

    private func rendererFailed(_ message: String) {
        guard enabled || activeWallpaper != nil else { return }
        disable()
        status = "The lock-screen scene renderer stopped: \(message) Use Prepare Static Fallback instead."
    }

    private func screenLocked() {
        locked = true
        if enabled { status = "Lock detected; requesting the scene overlay. See renderer status below." }
        updateVisibility()
    }
    private func screenUnlocked() {
        locked = false
        if enabled { status = "Experimental overlay is armed. The scene is paused until macOS locks." }
        updateVisibility()
    }

    private static func sessionLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        // The unlocked dictionary can omit this key entirely.
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func monitorSession() {
        guard sessionTask == nil, enabled, !shuttingDown else { return }
        // Notifications can be missed during login, wake or fast user switching.
        // Read session state as a fallback; this never locks or unlocks the Mac.
        sessionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.enabled, !self.shuttingDown else { return }
                if let current = Self.sessionLocked(), current != self.locked {
                    if current { self.screenLocked() } else { self.screenUnlocked() }
                }
            }
        }
    }

    private func updateDetails() {
        guard !surfaces.isEmpty else { details = ""; return }
        let ready = surfaces.values.filter { $0.host.didBecomeReady }.count
        details = "Session: \(locked ? "locked" : "unlocked"); displays: \(sleeping ? "asleep" : "awake"); scene renderers ready: \(ready)/\(surfaces.count)."
        if ready < surfaces.count { details += " Hidden WebKit content may finish loading only when the lock screen appears." }
        if !lastDiagnostic.isEmpty { details += "\nRenderer: \(lastDiagnostic)" }
    }

    private func updateVisibility() {
        monitorSession()
        let visible = enabled && locked && !sleeping && !shuttingDown
        privateSpace?.setVisible(visible)
        for surface in surfaces.values {
            surface.host.setPlaying(visible)
            if visible {
                surface.window.alphaValue = 1
                surface.window.orderFrontRegardless()
            } else {
                surface.window.alphaValue = 0
                surface.window.orderOut(nil)
            }
        }
        updateDetails()
    }

    private func rebuildForScreenChange() {
        guard enabled, let id = wallpaperID, let wallpaper = library.state.wallpapers.first(where: { $0.id == id }) else { return }
        do { try build(for: wallpaper); updateVisibility() }
        catch { disable(); status = "Overlay stopped after the display layout changed: \(error.localizedDescription)" }
    }

    @discardableResult private func cleanupRuntime() -> String? {
        sessionTask?.cancel(); sessionTask = nil
        for surface in surfaces.values { surface.stop() }
        surfaces.removeAll()
        activeWallpaper = nil
        activeConfigurationIdentity = nil
        details = ""
        let result = privateSpace?.remove()
        if result == nil { privateSpace = nil }
        return result
    }
}

@MainActor private final class LockSceneSurface {
    let window: LockSceneWindow
    let host: SceneHost

    init(screen: NSScreen, host: SceneHost) {
        self.host = host
        window = LockSceneWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.setFrame(screen.frame, display: true)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.canBecomeVisibleWithoutLogin = true
        window.canHide = false
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        // This fills the display: use Atoll's background level, not the widget
        // level that would cover macOS's clock and password controls.
        window.level = .init(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.alphaValue = 0
        window.contentView = host.webView
        host.webView.frame = window.contentView?.bounds ?? screen.frame
        host.webView.autoresizingMask = [.width, .height]
        window.displayIfNeeded()
        window.orderFrontRegardless()
    }

    func stop() {
        host.setPlaying(false)
        host.stop()
        window.orderOut(nil)
        window.close()
    }
}

@MainActor private final class LockSceneWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

import AppKit
import Combine
import Darwin
import Foundation

/// A private-API experiment. macOS does not promise that a third-party window
/// will remain visible or animate on the authenticated lock screen.
@MainActor final class ExperimentalLockScreenOverlay: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var status = "Live lock-screen overlay is off."
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

    init(library: LibraryStore, assets: @escaping () -> URL?) {
        self.library = library
        self.assets = assets
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        wallpaperID = UUID(uuidString: UserDefaults.standard.string(forKey: Self.wallpaperKey) ?? "")

        let distributed = DistributedNotificationCenter.default()
        observe(Notification.Name("com.apple.screenIsLocked"), center: distributed) { [weak self] in self?.screenLocked() }
        observe(Notification.Name("com.apple.screenIsUnlocked"), center: distributed) { [weak self] in self?.screenUnlocked() }
        observe(NSApplication.didChangeScreenParametersNotification, center: .default) { [weak self] in self?.rebuildForScreenChange() }

        let workspace = NSWorkspace.shared.notificationCenter
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
        guard renderIdentity(activeWallpaper) != renderIdentity(wallpaper) else { return }
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

    private func build(for wallpaper: Wallpaper) throws {
        let oldError = cleanupRuntime()
        if let oldError { throw LumaError("The previous overlay could not be removed: \(oldError)") }
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
            }
            surfaces = newSurfaces
            activeWallpaper = wallpaper
            updateVisibility()
        } catch {
            for surface in newSurfaces.values { surface.stop() }
            surfaces.removeAll()
            activeWallpaper = nil
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

    private func screenLocked() { locked = true; updateVisibility() }
    private func screenUnlocked() { locked = false; updateVisibility() }

    private func updateVisibility() {
        let visible = enabled && locked && !sleeping
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
    }

    private func rebuildForScreenChange() {
        guard enabled, let id = wallpaperID, let wallpaper = library.state.wallpapers.first(where: { $0.id == id }) else { return }
        do { try build(for: wallpaper); updateVisibility() }
        catch { disable(); status = "Overlay stopped after the display layout changed: \(error.localizedDescription)" }
    }

    @discardableResult private func cleanupRuntime() -> String? {
        for surface in surfaces.values { surface.stop() }
        surfaces.removeAll()
        activeWallpaper = nil
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
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.canBecomeVisibleWithoutLogin = true
        window.ignoresMouseEvents = true
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        window.level = .init(rawValue: Int(Int32.max - 2))
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

/// Thin, dynamically resolved wrapper around SkyLight. The overlay is disabled
/// unless create/attach/hide/destroy operations are all available on this macOS.
@MainActor private final class SkyLightLockSpace {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceListOperation = @convention(c) (Int32, CFArray) -> Int32
    private typealias AttachWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias SpaceDestroy = @convention(c) (Int32, Int32) -> Int32

    private let handle: UnsafeMutableRawPointer
    private let connection: Int32
    private let id: Int32
    private let hideSpaces: SpaceListOperation
    private let attachWindows: AttachWindows
    private let destroySpace: SpaceDestroy
    private var removed = false

    init() throws {
        let paths = ["/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                     "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"]
        guard let library = paths.lazy.compactMap({ dlopen($0, RTLD_NOW) }).first else {
            throw LumaError("The private SkyLight framework is unavailable on this macOS version.")
        }
        handle = library
        let main: MainConnection = try Self.resolve(handle: library, name: "SLSMainConnectionID", as: MainConnection.self)
        let create: SpaceCreate = try Self.resolve(handle: library, name: "SLSSpaceCreate", as: SpaceCreate.self)
        let setLevel: SpaceSetLevel = try Self.resolve(handle: library, name: "SLSSpaceSetAbsoluteLevel", as: SpaceSetLevel.self)
        let showSpaces: SpaceListOperation = try Self.resolve(handle: library, name: "SLSShowSpaces", as: SpaceListOperation.self)
        attachWindows = try Self.resolve(handle: library, name: "SLSSpaceAddWindowsAndRemoveFromSpaces", as: AttachWindows.self)
        hideSpaces = try Self.resolve(handle: library, name: "SLSHideSpaces", as: SpaceListOperation.self)
        destroySpace = try Self.resolve(handle: library, name: "SLSSpaceDestroy", as: SpaceDestroy.self)
        connection = main()
        guard connection > 0 else { throw LumaError("Luma has no usable WindowServer connection for the experimental overlay.") }
        let space = create(connection, 1, 0)
        guard space > 0 else { throw LumaError("SkyLight could not create a lock-screen space.") }
        id = space
        guard setLevel(connection, id, 400) == 0 else {
            _ = destroySpace(connection, id)
            removed = true
            throw LumaError("SkyLight rejected the lock-screen space level.")
        }
        guard showSpaces(connection, [id] as CFArray) == 0 else {
            _ = hideSpaces(connection, [id] as CFArray)
            _ = destroySpace(connection, id)
            removed = true
            throw LumaError("SkyLight could not show the lock-screen space.")
        }
    }

    func attach(_ window: NSWindow) throws {
        guard !removed, window.windowNumber > 0 else { throw LumaError("The lock-screen window is no longer available.") }
        guard attachWindows(connection, id, [window.windowNumber] as CFArray, 7) == 0 else {
            throw LumaError("SkyLight could not attach a scene window to the lock-screen space.")
        }
    }

    @discardableResult func remove() -> String? {
        guard !removed else { return nil }
        let hide = hideSpaces(connection, [id] as CFArray)
        let destroy = destroySpace(connection, id)
        guard destroy == 0 else { return "SLSpaceDestroy returned \(destroy) (hide returned \(hide))." }
        removed = true
        if hide != 0 { return "SLSHideSpaces returned \(hide); the space was destroyed." }
        return nil
    }

    private static func resolve<T>(handle: UnsafeMutableRawPointer, name: String, as type: T.Type) throws -> T {
        guard let address = dlsym(handle, name) else { throw LumaError("SkyLight is missing required symbol \(name).") }
        return unsafeBitCast(address, to: type)
    }
}

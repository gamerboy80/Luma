import AppKit
import AVFoundation
import Combine
import IOKit.ps
import QuartzCore

extension NSScreen {
    var displayID: CGDirectDisplayID { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
    var persistentID: String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() { return CFUUIDCreateString(nil, uuid) as String }
        return String(displayID)
    }
}

@MainActor final class DesktopSurface {
    let window: NSWindow
    let wallpaper: Wallpaper
    let screenID: String
    let view: NSView
    var player: AVQueuePlayer?
    var looper: AVPlayerLooper?
    var videoLayer: AVPlayerLayer?
    var imageLayer: CALayer?
    var scene: SceneHost?
    var observations: [NSKeyValueObservation] = []
    var ready = false
    var lastTime: Double = 0
    var lastAdvance = Date()
    var started = Date()
    var configuration: DisplayConfiguration
    init(wallpaper: Wallpaper, screen: NSScreen, configuration: DisplayConfiguration) {
        self.wallpaper = wallpaper; screenID = screen.persistentID; self.configuration = configuration
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.setFrame(screen.frame, display: true)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.ignoresMouseEvents = true; window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.isReleasedWhenClosed = false; window.isRestorable = false; window.canHide = false; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.alphaValue = 0
        view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size)); view.wantsLayer = true
        view.layer?.masksToBounds = true; window.contentView = view
    }
    func setPlaying(_ playing: Bool) { if playing { player?.playImmediately(atRate: Float(configuration.speed)) } else { player?.pause() }; scene?.setPlaying(playing) }
    func updateGeometry(screen: NSScreen, preferences: AppPreferences) {
        window.setFrame(screen.frame, display: true)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let bounds = view.bounds
        let frame = CGRect(x: bounds.midX - bounds.width * configuration.scale / 2 + bounds.width * configuration.offsetX,
                           y: bounds.midY - bounds.height * configuration.scale / 2 + bounds.height * configuration.offsetY,
                           width: bounds.width * configuration.scale, height: bounds.height * configuration.scale)
        videoLayer?.frame = frame
        imageLayer?.frame = frame
        imageLayer?.contentsGravity = configuration.fit == .contain ? .resizeAspect : (configuration.fit == .stretch ? .resize : .resizeAspectFill)
        videoLayer?.contentsScale = preferences.retina ? screen.backingScaleFactor : 1
        videoLayer?.videoGravity = configuration.fit == .cover ? .resizeAspectFill : (configuration.fit == .contain ? .resizeAspect : .resize)
        scene?.webView.frame = frame
        player?.volume = Float(configuration.volume); player?.isMuted = configuration.volume == 0
        scene?.configure(configuration, preferences: preferences)
        CATransaction.commit()
    }
    func stop() { observations.removeAll(); scene?.stop(); scene = nil; looper?.disableLooping(); looper = nil; player?.pause(); player?.removeAllItems(); videoLayer?.player = nil; window.orderOut(nil); window.close() }
}

private struct DesktopStillReceipt: Codable {
    var screenID: String
    var originalURL: URL?
    var installedURL: URL
}

@MainActor final class DesktopEngine: ObservableObject {
    @Published var screens: [NSScreen] = NSScreen.screens
    @Published var pauseReasons: [String: [String]] = [:]
    @Published var message = "Choose a wallpaper to bring your desktop to life."
    @Published var diagnostics: [String] = []
    let library: LibraryStore
    private(set) var surfaces: [String: DesktopSurface] = [:]
    private var pending: [String: DesktopSurface] = [:]
    private var retryCounts: [String: Int] = [:]
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var pointerTimer: Timer?
    private var sleeping = false
    private var locked = false
    private var previousCPUTicks: [UInt32]?
    private var cpuLoad = 0.0
    private var lastPlaylist = Date()
    private var lastScheduledID: UUID?
    private var stillReceipts: [String: DesktopStillReceipt] = [:]
    private var stillTasks: [String: Task<Void, Never>] = [:]
    private var clearingData = false
    var assetsURL: URL?
    init(library: LibraryStore) {
        self.library = library
        let receiptURL = library.root.appendingPathComponent("DesktopStills/ownership.json")
        if let data = try? Data(contentsOf: receiptURL), let receipts = try? JSONDecoder().decode([String: DesktopStillReceipt].self, from: data) { stillReceipts = receipts }
        library.onChange = { [weak self] in self?.reconcile() }
        observe(NSApplication.didChangeScreenParametersNotification, center: .default) { [weak self] in self?.screens = NSScreen.screens; self?.reconcile() }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.willSleepNotification, center: workspace) { [weak self] in self?.sleeping = true; self?.updatePolicy() }
        observe(NSWorkspace.screensDidSleepNotification, center: workspace) { [weak self] in self?.sleeping = true; self?.updatePolicy() }
        observe(NSWorkspace.didWakeNotification, center: workspace) { [weak self] in self?.wake() }
        observe(NSWorkspace.screensDidWakeNotification, center: workspace) { [weak self] in self?.wake() }
        observe(NSWorkspace.activeSpaceDidChangeNotification, center: workspace) { [weak self] in self?.reconcile() }
        let distributed = DistributedNotificationCenter.default()
        observe(Notification.Name("com.apple.screenIsLocked"), center: distributed) { [weak self] in self?.locked = true; self?.updatePolicy() }
        observe(Notification.Name("com.apple.screenIsUnlocked"), center: distributed) { [weak self] in self?.locked = false; self?.wake() }
        startTimers()
        if library.state.preferences.restoreAtLaunch { reconcile() }
    }
    private func startTimers() {
        timer?.invalidate(); pointerTimer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in self?.tick() } }
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in self?.updatePointer() } }
    }
    private func observe(_ name: Notification.Name, center: NotificationCenter, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in Task { @MainActor in action() } }
        observers.append((center, token))
    }
    func apply(_ wallpaper: Wallpaper, to screenID: String?) {
        let ids = screenID.map { [$0] } ?? screens.map(\.persistentID)
        for id in ids { var config = library.state.displays[id] ?? DisplayConfiguration(); config.wallpaperID = wallpaper.id; config.enabled = true; library.state.displays[id] = config; retryCounts[id] = 0 }
        lastPlaylist = Date(); library.save()
    }
    func configure(_ screenID: String, update: (inout DisplayConfiguration) -> Void) {
        var config = library.state.displays[screenID] ?? DisplayConfiguration(); update(&config); library.state.displays[screenID] = config; library.save()
    }
    func stopAll() {
        for id in Array(library.state.displays.keys) { library.state.displays[id]?.wallpaperID = nil }
        library.state.preferences.playlistEnabled = false; library.state.preferences.scheduleEnabled = false; library.save()
        message = "Desktop wallpapers stopped."
    }
    func togglePause() { library.state.preferences.paused.toggle(); library.save() }
    func reconcile() {
        guard !clearingData else { return }
        if !library.state.preferences.syncDesktopStill { for screen in screens { restoreStill(screen.persistentID, screen: screen) } }
        let connected = Set(screens.map(\.persistentID))
        for id in Set(surfaces.keys).union(pending.keys) where !connected.contains(id) { surfaces.removeValue(forKey: id)?.stop(); pending.removeValue(forKey: id)?.stop() }
        for screen in screens {
            let id = screen.persistentID
            let config = library.state.displays[id] ?? DisplayConfiguration()
            guard config.enabled, let wallpaperID = config.wallpaperID, let wallpaper = library.state.wallpapers.first(where: { $0.id == wallpaperID }) else {
                pending.removeValue(forKey: id)?.stop(); surfaces.removeValue(forKey: id)?.stop(); restoreStill(id, screen: screen); continue
            }
            // Revoking consent stops existing and pending script hosts immediately.
            if !wallpaper.runsSceneScript {
                if let active = surfaces[id], active.wallpaper.id == wallpaperID, active.wallpaper.runsSceneScript { surfaces.removeValue(forKey: id)?.stop() }
                if let waiting = pending[id], waiting.wallpaper.id == wallpaperID, waiting.wallpaper.runsSceneScript { pending.removeValue(forKey: id)?.stop() }
            }
            if let active = surfaces[id], active.wallpaper.id == wallpaperID, active.wallpaper.propertiesJSON == wallpaper.propertiesJSON, active.wallpaper.runsSceneScript == wallpaper.runsSceneScript {
                active.configuration = config; active.updateGeometry(screen: screen, preferences: library.state.preferences)
                if let waiting = pending[id], waiting.wallpaper.id != wallpaperID { pending.removeValue(forKey: id)?.stop() }
            } else if pending[id]?.wallpaper.id != wallpaperID || pending[id]?.wallpaper.propertiesJSON != wallpaper.propertiesJSON || pending[id]?.wallpaper.runsSceneScript != wallpaper.runsSceneScript { load(wallpaper, on: screen, configuration: config) }
        }
        updatePolicy()
    }
    private func load(_ wallpaper: Wallpaper, on screen: NSScreen, configuration: DisplayConfiguration) {
        let id = screen.persistentID
        pending.removeValue(forKey: id)?.stop()
        let surface = DesktopSurface(wallpaper: wallpaper, screen: screen, configuration: configuration)
        pending[id] = surface
        let ready: @MainActor @Sendable () -> Void = { [weak self, weak surface] in guard let self, let surface else { return }; self.reveal(surface) }
        let failure: @MainActor @Sendable (String) -> Void = { [weak self, weak surface] error in guard let self, let surface, self.pending[id] === surface || self.surfaces[id] === surface else { return }; self.fail(surface, error: error) }
        do {
            let media = try library.mediaURL(wallpaper)
            guard FileManager.default.fileExists(atPath: media.path) else { throw LumaError("The source is missing. Import this wallpaper again.") }
            switch wallpaper.kind {
            case .video:
                let player = AVQueuePlayer(); player.volume = Float(configuration.volume); player.isMuted = configuration.volume == 0
                player.automaticallyWaitsToMinimizeStalling = false
                let item = AVPlayerItem(url: media)
                surface.looper = AVPlayerLooper(player: player, templateItem: item); surface.player = player
                let layer = AVPlayerLayer(player: player); layer.frame = surface.view.bounds; surface.videoLayer = layer; surface.view.layer?.addSublayer(layer)
                surface.observations.append(layer.observe(\.isReadyForDisplay, options: [.new]) { _, change in if change.newValue == true { Task { @MainActor in ready() } } })
                surface.observations.append(item.observe(\.status, options: [.new]) { item, _ in if item.status == .failed { Task { @MainActor in failure(item.error?.localizedDescription ?? "This video cannot be decoded.") } } })
                if let looper = surface.looper { surface.observations.append(looper.observe(\.status, options: [.new]) { looper, _ in if looper.status == .failed { Task { @MainActor in failure(looper.error?.localizedDescription ?? "Looping failed.") } } }) }
                player.play()
            case .image:
                guard let image = NSImage(contentsOf: media) else { throw LumaError("The image could not be decoded.") }
                let layer = CALayer(); layer.frame = surface.view.bounds; layer.contents = image; layer.contentsGravity = configuration.fit == .contain ? .resizeAspect : (configuration.fit == .stretch ? .resize : .resizeAspectFill); surface.view.layer?.addSublayer(layer); surface.imageLayer = layer
                Task { @MainActor in ready() }
            case .scene, .web:
                let scene = SceneHost(folder: library.folder(wallpaper), assets: assetsURL, wallpaper: wallpaper, configuration: configuration, preferences: library.state.preferences)
                surface.scene = scene; scene.ready = ready; scene.failed = failure
                scene.diagnostic = { [weak self] warning in self?.log(warning) }
                surface.view.addSubview(scene.webView)
            }
            surface.updateGeometry(screen: screen, preferences: library.state.preferences)
            surface.window.orderFrontRegardless()
            message = "Loading \(wallpaper.title)…"
        } catch { failure(error.localizedDescription) }
    }
    private func reveal(_ surface: DesktopSurface) {
        let id = surface.screenID
        guard pending[id] === surface, !surface.ready else { return }
        surface.ready = true
        let old = surfaces[id]; pending.removeValue(forKey: id); surfaces[id] = surface
        updatePolicy()
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.5; surface.window.animator().alphaValue = 1 } completionHandler: { Task { @MainActor in old?.stop() } }
        message = "Playing \(surface.wallpaper.title)"
        if library.state.preferences.syncDesktopStill, let screen = screens.first(where: { $0.persistentID == id }) { synchronizeStill(surface, screen: screen) }
    }
    private func fail(_ surface: DesktopSurface, error: String) {
        let id = surface.screenID
        if pending[id] === surface { pending.removeValue(forKey: id); surface.stop() }
        log("\(surface.wallpaper.title): \(error)"); message = error
    }
    func retry(_ id: String) {
        guard let screen = screens.first(where: { $0.persistentID == id }), let config = library.state.displays[id], let item = library.state.wallpapers.first(where: { $0.id == config.wallpaperID }) else { return }
        load(item, on: screen, configuration: config)
    }
    private func wake() {
        sleeping = false
        reconcile()
        for surface in surfaces.values { surface.lastAdvance = Date(); surface.window.orderFrontRegardless() }
        updatePolicy()
    }
    func updatePolicy() {
        let prefs = library.state.preferences
        let battery = onBattery()
        let windows = prefs.pauseWhenFullscreen ? (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []) : []
        var reasons: [String: [String]] = [:]
        for screen in screens {
            let id = screen.persistentID; let config = library.state.displays[id] ?? DisplayConfiguration()
            var holds = Set<String>()
            if sleeping || CGDisplayIsAsleep(screen.displayID) != 0 { holds.insert("Display asleep") }
            if locked { holds.insert("Screen locked") }
            if prefs.pauseOnBattery && battery { holds.insert("On battery") }
            if prefs.pauseOnLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled { holds.insert("Low Power Mode") }
            if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical { holds.insert("Thermal pressure") }
            if prefs.pauseWhenBusy && cpuLoad > prefs.cpuThreshold { holds.insert("CPU busy") }
            if prefs.pauseWhenFullscreen && windows.contains(where: { window in
                guard let owner = window[kCGWindowOwnerPID as String] as? Int, owner != Int(getpid()), (window[kCGWindowLayer as String] as? Int) == 0,
                      let bounds = window[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return false }
                let displayBounds = CGDisplayBounds(screen.displayID)
                return rect.intersection(displayBounds).width >= displayBounds.width - 2 && rect.intersection(displayBounds).height >= displayBounds.height - 2
            }) { holds.insert("Fullscreen app") }
            let policy = PlaybackPolicy(userPaused: prefs.paused || config.paused, holds: holds)
            surfaces[id]?.setPlaying(policy.shouldPlay)
            if prefs.paused || config.paused { holds.insert("Paused by you") }
            reasons[id] = holds.sorted()
        }
        if reasons != pauseReasons { pauseReasons = reasons }
    }
    private func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in guard let data = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { return false }; return data[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue }
    }
    private func sampleCPU() {
        var info = host_cpu_load_info(); var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) } }
        guard result == KERN_SUCCESS else { return }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        if let previous = previousCPUTicks { let delta = zip(ticks, previous).map { Double($0 &- $1) }; let total = delta.reduce(0,+); if total > 0 { cpuLoad = 100 * (total - delta[Int(CPU_STATE_IDLE)]) / total } }
        previousCPUTicks = ticks
    }
    private func tick() {
        guard !clearingData else { return }
        sampleCPU(); updatePolicy(); advancePlaylistIfNeeded()
        for (id, surface) in pending where Date().timeIntervalSince(surface.started) > 50 { fail(surface, error: "No frame arrived within 50 seconds. The previous wallpaper was kept."); retryCounts[id] = 3 }
        for (id, surface) in surfaces {
            guard pauseReasons[id]?.isEmpty != false, let player = surface.player, surface.wallpaper.kind == .video else { surface.lastAdvance = Date(); continue }
            let time = player.currentTime().seconds
            if time.isFinite && abs(time - surface.lastTime) > 0.01 { surface.lastAdvance = Date(); surface.lastTime = time; retryCounts[id] = 0 }
            else if Date().timeIntervalSince(surface.lastAdvance) > 20 && (retryCounts[id] ?? 0) < 3 { retryCounts[id, default: 0] += 1; surface.lastAdvance = Date(); retry(id) }
        }
    }
    private func advancePlaylistIfNeeded() {
        let prefs = library.state.preferences
        if prefs.scheduleEnabled {
            let hour = Calendar.current.component(.hour, from: Date())
            let day = prefs.dayHour < prefs.nightHour ? (hour >= prefs.dayHour && hour < prefs.nightHour) : (hour >= prefs.dayHour || hour < prefs.nightHour)
            let id = day ? prefs.dayWallpaperID : prefs.nightWallpaperID
            if id != lastScheduledID, let item = library.state.wallpapers.first(where: { $0.id == id }) { lastScheduledID = id; apply(item, to: nil) }
        } else { lastScheduledID = nil }
        guard prefs.playlistEnabled, !prefs.scheduleEnabled, !prefs.paused, !locked, !sleeping, Date().timeIntervalSince(lastPlaylist) >= max(15, prefs.playlistSeconds) else { return }
        nextWallpaper()
    }
    func nextWallpaper() {
        let ids = library.state.preferences.playlistIDs
        let items = library.state.wallpapers.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return }
        let current = surfaces.values.first?.wallpaper.id
        let next: Wallpaper
        if library.state.preferences.playlistShuffle { next = items.filter { $0.id != current }.randomElement() ?? items[0] }
        else { let index = items.firstIndex(where: { $0.id == current }) ?? -1; next = items[(index + 1) % items.count] }
        apply(next, to: nil)
    }
    private func updatePointer() {
        guard !clearingData, library.state.preferences.mouseParallax, !sleeping, !locked, !library.state.preferences.paused else { return }
        let mouse = NSEvent.mouseLocation
        for screen in screens where screen.frame.contains(mouse) {
            guard pauseReasons[screen.persistentID]?.isEmpty != false else { continue }
            surfaces[screen.persistentID]?.scene?.pointer(x: (mouse.x - screen.frame.minX) / screen.frame.width, y: 1 - (mouse.y - screen.frame.minY) / screen.frame.height)
        }
    }
    private func synchronizeStill(_ surface: DesktopSurface, screen: NSScreen) {
        let id = screen.persistentID; stillTasks[id]?.cancel()
        let originalURL = stillReceipts[id]?.originalURL ?? NSWorkspace.shared.desktopImageURL(for: screen)
        stillTasks[id] = Task { [weak self, weak surface] in
            guard let self, let surface else { return }
            do {
                let data: Data
                if surface.wallpaper.kind == .video {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: try library.mediaURL(surface.wallpaper))); generator.appliesPreferredTrackTransform = true
                    data = NSBitmapImageRep(cgImage: try await generator.image(at: .zero).image).representation(using: .png, properties: [:])!
                } else if surface.wallpaper.kind == .image { data = try Data(contentsOf: library.mediaURL(surface.wallpaper)) }
                else { guard let scene = surface.scene else { return }; data = try await scene.capture(time: 0, width: 1920, height: 1080) }
                try Task.checkCancellation(); guard surfaces[id] === surface else { return }
                let dir = library.root.appendingPathComponent("DesktopStills"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("\(surface.wallpaper.id).png"); try data.write(to: url, options: .atomic)
                stillReceipts[id] = DesktopStillReceipt(screenID: id, originalURL: originalURL, installedURL: url)
                try persistStillReceipts()
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            } catch is CancellationError {} catch { log("Desktop still: \(error.localizedDescription)") }
        }
    }
    private func restoreStill(_ id: String, screen: NSScreen) {
        stillTasks.removeValue(forKey: id)?.cancel()
        guard let receipt = stillReceipts[id] else { return }
        do {
            if NSWorkspace.shared.desktopImageURL(for: screen) == receipt.installedURL {
                guard let original = receipt.originalURL else { throw LumaError("The previous desktop image could not be identified, so the wallpaper backup was retained.") }
                try NSWorkspace.shared.setDesktopImageURL(original, for: screen, options: [:])
            }
            stillReceipts.removeValue(forKey: id)
            try persistStillReceipts()
        } catch { log("Could not restore the previous desktop image: \(error.localizedDescription)") }
    }
    func clearDataRestorePlan() -> [String] {
        stillReceipts.values.sorted { $0.screenID < $1.screenID }.map { receipt in
            "Restore display \(receipt.screenID) to \(receipt.originalURL?.path ?? "the macOS default desktop image")."
        }
    }
    func beginClearData() {
        guard !clearingData else { return }
        clearingData = true
        timer?.invalidate(); timer = nil
        pointerTimer?.invalidate(); pointerTimer = nil
        for surface in Array(surfaces.values) + Array(pending.values) { surface.stop() }
        surfaces.removeAll(); pending.removeAll()
    }
    func resumeAfterClearDataFailure() {
        guard clearingData else { return }
        clearingData = false
        startTimers()
        reconcile()
    }
    func prepareForClearData() async throws {
        beginClearData()
        let inFlightStillTasks = Array(stillTasks.values)
        inFlightStillTasks.forEach { $0.cancel() }
        stillTasks.removeAll()
        for id in Array(library.state.displays.keys) { library.state.displays[id]?.wallpaperID = nil }
        library.state.preferences.playlistEnabled = false
        library.state.preferences.scheduleEnabled = false
        for surface in Array(surfaces.values) + Array(pending.values) { surface.stop() }
        surfaces.removeAll(); pending.removeAll()
        for task in inFlightStillTasks { await task.value }
        let stillsDirectory = library.root.appendingPathComponent("DesktopStills", isDirectory: true)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: stillsDirectory.path),
           attributes[.type] as? FileAttributeType != .typeDirectory {
            throw LumaError("\(stillsDirectory.path) is not a Luma-managed directory. It was left untouched.")
        }
        for (id, receipt) in Array(stillReceipts) {
            guard let screen = screens.first(where: { $0.persistentID == id }) else {
                throw LumaError("Connect display \(id) so Luma can restore its previous desktop image before clearing data.")
            }
            if NSWorkspace.shared.desktopImageURL(for: screen) == receipt.installedURL {
                guard let original = receipt.originalURL else { throw LumaError("The previous desktop image could not be identified. Luma's backup was retained.") }
                try NSWorkspace.shared.setDesktopImageURL(original, for: screen, options: [:])
            }
            try removeOwnedStillFile(receipt.installedURL, directory: stillsDirectory)
            stillReceipts.removeValue(forKey: id)
        }
        let ownership = stillsDirectory.appendingPathComponent("ownership.json")
        try removeManagedFileIfPresent(ownership)
        if FileManager.default.fileExists(atPath: stillsDirectory.path),
           (try FileManager.default.contentsOfDirectory(atPath: stillsDirectory.path)).isEmpty {
            try FileManager.default.removeItem(at: stillsDirectory)
        }
    }
    private func removeOwnedStillFile(_ url: URL, directory: URL) throws {
        let standardizedDirectory = directory.standardizedFileURL
        guard url.deletingLastPathComponent().standardizedFileURL == standardizedDirectory,
              let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
              url.lastPathComponent == "\(id.uuidString).png" else { return }
        try removeManagedFileIfPresent(url)
    }
    private func removeManagedFileIfPresent(_ url: URL) throws {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { return }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw LumaError("\(url.path) is not a regular Luma-generated file. It was left untouched.")
        }
        try fm.removeItem(at: url)
    }
    private func persistStillReceipts() throws {
        let dir = library.root.appendingPathComponent("DesktopStills", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(stillReceipts).write(to: dir.appendingPathComponent("ownership.json"), options: .atomic)
    }
    func log(_ message: String) { diagnostics.append("\(Date().formatted(date: .omitted, time: .standard))  \(message)"); if diagnostics.count > 100 { diagnostics.removeFirst(diagnostics.count - 100) } }
    func shutdown() {
        timer?.invalidate(); pointerTimer?.invalidate(); for (center, token) in observers { center.removeObserver(token) }; observers.removeAll()
        for surface in Array(surfaces.values) + Array(pending.values) { surface.stop() }; surfaces.removeAll(); pending.removeAll()
        for screen in screens { restoreStill(screen.persistentID, screen: screen) }
    }
}

import AppKit
import AVFoundation
import SwiftUI
import WebKit
import ImageIO

struct DisplaysView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var desktop: DesktopEngine
    @State private var selectedID = ""
    @State private var session: DisplayAdjustmentDraft?
    @State private var pendingSelection: String?
    @State private var message = ""
    @State private var previewMessage = ""
    @State private var previewPlaying = true
    @State private var dragStart: CGSize?
    @State private var failure: String?

    private var screen: NSScreen? { desktop.screens.first { $0.persistentID == selectedID } }
    private var configuration: DisplayConfiguration { session?.configuration ?? DisplayConfiguration() }
    private var wallpaper: Wallpaper? { library.state.wallpapers.first { $0.id == configuration.wallpaperID } }
    private var supportsCenter: Bool { wallpaper?.kind == .image || wallpaper?.kind == .video }
    private var saved: DisplayConfiguration { library.state.displays[selectedID] ?? DisplayConfiguration() }
    private var conflict: Bool { session.map { $0.baseline != saved } ?? false }
    private var previewIdentity: String { [selectedID, wallpaper?.id.uuidString ?? "", wallpaper?.entry ?? "", wallpaper?.propertiesJSON ?? "", wallpaper?.scriptApprovalFingerprint ?? "", String(wallpaper?.runsSceneScript ?? false), desktop.assetsURL?.path ?? ""].joined(separator: "|") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Adjust your display wallpaper").font(.system(size: 27, weight: .semibold, design: .rounded))
                Text("Preview changes here, then apply them to the selected display.").foregroundStyle(.secondary)
                Picker("Display", selection: Binding(get: { selectedID }, set: requestSelection)) {
                    if screen == nil { Text(selectedID.isEmpty ? "Choose a display" : "Disconnected display").tag(selectedID) }
                    ForEach(desktop.screens, id: \.persistentID) { display in
                        Text("\(display.localizedName) · \(resolution(display))").tag(display.persistentID)
                    }
                }
                if let screen {
                    HStack {
                        Image(systemName: "display").font(.largeTitle)
                        VStack(alignment: .leading) {
                            Text(screen.localizedName).font(.headline)
                            Text("\(resolution(screen)) pixels · Display \(selectedID.suffix(8))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(session?.hasChanges == true ? "Unsaved adjustments" : "Saved placement").font(.caption).foregroundStyle(.secondary)
                    }
                    preview(for: screen)
                    HStack {
                        Button(previewPlaying ? "Pause Preview" : "Play Preview") { previewPlaying.toggle() }.disabled(wallpaper?.kind == .image || wallpaper == nil)
                        Text("Preview is muted").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(previewMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Picker("Wallpaper", selection: binding(\.wallpaperID)) {
                        Text("None").tag(nil as UUID?)
                        if let id = configuration.wallpaperID, wallpaper == nil { Text("Removed wallpaper").tag(Optional(id)) }
                        ForEach(library.state.wallpapers) { item in Text(item.title).tag(Optional(item.id)) }
                    }.onChange(of: configuration.wallpaperID) { _, _ in
                        previewMessage = ""
                        if !supportsCenter, configuration.fit == .center { session?.configuration.fit = .cover }
                    }
                    Picker("Placement", selection: binding(\.fit)) {
                        ForEach(FitMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode).disabled(mode == .center && !supportsCenter) }
                    }.pickerStyle(.segmented)
                    adjustmentSlider("Zoom", value: binding(\.scale), range: 0.1...4, format: "%.2f×")
                    adjustmentSlider("Horizontal", value: binding(\.offsetX), range: -1...1, format: "%.2f")
                    adjustmentSlider("Vertical", value: binding(\.offsetY), range: -1...1, format: "%.2f")
                    HStack {
                        Toggle("Enabled", isOn: binding(\.enabled))
                        Toggle("Pause this display", isOn: binding(\.paused))
                        Spacer()
                        Button("Reset Placement") { session?.resetPlacement(); message = "Default placement previewed. Apply to save." }
                    }
                    adjustmentSlider("Volume", value: binding(\.volume), range: 0...1, format: "%.2f")
                    adjustmentSlider("Video speed", value: binding(\.speed), range: 0.25...2, format: "%.2f×")
                    if !supportsCenter {
                        Text("Scene previews use WebWallGL's Fill, Fit, and Stretch modes in a smaller viewport. Screen-size-dependent scripts, cursor parallax, and pixel-sized effects may differ from the desktop. Web wallpapers control their own responsive layout. Center is available for images and videos.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Drag inside the display frame to position the wallpaper. Uncovered areas are black in the preview; your macOS desktop may show through on screen. Center uses one source pixel per display backing pixel.").font(.caption).foregroundStyle(.secondary)
                    if let reasons = desktop.pauseReasons[selectedID], !reasons.isEmpty {
                        Label("Current desktop: " + reasons.joined(separator: " · "), systemImage: "pause.circle").font(.caption).foregroundStyle(.orange)
                    }
                    if conflict { Label("Saved settings changed elsewhere. Discard this draft to load the latest settings.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    HStack {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Discard Changes") { load(selectedID); message = "Loaded the saved adjustments." }.disabled(session?.hasChanges != true && !conflict)
                        Button("Apply to \(screen.localizedName)") { apply() }.buttonStyle(.borderedProminent)
                            .disabled(session?.hasChanges != true || conflict)
                    }
                } else {
                    ContentUnavailableView("Display unavailable", systemImage: "display.trianglebadge.exclamationmark", description: Text("Reconnect this display to keep adjusting it, or choose another display. Unsaved settings will not be applied to a different screen."))
                }
            }.padding(28)
        }
        .onAppear { if selectedID.isEmpty, let first = desktop.screens.first { load(first.persistentID) } }
        .onChange(of: desktop.screens.map(\.persistentID)) { _, _ in dragStart = nil; if selectedID.isEmpty, let first = desktop.screens.first { load(first.persistentID) } }
        .onChange(of: screen?.frame) { _, _ in dragStart = nil }
        .onChange(of: saved) { _, _ in if session?.hasChanges != true && session?.baseline != saved { load(selectedID) } }
        .alert("Discard unsaved adjustments?", isPresented: Binding(get: { pendingSelection != nil }, set: { if !$0 { pendingSelection = nil } })) {
            Button("Keep Editing", role: .cancel) { pendingSelection = nil }
            Button("Discard and Switch", role: .destructive) { if let id = pendingSelection { load(id) }; pendingSelection = nil }
        } message: { Text("Your current draft has not been applied to the desktop.") }
        .alert("Could not apply adjustments", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
    }
    private func preview(for screen: NSScreen) -> some View {
        GeometryReader { geometry in
            let size = WallpaperPlacement.previewSize(display: screen.frame.size, available: geometry.size)
            let identity = previewIdentity
            ZStack {
                Color.black
                if let wallpaper {
                    DisplayWallpaperPreview(folder: library.folder(wallpaper), media: try? library.mediaURL(wallpaper), assets: desktop.assetsURL,
                        wallpaper: wallpaper, configuration: configuration, preferences: library.state.preferences,
                        displayPixels: screen.wallpaperPixelSize, playing: previewPlaying, report: { value in
                            Task { @MainActor in if previewIdentity == identity { previewMessage = value } }
                        })
                        .id(previewIdentity)
                        .allowsHitTesting(false)
                } else { Text("Choose a wallpaper").foregroundStyle(.secondary) }
            }.frame(width: size.width, height: size.height).clipped()
                .overlay(Rectangle().stroke(.white.opacity(0.3), lineWidth: 1))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                    if dragStart == nil { dragStart = CGSize(width: configuration.offsetX, height: configuration.offsetY) }
                    let offsets = WallpaperPlacement.draggedOffsets(start: dragStart ?? .zero, translation: value.translation, previewSize: size)
                    session?.configuration.offsetX = offsets.width; session?.configuration.offsetY = offsets.height; message = ""
                }.onEnded { _ in dragStart = nil })
                .id("\(screen.persistentID)-\(screen.frame.width)-\(screen.frame.height)-\(screen.backingScaleFactor)")
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }.frame(height: 360).padding(12).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
    }
    private func binding<T>(_ path: WritableKeyPath<DisplayConfiguration, T>) -> Binding<T> {
        Binding(get: { configuration[keyPath: path] }, set: { session?.configuration[keyPath: path] = $0; message = "" })
    }
    private func adjustmentSlider(_ name: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        HStack { Text(name).frame(width: 95, alignment: .leading); Slider(value: value, in: range); Text(String(format: format, value.wrappedValue)).monospacedDigit().frame(width: 58) }.font(.caption)
    }
    private func resolution(_ screen: NSScreen) -> String { "\(Int(screen.wallpaperPixelSize.width)) × \(Int(screen.wallpaperPixelSize.height))" }
    private func requestSelection(_ id: String) { guard id != selectedID else { return }; if session?.hasChanges == true { pendingSelection = id } else { load(id) } }
    private func load(_ id: String) { selectedID = id; session = DisplayAdjustmentDraft(displayID: id, configuration: library.state.displays[id] ?? DisplayConfiguration()); message = ""; previewMessage = ""; dragStart = nil }
    private func apply() {
        guard let session else { return }
        do { let result = try desktop.applyAdjustment(session); self.session = DisplayAdjustmentDraft(displayID: session.displayID, configuration: result); message = "Applied and saved for this display." }
        catch { failure = error.localizedDescription }
    }
}

private struct DisplayWallpaperPreview: NSViewRepresentable {
    let folder: URL
    let media: URL?
    let assets: URL?
    let wallpaper: Wallpaper
    let configuration: DisplayConfiguration
    let preferences: AppPreferences
    let displayPixels: CGSize
    let playing: Bool
    let report: (String) -> Void
    func makeNSView(context: Context) -> DisplayWallpaperPreviewView {
        let view = DisplayWallpaperPreviewView()
        view.load(folder: folder, media: media, assets: assets, wallpaper: wallpaper, configuration: configuration, preferences: preferences, report: report)
        return view
    }
    func updateNSView(_ view: DisplayWallpaperPreviewView, context: Context) {
        view.configuration = configuration; view.displayPixels = displayPixels; view.playing = playing
        view.preferences = preferences; view.needsLayout = true
    }
    static func dismantleNSView(_ view: DisplayWallpaperPreviewView, coordinator: ()) { view.stop() }
}

final class DisplayWallpaperPreviewView: NSView {
    var configuration = DisplayConfiguration()
    var displayPixels = CGSize.zero
    var playing = true
    var preferences = AppPreferences()
    private var imageLayer: CALayer?
    private var sourcePixels: CGSize?
    private var player: AVQueuePlayer?
    private var videoLayer: AVPlayerLayer?
    private var looper: AVPlayerLooper?
    private var observation: NSKeyValueObservation?
    private var failureObservation: NSKeyValueObservation?
    private var host: SceneHost?
    private var lastSceneWarning: String?
    private var imageTask: Task<Void, Never>?
    private var stopped = false
    private var windowObservers: [NSObjectProtocol] = []
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.masksToBounds = true; layer?.backgroundColor = NSColor.black.cgColor }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func load(folder: URL, media: URL?, assets: URL?, wallpaper: Wallpaper, configuration: DisplayConfiguration, preferences: AppPreferences, report: @escaping (String) -> Void) {
        self.configuration = configuration; self.preferences = preferences
        report("Loading preview…")
        switch wallpaper.kind {
        case .image:
            guard let media else { report("The wallpaper file is unavailable."); return }
            imageTask = Task { @MainActor [weak self] in
                let decoded = await Task.detached(priority: .utility) { () -> ImagePreviewFrame? in
                    guard let source = CGImageSourceCreateWithURL(media as CFURL, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let w = properties[kCGImagePropertyPixelWidth] as? NSNumber, let h = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                              kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else { return nil }
                    return ImagePreviewFrame(image: image, size: WallpaperPlacement.orientedPixels(CGSize(width: w.doubleValue, height: h.doubleValue), orientation: (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1))
                }.value
                guard !Task.isCancelled, let self, !self.stopped else { return }
                guard let decoded else { report("The image preview could not be decoded."); return }
                let imageLayer = CALayer(); imageLayer.contents = decoded.image; self.layer?.addSublayer(imageLayer)
                self.imageLayer = imageLayer; self.sourcePixels = decoded.size; self.needsLayout = true
                report("Image preview")
            }
        case .video:
            guard let media else { report("The wallpaper file is unavailable."); return }
            let player = AVQueuePlayer(); player.isMuted = true
            let item = AVPlayerItem(url: media)
            looper = AVPlayerLooper(player: player, templateItem: item); self.player = player
            let video = AVPlayerLayer(player: player); videoLayer = video; layer?.addSublayer(video)
            if let w = wallpaper.width, let h = wallpaper.height { sourcePixels = CGSize(width: w, height: h) }
            observation = video.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, change in
                if change.newValue == true { Task { @MainActor [weak self] in guard let self, !self.stopped else { return }; self.needsLayout = true; report("Live video preview") } }
            }
            failureObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                if item.status == .failed { Task { @MainActor [weak self] in guard self?.stopped == false else { return }; report(item.error?.localizedDescription ?? "The video preview could not be decoded.") } }
            }
            player.play()
        case .scene, .web:
            var previewPreferences = preferences; previewPreferences.retina = false; previewPreferences.sceneFPS = 24
            var muted = configuration; muted.volume = 0
            let scene = SceneHost(folder: folder, assets: assets, wallpaper: wallpaper, configuration: muted, preferences: previewPreferences)
            host = scene; addSubview(scene.webView)
            scene.setPlaying(false)
            scene.ready = { [weak self] in report(self?.lastSceneWarning ?? (wallpaper.kind == .scene ? "Live scene preview · 24 fps · existing script approval applies" : "Live web preview")) }
            scene.failed = { [weak self] message in self?.lastSceneWarning = message; report(message) }
            scene.diagnostic = { [weak self] message in self?.lastSceneWarning = message; report(message) }
        }
    }
    override func layout() {
        super.layout()
        let presentation = player?.currentItem?.presentationSize ?? .zero
        if WallpaperPlacement.valid(presentation) { sourcePixels = presentation }
        let frame = WallpaperPlacement.frame(in: bounds, configuration: configuration, sourcePixels: sourcePixels, displayPixels: displayPixels)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer?.frame = frame; videoLayer?.frame = frame; host?.webView.frame = frame
        imageLayer?.contentsGravity = configuration.fit == .contain || configuration.fit == .center ? .resizeAspect : configuration.fit == .stretch ? .resize : .resizeAspectFill
        videoLayer?.videoGravity = configuration.fit == .cover ? .resizeAspectFill : configuration.fit == .contain ? .resizeAspect : .resize
        let visible = !stopped && window?.isVisible == true && window?.occlusionState.contains(.visible) == true
        if let player {
            if playing && visible { let rate = Float(configuration.speed); if player.rate != rate { player.playImmediately(atRate: rate) } }
            else { player.pause() }
        }
        if let host {
            var muted = configuration; muted.volume = 0
            var previewPreferences = preferences; previewPreferences.retina = false; previewPreferences.sceneFPS = 24
            host.configure(muted, preferences: previewPreferences); host.setPlaying(playing && visible)
        }
        CATransaction.commit()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver); windowObservers.removeAll()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.needsLayout = true; self?.layoutSubtreeIfNeeded() }
                })
            }
        }
        needsLayout = true; layoutSubtreeIfNeeded()
    }
    func stop() {
        stopped = true; windowObservers.forEach(NotificationCenter.default.removeObserver); windowObservers.removeAll()
        imageTask?.cancel(); imageTask = nil; observation = nil; failureObservation = nil
        player?.pause(); looper?.disableLooping(); player?.removeAllItems(); videoLayer?.player = nil; player = nil; looper = nil
        host?.stop(); host?.webView.removeFromSuperview(); host = nil
    }
}

private struct ImagePreviewFrame: @unchecked Sendable { let image: CGImage; let size: CGSize }

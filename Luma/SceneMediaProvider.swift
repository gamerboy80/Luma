import AppKit
import Combine
import Foundation

/// User-selected metadata source. Fixed host-owned AppleScript only; scene code
/// can neither choose a target app nor supply automation commands.
@MainActor final class SceneMediaProvider: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case off, music, spotify
        var id: String { rawValue }
        var title: String { switch self { case .off: "Off"; case .music: "Music"; case .spotify: "Spotify" } }
        var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
    }
    static let shared = SceneMediaProvider()
    static let preferenceKey = "luma.sceneMedia.source"
    @Published private(set) var source: Source = .off
    @Published private(set) var status = "Track information is off."
    @Published private(set) var snapshot = TrackSnapshot.empty
    private var timer: Timer?
    private var reading = false
    private var generation = 0
    private let queue = DispatchQueue(label: "dev.patrick.Luma.track-metadata", qos: .utility)

    struct TrackSnapshot: Equatable, Sendable {
        var available = false
        var state = "stopped"
        var title = "", artist = "", album = "", albumArtist = ""
        var position = 0.0, duration = 0.0
        var trackIndex = 0
        static let empty = TrackSnapshot()
        var json: [String: Any] {
            ["hasMedia": available, "playing": state == "playing", "state": state == "playing" ? 1 : state == "paused" ? 2 : 0,
             "title": title, "artist": artist, "album": album, "albumArtist": albumArtist,
             "position": position, "duration": duration, "trackIndex": trackIndex, "hasThumbnail": false, "thumbnail": "", "lyrics": []]
        }
    }

    func startSavedSource() { setSource(Source(rawValue: UserDefaults.standard.string(forKey: Self.preferenceKey) ?? "") ?? .off, save: false) }
    func setSource(_ value: Source, save: Bool = true) {
        generation += 1
        timer?.invalidate(); timer = nil
        source = value; snapshot = .empty
        if save { UserDefaults.standard.set(value.rawValue, forKey: Self.preferenceKey) }
        guard value != .off else { status = "Track information is off."; return }
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            status = "Track metadata requires the standard local Luma build. This sandboxed build cannot automate the player."
            return
        }
        status = "Waiting for \(value.title). macOS may ask you to allow Luma under Privacy & Security → Automation."
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
    }
    func retry() { setSource(source, save: false) }
    func stop(clearPreference: Bool = false) {
        generation += 1
        timer?.invalidate(); timer = nil
        snapshot = .empty
        if clearPreference { source = .off; status = "Track information is off."; UserDefaults.standard.removeObject(forKey: Self.preferenceKey) }
    }
    private func poll() {
        guard source != .off, !reading else { return }
        let selected = source, token = generation
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: selected.bundleID).isEmpty else {
            snapshot = .empty; status = "Open \(selected.title) and play a track to share its title, artist, album, and playback position."; return
        }
        reading = true
        queue.async { [weak self] in
            let result = Self.read(selected)
            Task { @MainActor in
                guard let self else { return }
                self.reading = false
                guard self.generation == token, self.source == selected else { return }
                switch result {
                case .success(let value): self.snapshot = value; self.status = value.available ? "Receiving track metadata from \(selected.title)." : "\(selected.title) has no current track."
                case .failure(let error):
                    self.snapshot = .empty; self.status = error.localizedDescription
                    // Do not repeatedly request denied automation or flood errors.
                    self.timer?.invalidate(); self.timer = nil
                }
            }
        }
    }
    nonisolated static func read(_ source: Source) -> Result<TrackSnapshot, LumaError> {
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: metadataScript(for: source)) else { return .failure(LumaError("Could not compile the fixed track metadata query.")) }
        let result = appleScript.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            if code == -1743 { return .failure(LumaError("macOS denied track metadata access. Allow Luma to read the selected player in System Settings → Privacy & Security → Automation, then click Retry.")) }
            return .failure(LumaError("Could not read track metadata (Apple event \(code)): \(error[NSAppleScript.errorMessage] as? String ?? "The player did not respond.")"))
        }
        guard result.numberOfItems == 8 else { return .failure(LumaError("The player returned an unsupported track metadata response.")) }
        return .success(decode((1...8).map { result.atIndex($0)?.stringValue ?? "" }))
    }
    nonisolated static func metadataScript(for source: Source) -> String {
        // Target and code come from a closed enum, never from wallpaper content.
        let appName = source == .music ? "Music" : "Spotify"
        let duration = source == .spotify ? "((duration of t) / 1000.0)" : "(duration of t)"
        return """
        with timeout of 3 seconds
            tell application "\(appName)"
                set s to player state as text
                if s is "stopped" then return {"stopped", "", "", "", "", 0, 0, 0}
                set t to current track
                return {s, name of t, artist of t, album of t, album artist of t, player position, \(duration), track number of t}
            end tell
        end timeout
        """
    }
    nonisolated static func decode(_ fields: [String]) -> TrackSnapshot {
        guard fields.count == 8 else { return .empty }
        func text(_ index: Int) -> String { String(fields[index].prefix(4096)) }
        func seconds(_ index: Int) -> Double { let n = Double(fields[index]) ?? 0; return n.isFinite ? min(604800, max(0, n)) : 0 }
        return TrackSnapshot(available: !text(1).isEmpty, state: ["playing", "paused", "stopped"].contains(fields[0]) ? fields[0] : "stopped",
                             title: text(1), artist: text(2), album: text(3), albumArtist: text(4), position: seconds(5), duration: seconds(6), trackIndex: max(0, min(100_000, Int(fields[7]) ?? 0)))
    }
}

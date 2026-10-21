import AppKit
import Combine
import Foundation
import Darwin

private final class SceneMetadataOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var oversized = false
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        let remaining = max(0, 65_536 - bytes.count)
        if data.count > remaining { oversized = true }
        bytes.append(data.prefix(remaining))
    }
    func result() -> (Data, Bool) { lock.lock(); defer { lock.unlock() }; return (bytes, oversized) }
}

private final class SceneMetadataQuery: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func start(_ value: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try value.run(); process = value
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }
    func finish() { lock.lock(); process = nil; lock.unlock() }
}

private final class WeakSceneMediaProviderReference: @unchecked Sendable {
    weak var value: SceneMediaProvider?
    init(_ value: SceneMediaProvider) { self.value = value }
}

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
    private var stopped = false
    private var generation = 0
    private var activeQuery: SceneMetadataQuery?
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
        stopped = false
        generation += 1
        activeQuery?.cancel(); activeQuery = nil
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
        let weakOwner = WeakSceneMediaProviderReference(self)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in weakOwner.value?.poll() } }
    }
    func retry() { setSource(source, save: false) }
    func stop(clearPreference: Bool = false) {
        stopped = true
        generation += 1
        activeQuery?.cancel(); activeQuery = nil
        timer?.invalidate(); timer = nil
        snapshot = .empty
        if clearPreference { source = .off; status = "Track information is off."; UserDefaults.standard.removeObject(forKey: Self.preferenceKey) }
    }
    private func poll() {
        guard !stopped, source != .off, !reading else { return }
        let selected = source, token = generation
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: selected.bundleID).isEmpty else {
            snapshot = .empty; status = "Open \(selected.title) and play a track to share its title, artist, album, and playback position."; return
        }
        reading = true
        let query = SceneMetadataQuery()
        activeQuery = query
        let owner = self
        queue.async {
            let result = Self.read(selected, query: query)
            Task { @MainActor in
                owner.reading = false
                if owner.activeQuery === query { owner.activeQuery = nil }
                guard owner.generation == token, owner.source == selected else { return }
                switch result {
                case .success(let value): owner.snapshot = value; owner.status = value.available ? "Receiving track metadata from \(selected.title)." : "\(selected.title) has no current track."
                case .failure(let error):
                    owner.snapshot = .empty; owner.status = error.localizedDescription
                    // Do not repeatedly request denied automation or flood errors.
                    owner.timer?.invalidate(); owner.timer = nil
                }
            }
        }
    }
    private nonisolated static func read(_ source: Source, query: SceneMetadataQuery) -> Result<TrackSnapshot, LumaError> {
        guard source != .off else { return .success(.empty) }
        // NSAppleScript is a main-thread API. Executing it on the polling queue
        // timed out despite a responsive Spotify; running it on main would stall
        // Luma's controls. A bounded host-owned osascript process gives AppleScript
        // its own main run loop without exposing any scripting bridge to scenes.
        let process = Process(), output = Pipe(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        process.standardInput = input; process.standardOutput = output; process.standardError = output
        let buffer = SceneMetadataOutput(), eof = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; eof.signal() }
            else { buffer.append(chunk) }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
            try? input.fileHandleForReading.close(); try? input.fileHandleForWriting.close()
        }
        do { try query.start(process) }
        catch { return .failure(LumaError("Could not launch the fixed metadata query: \(error.localizedDescription)")) }
        defer { query.finish() }
        try? output.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        let deadline = DispatchWorkItem { query.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: deadline)
        defer { deadline.cancel() }
        do { try input.fileHandleForWriting.write(contentsOf: Data(metadataProcessScript(for: source).utf8)); try input.fileHandleForWriting.close() }
        catch { query.cancel(); return .failure(LumaError("Could not send the fixed metadata query.")) }
        process.waitUntilExit()
        guard eof.wait(timeout: .now() + 2) == .success else { return .failure(LumaError("The metadata query did not finish returning its response.")) }
        let (data, oversized) = buffer.result()
        guard !oversized else { return .failure(LumaError("The player metadata response exceeds Luma's 64 KiB limit.")) }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let message = String(decoding: data.prefix(1500), as: UTF8.self)
            if message.contains("-1743") { return .failure(LumaError("macOS denied track metadata access. Allow Luma to read the selected player in System Settings → Privacy & Security → Automation, then click Retry.")) }
            return .failure(LumaError("Could not read \(source.title) metadata: \(message.isEmpty ? "The fixed query timed out or the player did not respond. Click Retry Metadata Connection after opening the player." : message)"))
        }
        return decodeResponse(data)
    }
    nonisolated static func decodeResponse(_ data: Data) -> Result<TrackSnapshot, LumaError> {
        guard data.count <= 65_536, let fields = (try? JSONSerialization.jsonObject(with: data)) as? [Any], fields.count == 8,
              fields.allSatisfy({ $0 is String || $0 is NSNumber }) else { return .failure(LumaError("The player returned an unsupported track metadata response.")) }
        return .success(decode(fields.map { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue ?? "" }))
    }
    nonisolated static func metadataProcessScript(for source: Source) -> String {
        """
        use framework "Foundation"
        set fields to readMetadata()
        set jsonData to current application's NSJSONSerialization's dataWithJSONObject:fields options:0 |error|:(missing value)
        return (current application's NSString's alloc()'s initWithData:jsonData encoding:(current application's NSUTF8StringEncoding)) as text
        on readMetadata()
        \(metadataScript(for: source))
        end readMetadata
        """
    }
    nonisolated static func metadataScript(for source: Source) -> String {
        // Target and code come from a closed enum, never from wallpaper content.
        let appName = source == .music ? "Music" : "Spotify"
        return """
        with timeout of 3 seconds
            tell application "\(appName)"
                -- Raw Apple Event property codes work across dictionary versions
                -- and avoid relying on terminology being installed at compile time.
                set rawState to «property pPlS»
                if rawState is «constant ePlSkPSS» then
                    set s to "stopped"
                else if rawState is «constant ePlSkPSP» or rawState is «constant ePlSkPSF» or rawState is «constant ePlSkPSR» then
                    set s to "playing"
                else
                    set s to "paused"
                end if
                if s is "stopped" then return {"stopped", "", "", "", "", 0, 0, 0}
                set t to «property pTrk»
                return {s, «property pnam» of t, «property pArt» of t, «property pAlb» of t, «property pAlA» of t, «property pPos», «property pDur» of t, «property pTrN» of t}
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

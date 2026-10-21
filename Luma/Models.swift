import Foundation
import Darwin

enum WallpaperKind: String, Codable, CaseIterable { case video, scene, web, image }
enum FitMode: String, Codable, CaseIterable { case cover, contain, stretch }
struct Wallpaper: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var kind: WallpaperKind
    var folder: String
    var entry: String
    var preview: String?
    var tags: [String] = []
    var favorite = false
    var added = Date()
    var workshopID: String?
    var duration: Double?
    var width: Int?
    var height: Int?
    var contentSHA256: String?
    var propertiesJSON = "{}"
    var trustedScripts = false
    var scriptApprovalFingerprint: String?
    var isBuiltIn = false
    var scriptsApproved: Bool { scriptApprovalFingerprint != nil }
    var runsSceneScript: Bool { trustedScripts && (kind != .scene || scriptsApproved) }
    var details: String { [kind.rawValue.capitalized, width.map { "\($0) × \(height ?? 0)" }, duration.map { String(format: "%.0fs", $0) }].compactMap { $0 }.joined(separator: " · ") }
}
struct DisplayConfiguration: Codable, Equatable {
    var wallpaperID: UUID?
    var paused = false
    var enabled = true
    var fit: FitMode = .cover
    var scale = 1.0
    var offsetX = 0.0
    var offsetY = 0.0
    var volume = 0.0
    var speed = 1.0

    mutating func normalizeForRuntime() {
        volume = volume.isFinite ? min(1, max(0, volume)) : 0
        speed = speed.isFinite ? min(4, max(0.1, speed)) : 1
        scale = scale.isFinite ? min(4, max(0.1, scale)) : 1
        offsetX = offsetX.isFinite ? min(100_000, max(-100_000, offsetX)) : 0
        offsetY = offsetY.isFinite ? min(100_000, max(-100_000, offsetY)) : 0
    }
}
struct AppPreferences: Codable {
    var pauseOnBattery = false
    var pauseOnLowPower = true
    var pauseWhenFullscreen = true
    var pauseWhenBusy = false
    var cpuThreshold = 85.0
    var sceneFPS = 30
    var retina = true
    var paused = false
    var restoreAtLaunch = true
    var playlistEnabled = false
    var playlistSeconds = 300.0
    var playlistShuffle = true
    var playlistIDs: [UUID] = []
    var dayWallpaperID: UUID?
    var nightWallpaperID: UUID?
    var dayHour = 7
    var nightHour = 19
    var scheduleEnabled = false
    var syncDesktopStill = false
    var mouseParallax = true

    mutating func normalizeForRuntime() {
        cpuThreshold = cpuThreshold.isFinite ? min(99, max(50, cpuThreshold)) : 85
        playlistSeconds = playlistSeconds.isFinite ? min(86_400, max(60, playlistSeconds)) : 300
        if ![24, 30, 60].contains(sceneFPS) { sceneFPS = 30 }
        dayHour = min(23, max(0, dayHour))
        nightHour = min(23, max(0, nightHour))
    }
}
struct SavedLibrary: Codable {
    var version = 1
    var wallpapers: [Wallpaper] = []
    var displays: [String: DisplayConfiguration] = [:]
    var preferences = AppPreferences()
}
struct LumaError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
enum Safety {
    static func validateDirectoryIfPresent(_ url: URL) throws {
        var metadata = stat()
        let result = url.path.withCString { Darwin.lstat($0, &metadata) }
        if result != 0 {
            if Darwin.errno == ENOENT || Darwin.errno == ENOTDIR { return }
            throw LumaError("Cannot inspect directory \(url.path): \(String(cString: strerror(Darwin.errno))).")
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw LumaError("\(url.path) is not a real managed directory. It was left untouched.")
        }
    }
    static func validateProjectTree(_ root: URL) throws {
        try validateDirectoryIfPresent(root)
        guard FileManager.default.fileExists(atPath: root.path) else { throw LumaError("The project folder no longer exists.") }
        var readError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            errorHandler: { _, error in readError = error; return false }) else { throw LumaError("Cannot read the selected project folder.") }
        var count = 0
        for case let url as URL in enumerator {
            count += 1
            guard count <= 100_000 else { throw LumaError("The project contains too many files.") }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
                throw LumaError("The project contains a symbolic link or special file. Copy only regular files into the project first.")
            }
        }
        if let readError { throw readError }
    }
    static func child(_ relative: String, under root: URL) throws -> URL {
        let normalized = relative.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasPrefix("/"), !normalized.contains("\0"),
              !normalized.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { throw LumaError("The project contains an unsafe path: \(relative)") }
        try validateDirectoryIfPresent(root)
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        var candidate = base
        for component in normalized.split(separator: "/") {
            candidate.appendPathComponent(String(component))
            if let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw LumaError("A project path contains a symbolic link.") }
        }
        let result = candidate.standardizedFileURL
        guard result.path.hasPrefix(base.path + "/") else { throw LumaError("A project file points outside its folder.") }
        return result
    }
    static func workshopID(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: "^[0-9]{1,20}$", options: .regularExpression) != nil { return text }
        guard let url = URLComponents(string: text), ["steamcommunity.com", "www.steamcommunity.com"].contains(url.host?.lowercased() ?? ""),
              let id = url.queryItems?.first(where: { $0.name == "id" })?.value,
              id.range(of: "^[0-9]{1,20}$", options: .regularExpression) != nil else { return nil }
        return id
    }
    static func json(_ object: Any) -> String { guard let d = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]), let s = String(data: d, encoding: .utf8) else { return "null" }; return s }
}
struct PlaybackPolicy {
    var userPaused = false
    var holds: Set<String> = []
    var shouldPlay: Bool { !userPaused && holds.isEmpty }
}

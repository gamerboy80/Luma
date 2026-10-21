import Foundation

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
    static func child(_ relative: String, under root: URL) throws -> URL {
        let normalized = relative.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasPrefix("/"), !normalized.contains("\0"),
              !normalized.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { throw LumaError("The project contains an unsafe path: \(relative)") }
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

import AppKit
import AVFoundation
import Combine
import CryptoKit
import Darwin
import Foundation

struct WallperVideoFile: Identifiable, Hashable {
    let url: URL
    let relativePath: String
    let byteCount: Int64

    var id: String { relativePath }
    var filename: String { url.lastPathComponent }
}

struct WallperVideosDiscovery {
    let folderExists: Bool
    let supportedCandidateCount: Int
    let videos: [WallperVideoFile]
    let issues: [String]
}

enum WallperVideosDiscoveryService {
    static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]

    static func folder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Wallper/Videos", isDirectory: true)
    }

    static func discover(at folder: URL) throws -> WallperVideosDiscovery {
        let root = folder.standardizedFileURL
        guard let rootMode = try fileMode(at: root) else {
            return WallperVideosDiscovery(folderExists: false, supportedCandidateCount: 0, videos: [], issues: [])
        }
        guard rootMode & mode_t(S_IFMT) != mode_t(S_IFLNK) else {
            throw LumaError("The Wallper Videos folder is a symbolic link. Luma left it untouched for safety.")
        }
        guard root.resolvingSymlinksInPath().standardizedFileURL.path == root.path else {
            throw LumaError("The Wallper Videos folder resolves through a symbolic link. Luma will not scan outside the selected folder.")
        }
        guard rootMode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw LumaError("The Wallper Videos path exists but is not a folder.")
        }

        var videos: [WallperVideoFile] = []
        var issues: [String] = []
        var supportedCandidateCount = 0
        try scan(directory: root, root: root, videos: &videos, issues: &issues, supportedCandidateCount: &supportedCandidateCount)
        videos.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return WallperVideosDiscovery(folderExists: true, supportedCandidateCount: supportedCandidateCount, videos: videos, issues: issues)
    }

    static func validate(_ candidate: URL, under folder: URL) throws -> URL {
        let root = folder.standardizedFileURL
        let file = candidate.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(prefix) else { throw LumaError("The selected file is outside the Wallper Videos folder.") }
        guard root.resolvingSymlinksInPath().standardizedFileURL.path == root.path else {
            throw LumaError("The Wallper Videos folder resolves through a symbolic link. Luma will not import from outside it.")
        }
        guard try fileMode(at: root).map({ $0 & mode_t(S_IFMT) != mode_t(S_IFLNK) }) == true else { throw LumaError("The Wallper Videos folder is missing or is a symbolic link.") }

        let relative = String(file.path.dropFirst(prefix.count))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LumaError("The selected Wallper video has an unsafe path.")
        }
        var current = root
        for (index, component) in components.enumerated() {
            current.appendPathComponent(String(component))
            guard let mode = try fileMode(at: current) else {
                throw LumaError("The file is no longer available in Wallper Videos.")
            }
            guard mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else {
                throw LumaError("The selected path contains a symbolic link. Luma will not follow it.")
            }
            if index < components.count - 1 {
                guard mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                    throw LumaError("The selected Wallper video path is not a normal folder path.")
                }
            }
        }
        guard supportedExtensions.contains(file.pathExtension.lowercased()) else {
            throw LumaError("\(file.lastPathComponent) is not a supported video format.")
        }
        let fileMode = try fileMode(at: file)
        guard fileMode.map({ $0 & mode_t(S_IFMT) == mode_t(S_IFREG) }) == true else { throw LumaError("\(file.lastPathComponent) is not a regular video file.") }
        let descriptor = try openRegularFile(file)
        Darwin.close(descriptor)
        return file
    }

    static func sha256(of url: URL) throws -> String {
        let fd = try openRegularFile(url)
        defer { Darwin.close(fd) }
        var hasher = SHA256()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024 * 1024)
        defer { buffer.deallocate() }
        while true {
            let count = Darwin.read(fd, buffer, 1024 * 1024)
            if count < 0 {
                if Darwin.errno == EINTR { continue }
                throw LumaError("Could not read \(url.lastPathComponent): \(String(cString: strerror(Darwin.errno)))")
            }
            if count == 0 { break }
            hasher.update(data: Data(bytes: buffer, count: count))
        }
        return digestString(hasher.finalize())
    }

    /// Copies through a no-follow file descriptor after validating every path
    /// component. The digest is calculated from the bytes actually copied.
    static func copyRegularFile(_ source: URL, under folder: URL, to destination: URL) throws -> String {
        let safeSource = try validate(source, under: folder)
        let inputFD = try openRegularFile(safeSource)
        defer { Darwin.close(inputFD) }
        let outputFD = destination.path.withCString { path in
            Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        }
        guard outputFD >= 0 else {
            throw LumaError("Could not create Luma’s managed copy of \(source.lastPathComponent): \(String(cString: strerror(Darwin.errno)))")
        }
        var succeeded = false
        defer {
            Darwin.close(outputFD)
            if !succeeded { try? FileManager.default.removeItem(at: destination) }
        }
        var hasher = SHA256()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024 * 1024)
        defer { buffer.deallocate() }
        while true {
            let count = Darwin.read(inputFD, buffer, 1024 * 1024)
            if count < 0 {
                if Darwin.errno == EINTR { continue }
                throw LumaError("Could not read \(source.lastPathComponent): \(String(cString: strerror(Darwin.errno)))")
            }
            if count == 0 { break }
            hasher.update(data: Data(bytes: buffer, count: count))
            var offset = 0
            while offset < count {
                let written = Darwin.write(outputFD, buffer.advanced(by: offset), count - offset)
                if written < 0 {
                    if Darwin.errno == EINTR { continue }
                    throw LumaError("Could not finish copying \(source.lastPathComponent): \(String(cString: strerror(Darwin.errno)))")
                }
                guard written > 0 else { throw LumaError("The managed copy of \(source.lastPathComponent) stopped accepting data.") }
                offset += written
            }
        }
        guard Darwin.fsync(outputFD) == 0 else {
            throw LumaError("Could not finish writing \(source.lastPathComponent): \(String(cString: strerror(Darwin.errno)))")
        }
        succeeded = true
        return digestString(hasher.finalize())
    }

    private static func openRegularFile(_ url: URL) throws -> Int32 {
        let fd = url.path.withCString { path in Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else {
            throw LumaError("Could not open \(url.lastPathComponent) safely: \(String(cString: strerror(Darwin.errno)))")
        }
        var metadata = stat()
        guard Darwin.fstat(fd, &metadata) == 0 else {
            let detail = String(cString: strerror(Darwin.errno)); Darwin.close(fd)
            throw LumaError("Could not inspect \(url.lastPathComponent): \(detail)")
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            Darwin.close(fd)
            throw LumaError("\(url.lastPathComponent) is not a regular file.")
        }
        return fd
    }

    private static func digestString(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func scan(directory: URL, root: URL, videos: inout [WallperVideoFile], issues: inout [String], supportedCandidateCount: inout Int) throws {
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles])
        } catch {
            if directory == root { throw LumaError("Cannot read the Wallper Videos folder at \(root.path): \(error.localizedDescription)") }
            issues.append("Cannot read folder \(directory.lastPathComponent): \(error.localizedDescription)")
            return
        }
        for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            do {
                if try isSymbolicLink(child) { continue }
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                if values.isDirectory == true {
                    try scan(directory: child, root: root, videos: &videos, issues: &issues, supportedCandidateCount: &supportedCandidateCount)
                    continue
                }
                guard values.isRegularFile == true, supportedExtensions.contains(child.pathExtension.lowercased()) else { continue }
                supportedCandidateCount += 1
                do {
                    let safeURL = try validate(child, under: root)
                    let relativePath = String(safeURL.path.dropFirst(root.path.hasSuffix("/") ? root.path.count : root.path.count + 1))
                    videos.append(WallperVideoFile(url: safeURL, relativePath: relativePath, byteCount: Int64(values.fileSize ?? 0)))
                } catch {
                    issues.append("\(child.lastPathComponent): \(error.localizedDescription)")
                }
            } catch {
                issues.append("Cannot inspect \(child.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private static func isSymbolicLink(_ url: URL) throws -> Bool {
        try fileMode(at: url).map { $0 & mode_t(S_IFMT) == mode_t(S_IFLNK) } ?? false
    }

    private static func fileMode(at url: URL) throws -> mode_t? {
        var metadata = stat()
        let result = url.path.withCString { path in Darwin.lstat(path, &metadata) }
        if result == 0 { return metadata.st_mode }
        if Darwin.errno == ENOENT || Darwin.errno == ENOTDIR { return nil }
        throw LumaError("Cannot access \(url.lastPathComponent): \(String(cString: strerror(Darwin.errno)))")
    }
}

enum WallperImportDisposition {
    case imported
    case duplicate(String)
}

struct WallperImportResult: Identifiable {
    enum Status { case imported, duplicate, failed }
    let id = UUID()
    let filename: String
    let status: Status
    let detail: String
}

@MainActor final class WallperVideosCatalog: ObservableObject {
    let folderURL: URL
    @Published private(set) var videos: [WallperVideoFile] = []
    @Published private(set) var supportedCandidateCount = 0
    @Published private(set) var folderExists = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isImporting = false
    @Published private(set) var importResults: [WallperImportResult] = []
    @Published var errorMessage: String?
    @Published var pendingAlert: String?

    var isAvailable: Bool { folderExists && supportedCandidateCount > 0 }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        folderURL = WallperVideosDiscoveryService.folder(home: home)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let root = folderURL
            let result = try await Task.detached(priority: .utility) {
                try WallperVideosDiscoveryService.discover(at: root)
            }.value
            folderExists = result.folderExists
            supportedCandidateCount = result.supportedCandidateCount
            videos = result.videos
            errorMessage = result.issues.isEmpty ? nil : result.issues.joined(separator: "\n")
            pendingAlert = result.videos.isEmpty && !result.issues.isEmpty ? result.issues.joined(separator: "\n") : nil
        } catch {
            folderExists = true
            supportedCandidateCount = 0
            videos = []
            errorMessage = error.localizedDescription
            pendingAlert = error.localizedDescription
        }
    }

    func importSelected(_ selection: Set<String>, library: LibraryStore) async {
        guard !selection.isEmpty, !isImporting else { return }
        isImporting = true
        importResults = []
        defer { isImporting = false }
        let selected = videos.filter { selection.contains($0.id) }
        for video in selected {
            do {
                let safeURL = try WallperVideosDiscoveryService.validate(video.url, under: folderURL)
                switch try await library.importWallperVideo(safeURL, from: folderURL) {
                case .imported:
                    importResults.append(WallperImportResult(filename: video.filename, status: .imported, detail: "Copied into Luma’s library."))
                case .duplicate(let existingTitle):
                    importResults.append(WallperImportResult(filename: video.filename, status: .duplicate, detail: "Already in Luma as “\(existingTitle)”."))
                }
            } catch {
                importResults.append(WallperImportResult(filename: video.filename, status: .failed, detail: error.localizedDescription))
            }
        }
    }
}

extension LibraryStore {
    func importWallperVideo(_ source: URL, from folder: URL) async throws -> WallperImportDisposition {
        let safeSource = try WallperVideosDiscoveryService.validate(source, under: folder)
        let digest = try await Task.detached(priority: .utility) {
            try WallperVideosDiscoveryService.sha256(of: safeSource)
        }.value
        if let existing = state.wallpapers.first(where: { $0.kind == .video && $0.contentSHA256 == digest }) {
            return .duplicate(existing.title)
        }

        // Older imports predate content fingerprints. Compare same-name, same-size
        // candidates once so importing the same Wallper file does not create a copy.
        let sourceName = safeSource.deletingPathExtension().lastPathComponent
        let sourceSize = (try? FileManager.default.attributesOfItem(atPath: safeSource.path)[.size] as? NSNumber)?.int64Value
        for existing in state.wallpapers where existing.kind == .video && existing.contentSHA256 == nil && existing.title.localizedCaseInsensitiveCompare(sourceName) == .orderedSame {
            guard let existingURL = try? mediaURL(existing),
                  let existingSize = (try? FileManager.default.attributesOfItem(atPath: existingURL.path)[.size] as? NSNumber)?.int64Value,
                  sourceSize == existingSize else { continue }
            let existingDigest = try await Task.detached(priority: .utility) {
                try WallperVideosDiscoveryService.sha256(of: existingURL)
            }.value
            if existingDigest == digest { return .duplicate(existing.title) }
        }

        try await importURL(safeSource, sourceDigest: digest, titleOverride: sourceName, safeSingleFileRoot: folder)
        return .imported
    }
}

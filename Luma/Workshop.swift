import AppKit
import Combine
import Security

struct WorkshopItem: Identifiable, Decodable {
    var publishedfileid: String
    var title: String?
    var preview_url: String?
    var description: String?
    var consumer_app_id: Int?
    var result: Int?
    var tags: [WorkshopTag]?
    var id: String { publishedfileid }
    var kind: String { tags?.first(where: { ["Scene","Video","Web","Application"].contains($0.tag) })?.tag ?? "Wallpaper" }
}
struct WorkshopTag: Decodable { var tag: String }

@MainActor final class WorkshopService: ObservableObject {
    @Published var items: [WorkshopItem] = []
    @Published var searching = false
    @Published var error: String?
    @Published var apiKey: String = ""
    @Published var query = ""
    @Published var type = "All"
    @Published var page = 1
    @Published var total = 0
    private var task: Task<Void, Never>?
    func search(nextPage: Bool = false) {
        task?.cancel()
        page = nextPage ? page + 1 : 1
        let requestedPage = page
        task = Task {
            searching = true; error = nil; defer { searching = false }
            do {
                let result: [WorkshopItem]
                if let id = Safety.workshopID(query) { result = try await details(id: id); total = result.count }
                else {
                    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LumaError("Enter a Steam Web API key for text search, or paste a Workshop link / item ID. You can also browse Workshop in Steam.") }
                    var url = URLComponents(string: "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/")!
                    var fields = ["key":apiKey,"query_type":"0","page":String(requestedPage),"numperpage":"30","appid":"431960","search_text":query,"return_details":"true","return_tags":"true"]
                    if type != "All" { fields["requiredtags[0]"] = type; fields["match_all_tags"] = "true" }
                    url.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
                    struct Envelope: Decodable { var response: Response; struct Response: Decodable { var total: Int?; var publishedfiledetails: [WorkshopItem]? } }
                    let (data, response) = try await URLSession.shared.data(from: url.url!)
                    try Self.validate(response)
                    let decoded = try JSONDecoder().decode(Envelope.self, from: data)
                    total = decoded.response.total ?? 0; result = decoded.response.publishedfiledetails ?? []
                }
                try Task.checkCancellation()
                if nextPage { items += result } else { items = result }
            } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func details(id: String) async throws -> [WorkshopItem] {
        guard Safety.workshopID(id) == id else { throw LumaError("Invalid Workshop ID.") }
        var request = URLRequest(url: URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("itemcount=1&publishedfileids%5B0%5D=\(id)".utf8)
        let (data, response) = try await URLSession.shared.data(for: request); try Self.validate(response)
        struct Envelope: Decodable { var response: Response; struct Response: Decodable { var publishedfiledetails: [WorkshopItem] } }
        let result = try JSONDecoder().decode(Envelope.self, from: data).response.publishedfiledetails
        guard let item = result.first, item.result == 1, item.consumer_app_id == 431960 else { throw LumaError("This item is unavailable or does not belong to Wallpaper Engine.") }
        return result
    }
    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw LumaError("Steam returned an invalid response.") }
        guard (200...299).contains(http.statusCode) else { throw LumaError("Steam returned HTTP \(http.statusCode). Check your API key or try again later.") }
    }
    func browseInSteam() {
        var url = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
        url.queryItems = [URLQueryItem(name:"appid",value:"431960"), URLQueryItem(name:"searchtext",value:query)]
        if let result = url.url { NSWorkspace.shared.open(result) }
    }
    func resetForClearData() {
        task?.cancel(); task = nil; searching = false; error = nil; apiKey = ""; query = ""; type = "All"; page = 1; total = 0; items = []
    }
}

private final class SteamOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        value += String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\u{001B}", with: "")
        if value.count > 60000 { value = String(value.suffix(45000)) }
    }
    func snapshot() -> String { lock.lock(); defer { lock.unlock() }; return value }
}

// Credentials are typed into the live SteamCMD stdin stream, never command-line
// arguments, settings, or log files. The user selects a writable SteamCMD folder.
@MainActor final class SteamCMD: ObservableObject {
    @Published var running = false
    @Published var console = "Select your SteamCMD folder to get started. Steam enforces Wallpaper Engine ownership."
    @Published var status = "Not connected"
    @Published var username = ""
    @Published var currentItemID: String?
    @Published var folderURL: URL?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var scopedFolder: URL?
    private var checkingInstallation = false
    private var cancellationRequested = false
    var downloaded: ((URL, String) async throws -> Void)?
    init() {
        if let data = Bookmark.savedData(forKey: "steamcmd-folder"), let resolved = try? Bookmark.resolve(data) { folderURL = resolved }
    }
    func chooseFolder() {
        guard !running else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "Choose the writable folder containing steamcmd.sh (or steamcmd). Install SteamCMD from Valve first."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let executable = Self.executable(in: url) else { status = "Cannot read SteamCMD in this folder. Choose the folder containing steamcmd.sh or steamcmd and grant access in the file picker."; return }
        do {
            let bookmark = try Bookmark.create(url)
            UserDefaults.standard.set(bookmark, forKey: "steamcmd-folder")
            folderURL = url; status = "Connected to \(executable.lastPathComponent). Enter your Steam account name to download."
        } catch { status = error.localizedDescription }
    }
    static func executable(in folder: URL) -> URL? {
        // POSIX permission bits describe the installation. access(X_OK) also asks
        // the sandbox, so it can incorrectly make an installed binary look absent.
        let binaries = ["steamcmd", "osx32/steamcmd", "Steam.AppBundle/Steam/Contents/MacOS/steamcmd", "steamcmd/steamcmd", "Steam/steamcmd"]
        let scripts = ["steamcmd.sh", "steamcmd/steamcmd.sh", "Steam/steamcmd.sh"]
        return (binaries + scripts).map { folder.appendingPathComponent($0) }.first { url in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType == .typeRegular else { return false }
            if url.pathExtension == "sh" { return FileManager.default.isReadableFile(atPath: url.path) }
            return ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0
        }
    }
    static func environment(for executable: URL, inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = inherited
        let path = executable.deletingLastPathComponent().path
        for key in ["DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH"] {
            environment[key] = path + (inherited[key].flatMap { $0.isEmpty ? nil : ":" + $0 } ?? "")
        }
        return environment
    }
    private static func isInsideExistingSteamLibrary(_ file: URL) -> Bool {
        let fm = FileManager.default
        let steamRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
        var roots = [steamRoot.standardizedFileURL.resolvingSymlinksInPath()]
        let vdf = steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8),
           let regex = try? NSRegularExpression(pattern: #""((?:\\.|[^"\\])*)"\s*"((?:\\.|[^"\\])*)""#) {
            let nsText = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) where match.numberOfRanges == 3 {
                let key = nsText.substring(with: match.range(at: 1))
                guard key == "path" || Int(key) != nil else { continue }
                let path = nsText.substring(with: match.range(at: 2)).replacingOccurrences(of: "\\\\", with: "\\")
                guard path.hasPrefix("/") else { continue }
                roots.append(URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath())
            }
        }
        let target = file.standardizedFileURL.resolvingSymlinksInPath().path
        return roots.contains { root in target == root.path || target.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") }
    }
    func checkInstallation() {
        guard !running, let folder = folderURL else { status = "Choose a SteamCMD folder first."; return }
        if folder.startAccessingSecurityScopedResource() { scopedFolder = folder }
        guard let executable = Self.executable(in: folder) else { status = "SteamCMD is missing or folder access has expired. Choose the folder again."; release(); return }
        checkingInstallation = true; currentItemID = nil
        launch(executable, commands: ["+quit"], folder: folder, itemID: nil)
    }
    func download(_ item: WorkshopItem) {
        guard !running, Safety.workshopID(item.id) == item.id, let folder = folderURL else { status = "Choose a SteamCMD folder first."; return }
        guard username.range(of: "^[A-Za-z0-9_@.\\-]{1,100}$", options: .regularExpression) != nil else { status = "Enter your Steam account name before downloading."; return }
        if folder.startAccessingSecurityScopedResource() { scopedFolder = folder }
        guard let executable = Self.executable(in: folder) else { status = "SteamCMD is missing or folder access has expired. Choose the SteamCMD folder again."; release(); return }
        checkingInstallation = false; currentItemID = item.id
        let commands = ["+@ShutdownOnFailedCommand","1","+@NoPromptForPassword","0","+login",username,"+workshop_download_item","431960",item.id,"validate","+quit"]
        launch(executable, commands: commands, folder: folder, itemID: item.id)
    }
    private func launch(_ executable: URL, commands: [String], folder: URL, itemID: String?, restartCount: Int = 0) {
        if restartCount == 0 { console = ""; cancellationRequested = false }
        let p = Process(); let stdin = Pipe(); let stdout = Pipe()
        p.executableURL = executable.pathExtension == "sh" ? URL(fileURLWithPath: "/bin/bash") : executable
        p.arguments = (executable.pathExtension == "sh" ? [executable.path] : []) + commands
        p.environment = Self.environment(for: executable)
        p.currentDirectoryURL = executable.deletingLastPathComponent(); p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stdout
        append("Starting \(executable.path)…\n")
        let prefix = console
        let captured = SteamOutputBuffer()
        status = checkingInstallation ? "Checking SteamCMD without logging in…" : "Signing in / downloading"
        stdout.fileHandleForReading.readabilityHandler = { [weak self, weak p] handle in
            let data = handle.availableData; guard !data.isEmpty else { return }
            captured.append(data)
            Task { @MainActor [weak self, weak p] in
                guard let self, let p, self.process === p else { return }
                self.console = String((prefix + captured.snapshot()).suffix(60000))
            }
        }
        p.terminationHandler = { [weak self] completed in
            stdout.fileHandleForReading.readabilityHandler = nil
            captured.append(stdout.fileHandleForReading.readDataToEndOfFile())
            Task { @MainActor [weak self] in
                guard let self, self.process === completed else { return }
                self.console = String((prefix + captured.snapshot()).suffix(60000))
                self.closeProcess()
                if self.cancellationRequested { self.status = "Cancelled."; self.release(); return }
                if completed.terminationReason == .exit, completed.terminationStatus == 42, restartCount < 3 {
                    self.append("\nSteamCMD updated itself. Restarting…\n")
                    self.launch(executable, commands: commands, folder: folder, itemID: itemID, restartCount: restartCount + 1)
                    return
                }
                await self.finished(exitCode: completed.terminationStatus, folder: folder, itemID: itemID)
            }
        }
        process = p; input = stdin; output = stdout
        do {
            try p.run(); running = true
            try? stdout.fileHandleForWriting.close()
            try? stdin.fileHandleForReading.close()
        }
        catch {
            append("Launch failed: \(error.localizedDescription)\n")
            status = "macOS could not execute SteamCMD: \(error.localizedDescription). Use Export Terminal Download to run it in Terminal."
            release()
        }
    }
    func sendSecret(_ text: String) {
        guard running, !text.contains("\n"), !text.contains("\r"), !text.isEmpty else { return }
        do { try input?.fileHandleForWriting.write(contentsOf: Data((text + "\n").utf8)) }
        catch { status = "SteamCMD is no longer accepting input." }
    }
    func cancel() { guard running else { return }; cancellationRequested = true; process?.terminate(); status = "Cancelling…" }
    func resetConfiguration() {
        folderURL = nil; username = ""; currentItemID = nil
        status = "Not connected"; console = "Select your SteamCMD folder to get started. Steam enforces Wallpaper Engine ownership."
        UserDefaults.standard.removeObject(forKey: "steamcmd-folder")
    }
    private func append(_ text: String) {
        // SteamCMD normally does not echo passwords. Keep its log in memory only.
        console += text.replacingOccurrences(of: "\u{001B}", with: "")
        if console.count > 60000 { console = String(console.suffix(45000)) }
    }
    private func finished(exitCode: Int32, folder: URL, itemID: String?) async {
        guard let itemID else {
            status = exitCode == 0 ? "SteamCMD installation check passed. No login was attempted." : "SteamCMD exited with code \(exitCode). Check its output for a sandbox, runtime, or library error."
            release(); return
        }
        let success = console.range(of: "Success. Downloaded item \(itemID)", options: .caseInsensitive) != nil
        let installation = Self.executable(in: folder)?.deletingLastPathComponent() ?? folder
        let candidates = [installation.appendingPathComponent("steamapps/workshop/content/431960/\(itemID)"), installation.appendingPathComponent("osx32/steamapps/workshop/content/431960/\(itemID)")]
        let result = candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("project.json").path) }
        guard exitCode == 0 && success else {
            status = "SteamCMD stopped (\(exitCode)). Check its output for login, ownership, Steam Guard, or download errors. No files were removed."
            release(); return
        }
        guard let result else {
            status = "SteamCMD reported a successful download, but project.json was not found in its expected Workshop folder. Check the console; SteamCMD files were kept."
            release(); return
        }
        guard let downloaded else {
            status = "Downloaded item \(itemID), but Luma's importer is unavailable. The files were kept at \(result.path)."
            release(); return
        }
        status = "Downloaded. Importing into Luma…"
        do {
            try await downloaded(result, itemID)
            // Remove only this exact item directory under the selected SteamCMD
            // installation. The SteamCMD executable, its parent directories, and
            // any other Workshop items are never touched.
            let permitted = candidates.first { $0.standardizedFileURL.resolvingSymlinksInPath() == result.standardizedFileURL.resolvingSymlinksInPath() }
            guard let permitted, permitted.standardizedFileURL == result.standardizedFileURL else {
                status = "Imported successfully, but the temporary SteamCMD download path changed. Files were retained at \(result.path)."
                release(); return
            }
            guard !Self.isInsideExistingSteamLibrary(permitted) else {
                status = "Imported successfully. The downloaded copy remains at \(permitted.path) because it is inside an existing Steam library."
                release(); return
            }
            do {
                try FileManager.default.removeItem(at: permitted)
                status = "Downloaded, imported, and cleaned up the temporary Workshop folder."
            } catch {
                status = "Imported successfully, but the temporary download folder could not be removed: \(error.localizedDescription). It remains at \(permitted.path)."
            }
        } catch {
            status = "Downloaded, but Luma could not import the wallpaper: \(error.localizedDescription). The files were kept at \(result.path); download it again to retry."
        }
        release()
    }
    private func closeProcess() {
        output?.fileHandleForReading.readabilityHandler = nil
        try? output?.fileHandleForReading.close()
        try? input?.fileHandleForWriting.close()
        input = nil; output = nil; process = nil
    }
    private func release() {
        closeProcess(); running = false; currentItemID = nil
        scopedFolder?.stopAccessingSecurityScopedResource(); scopedFolder = nil; checkingInstallation = false
    }
    // A fallback for sandbox/runtime restrictions. The user opens this script in
    // Terminal; no credentials are included. Arguments are rigorously shell quoted.
    func exportTerminalDownload(itemID: String) {
        guard Safety.workshopID(itemID) == itemID, let folder = folderURL else { status = "Choose SteamCMD and enter a valid Workshop ID."; return }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        guard let executable = Self.executable(in: folder) else { status = "Choose the SteamCMD folder again to renew file access."; return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Download Wallpaper.command"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "#!/bin/bash\ncd \(quote(executable.deletingLastPathComponent().path)) || exit 1\nexport DYLD_LIBRARY_PATH=\(quote(executable.deletingLastPathComponent().path))\nexport DYLD_FRAMEWORK_PATH=\(quote(executable.deletingLastPathComponent().path))\nread -r -p 'Steam account name: ' account\nfor attempt in 1 2 3 4; do\n  \(executable.pathExtension == "sh" ? "/bin/bash " : "")\(quote(executable.path)) +login \"$account\" +workshop_download_item 431960 \(itemID) validate +quit\n  result=$?\n  [[ $result == 42 ]] || break\ndone\nprintf '\\nImport steamapps/workshop/content/431960/\(itemID) into Luma after a successful download.\\n'\nread -r -p 'Press Return to close.'\n"
        do { try script.write(to: destination, atomically: true, encoding: .utf8); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path); NSWorkspace.shared.activateFileViewerSelecting([destination]); status = "Open the exported command in Terminal, then import the downloaded project folder." }
        catch { status = error.localizedDescription }
    }
}

enum Bookmark {
    static let legacyPreferencesURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/dev.patrick.Luma/Data/Library/Preferences/dev.patrick.Luma.plist")
    static func savedData(forKey key: String) -> Data? {
        if let data = UserDefaults.standard.data(forKey: key) { return data }
        guard ["steamcmd-folder", "engine-assets", "native-root"].contains(key) else { return nil }
        let previous = legacyPreferencesURL
        guard let bytes = try? Data(contentsOf: previous), let values = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any], let data = values[key] as? Data else { return nil }
        UserDefaults.standard.set(data, forKey: key)
        return data
    }
    static func clearSavedBookmarks() throws {
        let keys = ["steamcmd-folder", "engine-assets", "native-root"]
        if FileManager.default.fileExists(atPath: legacyPreferencesURL.path) {
            let data = try Data(contentsOf: legacyPreferencesURL)
            guard var values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw LumaError("The old Luma preferences file could not be read, so its saved bookmarks were left untouched.") }
            keys.forEach { values.removeValue(forKey: $0) }
            let updated = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            try updated.write(to: legacyPreferencesURL, options: .atomic)
        }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }
    static func create(_ url: URL) throws -> Data { try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) }
    static func resolve(_ data: Data) throws -> URL { var stale = false; return try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) }
    @MainActor static func chooseFolder(message: String, defaultsKey: String) throws -> URL? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(try create(url), forKey: defaultsKey); return url
    }
}

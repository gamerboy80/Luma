import Foundation
import CryptoKit

struct SceneScriptSource: Identifiable, Sendable {
    let id: String
    let file: String
    let location: String
    let code: String
}

struct SceneScriptReview: Sendable {
    var sources: [SceneScriptSource] = []
    var issues: [String] = []
    var fingerprint = ""
    var canApprove: Bool { !sources.isEmpty && issues.isEmpty }

    // This reads source as data. It never creates a renderer or evaluates code.
    static func inspect(folder: URL) throws -> SceneScriptReview {
        try Safety.validateDirectoryIfPresent(folder)
        let folder = folder.resolvingSymlinksInPath().standardizedFileURL
        var review = SceneScriptReview()
        var hash = SHA256()
        var textBytes = 0
        var files = 0
        var sourceIDs: Set<String> = []
        let textLimit = 32 * 1024 * 1024
        let scriptExtensions: Set<String> = ["js", "mjs", "cjs", "scenescript"]

        func add(code: String, file: String, location: String) throws {
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard review.sources.count < 1000 else { throw LumaError("This scene has more than 1,000 script sources. Review could not be completed.") }
            let id = "\(file)#\(location)"
            guard sourceIDs.insert(id).inserted else { throw LumaError("Duplicate script location in \(file). Review could not be completed.") }
            review.sources.append(SceneScriptSource(id: id, file: file, location: location, code: code))
        }
        func visit(_ value: Any, file: String, path: String, depth: Int = 0) throws {
            guard depth < 128 else { throw LumaError("A scene document is too deeply nested to review completely.") }
            if let object = value as? [String: Any] {
                for key in object.keys.sorted() {
                    let pointer = path + "/" + key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                    if key.lowercased() == "script", let code = object[key] as? String {
                        try add(code: code, file: file, location: pointer)
                    } else if let child = object[key] { try visit(child, file: file, path: pointer, depth: depth + 1) }
                }
            } else if let array = value as? [Any] {
                for (index, child) in array.enumerated() { try visit(child, file: file, path: path + "/\(index)", depth: depth + 1) }
            }
        }
        func consume(_ bytes: Data, name: String) throws {
            let ext = (name as NSString).pathExtension.lowercased()
            guard ext == "json" || scriptExtensions.contains(ext) else { return }
            textBytes += bytes.count
            guard bytes.count <= 8 * 1024 * 1024, textBytes <= textLimit else { throw LumaError("Scene source exceeds the review limit (8 MB per file, 32 MB total). Approval is unavailable because review is incomplete.") }
            guard let text = String(data: bytes, encoding: .utf8) else { throw LumaError("\(name) is not readable UTF-8 source.") }
            // Delimit names and lengths so distinct source layouts cannot collide.
            hash.update(data: Data("\(name.utf8.count):\(name):\(bytes.count):".utf8)); hash.update(data: bytes)
            if scriptExtensions.contains(ext) { try add(code: text, file: name, location: "Script file") }
            else {
                do {
                    let json = try JSONSerialization.jsonObject(with: Data(normalizedJSON(text).utf8), options: [.fragmentsAllowed])
                    try visit(json, file: name, path: "")
                } catch { throw LumaError("Cannot fully inspect \(name): \(error.localizedDescription)") }
            }
        }
        let manager = FileManager.default
        var names: [String] = []
        var directories: [(URL, String)] = [(folder, "")]
        while let (directory, prefix) = directories.popLast() {
            try Task.checkCancellation()
            do {
                for file in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                    files += 1
                    guard files <= 25_000 else { throw LumaError("This project has too many files to review completely.") }
                    // Build relative names from components. Foundation may return
                    // /private/var URLs when the caller supplied /var (or /tmp).
                    let relative = prefix + file.lastPathComponent
                    names.append(relative)
                    let info = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if info.isDirectory == true, info.isSymbolicLink != true { directories.append((file, relative + "/")) }
                }
            } catch {
                review.issues.append("Cannot inspect \(prefix): \(error.localizedDescription)")
                if files > 25_000 || review.issues.count >= 20 { break }
            }
        }
        for relative in names.sorted() {
            try Task.checkCancellation()
            do {
                let file = try Safety.child(relative, under: folder)
                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard info.isRegularFile == true else { continue }
                let ext = file.pathExtension.lowercased()
                if ext == "pkg" {
                    guard (info.fileSize ?? Int.max) <= 2 * 1024 * 1024 * 1024 else { throw LumaError("\(relative) is too large to inspect.") }
                    let archive = try Data(contentsOf: file, options: .mappedIfSafe)
                    for item in try SceneMediaDiscovery.archiveEntries(archive).sorted(by: { $0.name < $1.name }) where item.ext == "json" || scriptExtensions.contains(item.ext) {
                        guard (item.range?.count ?? Int.max) <= 8 * 1024 * 1024 else { throw LumaError("\(relative) → \(item.name) is too large to review.") }
                        try consume(item.bytes(), name: relative + " → " + item.name)
                    }
                } else if ext == "json" || scriptExtensions.contains(ext) {
                    guard (info.fileSize ?? Int.max) <= 8 * 1024 * 1024 else { throw LumaError("\(relative) is too large to review.") }
                    try consume(Data(contentsOf: file), name: relative)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { review.issues.append("\(relative): \(error.localizedDescription)") }
            if review.issues.count >= 20 { review.issues.append("Further inspection stopped after 20 errors."); break }
        }
        review.fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return review
    }

    // Match the renderer's JSON support for comments and trailing commas while
    // preserving quoted script strings and their escape sequences exactly.
    private static func normalizedJSON(_ text: String) -> String {
        let input = Array(text)
        var output: [Character] = []
        var index = 0
        var quoted = false
        var escaped = false
        while index < input.count {
            let character = input[index]
            if quoted {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" { quoted = true; output.append(character) }
            else if character == "/", index + 1 < input.count, input[index + 1] == "/" {
                index += 2
                while index < input.count, input[index] != "\n", input[index] != "\r" { index += 1 }
                output.append("\n"); continue
            } else if character == "/", index + 1 < input.count, input[index + 1] == "*" {
                index += 2
                while index + 1 < input.count, !(input[index] == "*" && input[index + 1] == "/") { index += 1 }
                guard index + 1 < input.count else { return text }
                index += 2; output.append(" "); continue
            } else { output.append(character) }
            index += 1
        }
        var result = ""
        quoted = false; escaped = false
        for (offset, character) in output.enumerated() {
            if !quoted, character == "," {
                var next = offset + 1
                while next < output.count, output[next].isWhitespace { next += 1 }
                if next < output.count, output[next] == "]" || output[next] == "}" { continue }
            }
            result.append(character)
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" { quoted = true }
        }
        return result
    }
}

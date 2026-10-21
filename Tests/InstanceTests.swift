import Foundation
import Darwin

@main struct InstanceTests {
    static func main() throws {
        let arguments = CommandLine.arguments
        if arguments.count == 4, arguments[1] == "--claim" {
            let gate = URL(fileURLWithPath: arguments[3])
            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: gate.path) {
                guard Date() < deadline else { exit(3) }
                usleep(10_000)
            }
            let claim = try InstanceLock().claim(at: URL(fileURLWithPath: arguments[2]))
            switch claim {
            case .primary: usleep(750_000); exit(0)
            case .alreadyRunning: exit(2)
            }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LumaInstanceTests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let marker = root.appendingPathComponent("instance.lock"), gate = root.appendingPathComponent("go")
        func launch() throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: arguments[0]).standardizedFileURL
            process.arguments = ["--claim", marker.path, gate.path]
            try process.run(); return process
        }
        let processes = try (0..<6).map { _ in try launch() }
        try Data().write(to: gate)
        for process in processes { process.waitUntilExit() }
        guard processes.filter({ $0.terminationStatus == 0 }).count == 1,
              processes.filter({ $0.terminationStatus == 2 }).count == 5 else {
            throw LumaError("Expected one primary process and five rejected concurrent instances.")
        }
        let restart = try launch(); restart.waitUntilExit()
        guard restart.terminationStatus == 0 else { throw LumaError("The lock was not released after process exit.") }
        let symlink = root.appendingPathComponent("link.lock")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: marker)
        do {
            _ = try InstanceLock().claim(at: symlink)
        } catch {
            print("PASS: concurrent singleton election, release on exit, and symlink rejection")
            return
        }
        throw LumaError("Accepted a symbolic link as the runtime lock.")
    }
}

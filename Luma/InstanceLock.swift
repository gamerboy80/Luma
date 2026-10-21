import Foundation
import Darwin

/// A process-scoped advisory lock. Retain the descriptor until process exit;
/// unlinking its marker would allow two different inodes to be locked at once.
final class InstanceLock {
    enum Claim { case primary, alreadyRunning }
    private var descriptor: Int32 = -1

    func claim(at url: URL) throws -> Claim {
        if descriptor >= 0 { return .primary }
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else { throw LumaError(String(cString: strerror(errno))) }
        var keep = false
        defer { if !keep { Darwin.close(fd) } }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else { throw LumaError(String(cString: strerror(errno))) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
            throw LumaError("The instance lock is not a regular file owned by this user.")
        }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK); lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(fd, F_SETLK, &lock) == 0 else {
            if errno == EACCES || errno == EAGAIN { return .alreadyRunning }
            throw LumaError(String(cString: strerror(errno)))
        }
        descriptor = fd; keep = true
        return .primary
    }
}

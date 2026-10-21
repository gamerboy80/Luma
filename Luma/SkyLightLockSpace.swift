import AppKit
import Darwin

/// SkyLight is private. In particular, its space mutators do not return CGError:
/// reading their return register as an error rejected successful operations on
/// macOS 27. Validate the observable level, membership and destruction instead.
@MainActor final class SkyLightLockSpace {
    struct Operations {
        var connection: Int32
        var create: () -> UInt64
        var setLevel: (UInt64, Int32) -> Void
        var level: (UInt64) -> Int32
        var show: (UInt64) -> Void
        var hide: (UInt64) -> Void
        var attach: (UInt64, Int) -> Void
        var spaces: () throws -> [UInt64]
        var windowSpaces: (Int) throws -> [UInt64]
        var destroy: (UInt64) -> Void
        // Keep resolved functions mapped until the last operation has finished.
        var owner: AnyObject? = nil
    }

    private let operations: Operations
    private let id: UInt64
    private var removed = false

    convenience init() throws { try self.init(operations: Self.liveOperations()) }

    init(operations: Operations) throws {
        guard operations.connection > 0 else {
            throw LumaError("Luma has no usable WindowServer connection for the experimental overlay.")
        }
        self.operations = operations
        id = operations.create()
        guard id > 0 else { throw LumaError("SkyLight could not create a lock-screen space.") }
        do {
            operations.setLevel(id, 400)
            let actual = operations.level(id)
            guard actual == 400 else {
                throw LumaError("SkyLight did not apply lock-screen space level 400 (read back \(actual)).")
            }
            guard try operations.spaces().contains(id) else {
                throw LumaError("WindowServer did not retain Luma's lock-screen space.")
            }
            operations.show(id)
        } catch {
            let cleanup = remove()
            throw LumaError(error.localizedDescription + (cleanup.map { " Cleanup also failed: \($0)" } ?? ""))
        }
    }

    func attach(_ window: NSWindow) throws {
        guard !removed, window.windowNumber > 0 else { throw LumaError("The lock-screen window is no longer available.") }
        operations.attach(id, window.windowNumber)
        guard try operations.windowSpaces(window.windowNumber).contains(id) else {
            throw LumaError("WindowServer did not attach scene window \(window.windowNumber) to Luma's lock-screen space.")
        }
    }

    func setVisible(_ visible: Bool) {
        guard !removed else { return }
        if visible { operations.show(id) } else { operations.hide(id) }
    }

    @discardableResult func remove() -> String? {
        guard !removed else { return nil }
        operations.hide(id)
        operations.destroy(id)
        do {
            guard try !operations.spaces().contains(id) else {
                return "WindowServer still reports Luma's space \(id) after SLSSpaceDestroy."
            }
            removed = true
            return nil
        } catch {
            return "Could not verify lock-screen space cleanup: \(error.localizedDescription)"
        }
    }

    private final class DynamicLibrary {
        let handle: UnsafeMutableRawPointer
        init() throws {
            guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
                throw LumaError("The private SkyLight framework is unavailable on this macOS version.")
            }
            self.handle = handle
        }
        deinit { dlclose(handle) }
        func resolve<T>(_ name: String, as type: T.Type) throws -> T {
            guard let address = dlsym(handle, name) else { throw LumaError("SkyLight is missing required symbol \(name).") }
            return unsafeBitCast(address, to: type)
        }
    }

    private static func liveOperations() throws -> Operations {
        typealias Main = @convention(c) () -> Int32
        typealias Create = @convention(c) (Int32, Int32, Int32) -> UInt64
        typealias SetLevel = @convention(c) (Int32, UInt64, Int32) -> Void
        typealias GetLevel = @convention(c) (Int32, UInt64) -> Int32
        typealias List = @convention(c) (Int32, CFArray) -> Void
        typealias Attach = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void
        typealias Destroy = @convention(c) (Int32, UInt64) -> Void
        typealias CopySpaces = @convention(c) (Int32, Int32) -> Unmanaged<CFArray>?
        typealias CopyWindowSpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

        let library = try DynamicLibrary()
        let main = try library.resolve("SLSMainConnectionID", as: Main.self)
        let create = try library.resolve("SLSSpaceCreate", as: Create.self)
        let setLevel = try library.resolve("SLSSpaceSetAbsoluteLevel", as: SetLevel.self)
        let level = try library.resolve("SLSSpaceGetAbsoluteLevel", as: GetLevel.self)
        let show = try library.resolve("SLSShowSpaces", as: List.self)
        let hide = try library.resolve("SLSHideSpaces", as: List.self)
        let attach = try library.resolve("SLSSpaceAddWindowsAndRemoveFromSpaces", as: Attach.self)
        let destroy = try library.resolve("SLSSpaceDestroy", as: Destroy.self)
        let copySpaces = try library.resolve("SLSCopySpaces", as: CopySpaces.self)
        let copyWindowSpaces = try library.resolve("SLSCopySpacesForWindows", as: CopyWindowSpaces.self)
        let connection = main()
        func decode(_ result: Unmanaged<CFArray>?) throws -> [UInt64] {
            guard let result, let numbers = result.takeRetainedValue() as? [NSNumber] else {
                throw LumaError("WindowServer could not return space membership for the overlay.")
            }
            return numbers.map(\.uint64Value)
        }
        return Operations(connection: connection, create: { create(connection, 1, 0) },
                          setLevel: { setLevel(connection, $0, $1) }, level: { level(connection, $0) },
                          show: { show(connection, [$0] as CFArray) }, hide: { hide(connection, [$0] as CFArray) },
                          attach: { attach(connection, $0, [$1] as CFArray, 7) },
                          spaces: { try decode(copySpaces(connection, 0xf)) },
                          windowSpaces: { try decode(copyWindowSpaces(connection, 0xf, [$0] as CFArray)) },
                          destroy: { destroy(connection, $0) }, owner: library)
    }
}

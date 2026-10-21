import AppKit

enum LockOverlayTests {
    @MainActor static func verify() throws {
        struct State {
            var spaces = Set<UInt64>()
            var membership: [UInt64] = []
            var level: Int32 = 0
            var destroys = 0
            var shows = 0
            var hides = 0
            var keepSpace = false
        }
        var state = State()
        // IDs must not be truncated to 32 bits at any bridge operation.
        let id: UInt64 = (1 << 40) + 7
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw LumaError("Lock overlay regression: \(message)") }
        }
        func rejects(_ operation: () throws -> Void, containing text: String) throws {
            do { try operation() }
            catch { try check(error.localizedDescription.contains(text), "Unexpected error: \(error.localizedDescription)"); return }
            throw LumaError("Lock overlay regression: expected rejection containing \(text)")
        }
        let operations = SkyLightLockSpace.Operations(
            connection: 1,
            create: { state.spaces.insert(id); return id },
            setLevel: { sid, level in if sid == id { state.level = level } },
            level: { sid in sid == id ? state.level : -1 },
            show: { sid in if sid == id { state.shows += 1 } },
            hide: { sid in if sid == id { state.hides += 1 } },
            attach: { sid, _ in state.membership = [sid] },
            spaces: { Array(state.spaces) },
            windowSpaces: { _ in state.membership },
            destroy: { sid in state.destroys += 1; if !state.keepSpace { state.spaces.remove(sid) } }
        )
        let space = try SkyLightLockSpace(operations: operations)
        try check(state.level == 400 && state.shows == 1, "Void mutators should succeed through verified postconditions")
        try space.attach(windowNumber: 50)
        try check(state.membership == [id], "64-bit space ID must survive window attachment")
        space.setVisible(false); space.setVisible(true)
        try check(state.hides == 1 && state.shows == 2, "Lock/wake should show the space again and unlock should hide it")
        try check(space.remove() == nil && state.spaces.isEmpty, "Cleanup should verify that the space disappeared")
        try check(space.remove() == nil && state.destroys == 1, "Cleanup should be idempotent")
        try rejects({ try space.attach(windowNumber: 50) }, containing: "no longer available")

        state = State()
        var wrongLevel = operations
        wrongLevel.level = { _ in 300 }
        try rejects({ _ = try SkyLightLockSpace(operations: wrongLevel) }, containing: "read back 300")
        try check(state.destroys == 1 && state.spaces.isEmpty, "Failed setup should destroy its space")

        state = State()
        var wrongMembership = operations
        wrongMembership.windowSpaces = { _ in [] }
        let unattached = try SkyLightLockSpace(operations: wrongMembership)
        try rejects({ try unattached.attach(windowNumber: 50) }, containing: "did not attach")
        try check(unattached.remove() == nil, "Failed window attachment must still allow cleanup")

        state = State(); state.keepSpace = true
        let retained = try SkyLightLockSpace(operations: operations)
        try check(retained.remove()?.contains("still reports") == true, "Cleanup must report a retained space")
        state.keepSpace = false
        try check(retained.remove() == nil, "Failed cleanup must remain retryable")

        state = State()
        var unavailable = operations; unavailable.connection = 0
        try rejects({ _ = try SkyLightLockSpace(operations: unavailable) }, containing: "WindowServer connection")
        try check(state.spaces.isEmpty, "No space should be created without a valid connection")
        var missingReadback = operations
        missingReadback.spaces = { throw LumaError("fixture readback unavailable") }
        try rejects({ _ = try SkyLightLockSpace(operations: missingReadback) }, containing: "Could not verify")
        try check(state.spaces.isEmpty, "Unreadable postconditions must still attempt cleanup")
        let auth: [String: Any] = [kCGWindowNumber as String: 50]
        let overlay: [String: Any] = [kCGWindowNumber as String: 60]
        try check(LockOverlayStacking.isBelowAuthentication(window: 60, authentication: [50], orderedWindows: [auth, overlay]), "Overlay must be behind authentication UI")
        try check(!LockOverlayStacking.isBelowAuthentication(window: 60, authentication: [50], orderedWindows: [overlay, auth]), "An overlay above login controls must stay hidden")
        try check(!LockOverlayStacking.isBelowAuthentication(window: 60, authentication: [], orderedWindows: [overlay]), "Missing authentication windows must fail closed")
        try check(!LockOverlayStacking.isBelowAuthentication(window: 60, authentication: [50, 51], orderedWindows: [auth, overlay]), "Unverifiable authentication ordering must fail closed")
        print("PASS: lock overlay void API calls, 64-bit IDs, lifecycle, membership validation, setup rollback, and cleanup retry")
    }

    /// Explicit host-only check. This does not lock the Mac, change preferences,
    /// display a scene, or write files. The window stays transparent throughout.
    @MainActor static func verifyWindowServer() throws {
        let space = try SkyLightLockSpace()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        window.canBecomeVisibleWithoutLogin = true
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close(); _ = space.remove() }
        try space.attach(window)
        space.setVisible(false); space.setVisible(true)
        if let error = space.remove() { throw LumaError(error) }
        print("PASS: live WindowServer space level 400, transparent window membership, show/hide calls, and verified space removal")
    }
}

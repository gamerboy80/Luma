# Lock-screen overlay startup failure — 2026-10-21

On macOS 27.0.1 (26A434), an isolated WindowServer probe reproduced the
overlay's startup failure without locking the Mac or changing wallpaper settings.
With the old `Int32` return declarations, both `SLSShowSpaces` and `SLSHideSpaces`
appeared to return `3`. Luma required zero and destroyed the newly created space
before creating any scene windows. Its toggle therefore reverted to off.

Those routines return `void`; the observed integer is not an error code.
[yabai's SkyLight declarations](https://github.com/asmvik/yabai/blob/master/src/osax/payload.m)
and the [CGS space headers](https://github.com/NUIKit/CGSInternal/blob/master/CGSSpace.h)
declare show/hide this way. The older SkyLightWindow example gives them integer
returns but ignores those results; copying that declaration and then adding a
zero-result guard introduced Luma's failure.

The corrected wrapper keeps full-width space IDs, calls mutators without using
return registers, and checks `SLSSpaceGetAbsoluteLevel`, `SLSCopySpacesForWindows`,
and `SLSCopySpaces` for the observable postconditions. A probe verified level
400, window membership in the created space, and absence of that space after
destruction. The visible-spaces mask does not reliably report these unmanaged
spaces, so Luma does not use it as proof of locked-screen compositing.

The original full-screen window also copied a topmost widget window level.
[Atoll's fullscreen background implementation](https://github.com/Atoll-Labs/Atoll/blob/dev/DynamicIsland/managers/FullScreenArtworkWindowManager.swift)
uses desktop window level + 1 for backgrounds so authentication controls can
remain above them. Luma now follows that background approach, prevents the app's
Hide action from hiding the overlay windows, and supplements distributed lock
notifications with current-session polling. The UI reports renderer readiness
and warnings separately from space creation.

Regression coverage in `Tests/LockOverlayTests.swift` exercises void operations,
IDs above 32 bits, attachment rejection, failed setup cleanup, cleanup retry and
an unavailable connection. `Scripts/test-scenes.sh --live-lock-overlay` runs
those tests, the transparent-window WindowServer check, and the normal scene
and SceneScript suite. It never locks the Mac. Physical lock/unlock, WebKit
compositing while authenticated UI is visible, and sleep transitions remain
private-API behavior that needs a real lock-screen check.

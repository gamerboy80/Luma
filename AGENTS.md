# Luma project instructions

These instructions apply to the Luma macOS app under this directory. Read `README.md` for the current feature and compatibility notes before changing behavior.

## Persistent data and Clear Data

**Every persistent file, preference, or system change Luma creates must have an explicit entry in the Clear Data review and a matching cleanup or restore path.** Do not add a write path and leave its ownership, disclosure, or cleanup implicit.

Before shipping a feature that writes data:

1. Inventory every created, copied, moved, or modified file and every changed system setting. Include successful output, failure/retry data, backups, receipts, markers, and preferences.
2. Update `AppModel.clearDataPlan()` in `Luma/LumaApp.swift` so the confirmation view names what will be removed, retained, or restored.
3. Add or update the corresponding cleanup in `AppModel.clearLumaData()` and the owning service. Restore prior system state from a receipt before deleting the receipt.
4. Establish ownership for each managed item: use an ID recorded in Luma's library/index, a validated ownership marker, or a receipt that records both the original and Luma-installed state. Check paths and reject symlinks before deleting. Remove only items that the ownership record proves Luma created.
5. Preserve unknown files and user-selected exports. If Luma writes outside its managed data folder (for example, a file saved through `NSSavePanel`), state whether Clear Data preserves it or track it for explicit cleanup. Never silently delete user exports.
6. Give temporary work files a guaranteed cleanup path on success, error, and cancellation. Keep failed downloads or imports when the feature promises retry, and do not remove their source files.
7. Add focused tests for the ownership and cleanup behavior when changing storage or restoration logic.

Clear Data is an uninstall-style reset of Luma's data, not the application bundle. Keep its review and confirmation step. On success, restore recorded changes, remove only Luma-owned data, prevent shutdown callbacks and timers from recreating files, and quit. The app remains installed; a later launch may create a fresh library. If cleanup fails, show the error and leave enough ownership information to retry safely.

### Current storage map

| Area | Current ownership / cleanup rule |
| --- | --- |
| `~/Library/Application Support/Luma/library.json` and `Media/<UUID>/` | The library lists wallpaper IDs and managed folder names. Imported files are Luma copies; remove only listed Luma folders. Preserve unknown `Media` entries. Built-in wallpapers are also generated under `Media`. |
| `EditorProjects/` | The project index lists UUID-named project folders and copied assets. Compare its bytes with the loaded/saved index before editing or cleanup; external index edits abort the operation. Clear indexed projects and the index; retain unknown entries and remove the directory only when empty. |
| `DesktopStills/` | `ownership.json` records Luma-generated stills, including superseded files during replacement, the installed image, and the prior desktop image. Preserve later user choices. Restore every display before deleting shared owned stills and the receipt. Never save a new receipt during successful cleanup. |
| `NativeCache/<UUID>/` | Temporary native export work is marked `.luma-owned`. Remove only valid UUID folders with the expected marker; clean work on every task exit. |
| `LockScreenFallbacks/` | The `.luma-owned` marker identifies Luma's prepared fallback. Remove the fallback and marker only after validating both; retain unknown files. |
| `NativeBackups/`, `native-receipt.json` | Receipts, original catalog snapshots, per-install manifest digest/existence and created-directory records, and selection snapshots support restoration of Luma's changes to the selected macOS wallpaper catalog. Restore before deleting. Remove an originally absent manifest only when exact hashes link the live manifest through consecutive Luma installs back to its creation; any intervening external edit breaks that chain. Restore selection data only if it still matches Luma's recorded write; preserve later user changes and unknown catalog fields. |
| UserDefaults and old container preferences | App preferences primarily live in `library.json`. Bookmark, lock-overlay, fallback, and launch-at-login tracking keys are separate; clear Luma's keys while preserving unrelated preference values. Restore the original launch-at-login state before clearing its tracking keys. |
| Single-instance runtime lock | An empty per-user marker under macOS temporary storage is opened with `O_NOFOLLOW` and held with an `fcntl` write lock while Luma runs. Clear Data review must disclose that the OS lock is released when Luma exits; keep the marker to avoid an unlink/recreate race, and let macOS clean temporary storage. |
| Scene media source | `luma.sceneMedia.source` stores only the user's Music/Spotify/off selection. Clear Data stops polling, invalidates pending results, removes that key, and discards metadata in memory. Track queries and scene local storage write no files. Automation consent belongs to macOS; explain how to revoke it in System Settings rather than claiming to reset it. |
| User-selected external locations | SteamCMD downloads/install files, Steam library files, Wallper originals, and files explicitly exported by the user are outside Luma's managed library. Preserve them. |
| Temporary scene, render, and encode files | Use a unique temporary directory and guaranteed cleanup on success, failure, and cancellation. Do not mistake retained failed Workshop downloads for temporary files. |

When adding a new row, update this map and the in-app Clear Data review together. Re-audit this map whenever a new `write`, `createDirectory`, `copyItem`, `moveItem`, preference write, or external system mutation is introduced.

## Behavior to preserve

- Wallpaper playback continues when the library window is closed or hidden. Keep Dock/window reopening and menu-bar controls usable; do not make an activation-policy change that strands the app without an accessible window or controls.
- Mark library windows with LibraryWindowMarker and use LumaWindowIdentity for Open Library selection. A visible Settings window or file panel is not evidence that the library is open.
- Luma is a single running process per user. Keep the Launch Services prohibition and runtime file lock together; a duplicate launch should open the primary instance's library. Start with accessory activation and show the Dock icon only while a Luma window is visible.
- Acquire the instance lock before constructing `AppModel` or loading writable services. Attach the model to the app delegate independently of window presentation so login launches still clean up on exit.
- Unreadable or invalid library/project indexes are preserved and cannot be overwritten by subsequent edits. Failed index saves must roll back in-memory project lists and must not delete referenced media.
- Clear Data preflights library/media/cache, editor-project ownership, desktop-still restoration, native wallpaper receipts/backups, and fallback markers before changing playback or system state. Library, desktop-still, and native receipt records are compared with the exact bytes loaded by the service; external edits or corrupt records stop cleanup and remain available for recovery. It may retry from a syntactically valid editor ownership index when an indexed folder is already missing or its scene document is malformed; it still rejects unsafe paths and preserves corrupt indexes and unindexed entries. Review counts must come from validated ownership, not only objects that loaded successfully.
- Imported media and editor assets are copied into Luma's managed folders. Do not move, rename, or delete Wallper originals, SteamCMD, or the Steam library.
- Track active imports in LibraryStore for every entry point, including Wallper and nested batch imports. Clear Data must reject an active import even when no UI activity label is present. Honor cancellation before copying or publishing a library entry.
- Steam Workshop success imports a managed copy. Preserve failed downloads/imports for retry and report useful errors. Steam credentials are transient and must not be written to settings, logs, or process arguments.
- Keep SceneScript review and execution as separate user actions. A scene's approval is tied to its reviewed source fingerprint; edits invalidate approval. Scripts stay off by default, editor preview must not implicitly run them, and renderer changes must preserve the existing isolation/watchdog safeguards after inspecting their implementation.
- The SceneScript approval toggle does not make arbitrary scene content trusted. Continue validating bridge commands, paths, messages, and resource limits at the host boundary.
- SceneScript clock, shared helpers, and matrix APIs remain inside the SES Worker. Keep text styles live across the bridge, preserve vector methods when refreshing snapshots, and never use a renderer-thread Function constructor to regain compatibility. See `research/SCENESCRIPT_COMPATIBILITY.md` for the supported API surface and limits.
- Native media metadata is user-selected and read-only. Only fixed Music/Spotify queries may run; scene content must never supply AppleScript, an application target, shell code, or native automation commands. Keep source selection off by default and stop retries after denied access.
- Treat WebWallGL as a pinned bundled renderer. Inspect its checked-in version and verified editor/playback APIs before using or claiming an API. Preserve its licenses in `Vendor/DEPENDENCIES.md` and its bundled license notices.
- Wallpaper Engine compatibility is partial. Do not invent undocumented scene schemas or claim full fidelity. Keep unsupported features visible in diagnostics or documentation.
- The live lock-screen scene overlay uses private SkyLight APIs and is experimental and opt-in. Keep its cleanup on disable and normal exit, respect SceneScript approval, and provide a static fallback. macOS has no supported public API here for applying a separate lock-screen still without risking a desktop wallpaper change; do not claim otherwise.
- SkyLight space IDs are 64-bit. Do not interpret void mutators (including show/hide) as CGError returns; validate level, window membership and destruction with readback instead. Full-screen background windows must use a background window level, not the reference widget's topmost level. `test-scenes.sh --live-lock-overlay` exercises a temporary space and transparent window without locking the Mac.
- Luma's native Aerial wallpaper catalog workflow is undocumented and separate from the live overlay. Preserve backups, ownership checks, stale-write checks, and conditional restore behavior.
- Do not invent Wallper catalog search endpoints. The local Wallper app inspection did not verify a search route, request schema, required headers, or signature protocol; see `research/WALLPER_CATALOG_PROTOCOL.md`.
- Scene/project paths must remain relative and inside the project. Reject traversal and symbolic links, save atomically, preserve unknown scene fields and unedited package entries, and never mutate original source assets during edits.
- Keep the app's minimum macOS target at 14 unless the project requirements are deliberately revised. `SMAppService` is the supported launch-at-login mechanism; synchronize the UI with actual registration state and surface errors.

## Build and verification

- The Xcode project is `Luma.xcodeproj`; Swift app sources are in `Luma/`, tests in `Tests/`, helper scripts in `Scripts/`, and renderer/vendor notes in `Vendor/`.
- Build the local app with `./Scripts/build.sh`. It creates build products and generated signing entitlements under `build/`. Use `./Scripts/build.sh --sandboxed` only when validating the sandboxed/Terminal-download configuration. The normal local build is unsandboxed so it can launch a user-selected SteamCMD executable; do not bundle SteamCMD.
- Focused verification scripts are `./Scripts/test.sh`, `./Scripts/test-scenes.sh`, `./Scripts/test-editor.sh`, and `./Scripts/test-instance.sh`. Use the relevant script and build after changes to the corresponding behavior. Scene tests may launch WebKit and export movies; native wallpaper restoration, lock/unlock, physical-display behavior, and authenticated Workshop downloads require the user's macOS environment.
- Standalone Swift test binaries target macOS 14, matching the app minimum. Core media and scene suites require host AVFoundation encoders and WebKit/GPU services; a restricted process sandbox may fail with AVFoundation `-11834 Cannot Encode` or service-unavailable errors. Run those suites with the host services available and treat such errors as environment failures, never as passes. Core test failures include the current test phase to make diagnosis actionable.
- `.github/workflows/ci.yml` builds both local profiles, packages them as artifacts, and runs the isolated regression suites. Keep permissions minimal and action commits pinned; Dependabot proposes action updates. Tests must not require Steam credentials or modify the real wallpaper catalog.
- Never test Clear Data against the user's real library as part of routine verification. Exercise cleanup with isolated temporary roots and fake receipts/fixtures.


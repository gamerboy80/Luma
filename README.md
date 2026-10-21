# Luma

A custom Swift live wallpaper app for macOS 14 and later. SwiftUI controls and AppKit desktop windows, AVFoundation video playback, and a bundled WebWallGL renderer for Wallpaper Engine scenes.

## Run

The built app is at `build/Build/Products/Release/Luma.app`. Open it, choose a Luma Original or import a video/project folder, then click **Set Wallpaper**. Wallpapers remain behind desktop icons. Closing or hiding the library leaves them running; the menu bar provides pause, resume, reload, playlist advance, and quit.

Build locally with a full Xcode installation:

```sh
./Scripts/build.sh
open build/Build/Products/Release/Luma.app
```

`Luma.xcodeproj` is available for editing. The build script supplies the macOS target and local signing. The default local build is unsandboxed so it can execute your SteamCMD installation; hardened runtime remains enabled. Use `./Scripts/build.sh --sandboxed` for a sandboxed build with Terminal downloads. Existing sandboxed Luma library data and connected folders are reused. Use that script for a runnable local build; the template's default Xcode signing settings are not a release configuration. No paid developer team is required. The app is locally signed, not Apple notarized. To distribute it, configure your own Developer ID and notarization.

## Included

- Local video/image import; Wallpaper Engine video, scene, and local web projects; parent-folder batch import; direct HTTPS video downloads with progress and cancellation.
- Search, type filters, favorites, native previews, metadata and thumbnails, library persistence, managed media copies, and source-preserving deletion.
- Independent assignments per display, stable display IDs, fill/fit/stretch, pan/zoom, volume, video speed, per-display pause and reload.
- Retained `AVPlayerLooper` objects; first-frame transitions; failed replacements keep the previous wallpaper; bounded retries for stalled videos; screen/Space changes and wake recovery; Cmd+H leaves desktop windows visible.
- Separate user pause intent and temporary pause holds for sleep, lock, battery, Low Power Mode, fullscreen apps, high CPU, and thermal pressure.
- Playlist rotation/shuffle and day/night schedules; optional desktop still-frame synchronization; launch at login through SMAppService.
- Offline scene rendering through WebWallGL: layered scenes, effects, particles, models, textures, user properties, and opt-in SceneScript, subject to upstream compatibility. Native cursor position is supplied for parallax.
- **Review Scripts…** opens a read-only source review with file/JSON locations, source search, and copy. Inline JSON scripts and loose/packed JavaScript files are included. **Approve Scripts** saves approval and leaves scripts off; the separate **Run SceneScript** toggle is locked until approval. Incomplete reviews cannot be approved. Source is checked again before approval, enabling, and renderer startup; changes require a new review. Turning the toggle off stops running script hosts while retaining approval; **Revoke Approval** turns scripts off and removes saved approval. Older scene trust toggles require this new review once.
- Steam Workshop search and item lookup; SteamCMD wrapper with login/Steam Guard input, output, cancellation, validation and completed-project import; Terminal fallback.
- Experimental macOS 26+ native lock screen/screen saver installation for videos and rendered scene loops, including HEVC Main10 conversion, temporal-layer metadata checks, fresh IDs, catalog backups, schema checks, stale-write protection, and ownership-aware removal.
- Three procedural Luma Original web wallpapers. No third-party wallpaper assets are included.

## Steam Workshop setup

1. Install Valve's SteamCMD for macOS. If its Intel executable requires Rosetta, install Rosetta using Apple's normal workflow. SteamCMD is not bundled or installed automatically.
2. In **Steam Workshop → SteamCMD Setup**, select the writable folder containing `steamcmd.sh` or `steamcmd` (including `~/Steam`). Luma activates the folder access granted by the file picker before detecting or launching SteamCMD. Luma prefers the actual executable over Valve’s launcher script, supplies its library paths, and handles restart code 42 after updates. A readable shell script is accepted without an executable bit, because it runs through Bash. Use **Check Installation** to verify startup without logging in.
3. Enter your Steam account name. The account must own Wallpaper Engine and have access to the selected Workshop item.
4. Paste a Workshop link/ID for unauthenticated metadata lookup. For text search, enter a Steam Web API key under **Search connection**. Luma keeps the key in memory. You can also open Workshop in your browser.
5. Click **Download**. Enter a password or Steam Guard code only when SteamCMD asks for it. Luma sends this through stdin and never saves it in settings or arguments. Valve's own SteamCMD may persist its login session in its selected folder.
6. A successful download is copied into Luma's library. Ownership, login, API limits, and Workshop availability errors are shown to you. There is no anonymous-access bypass.

If macOS sandbox restrictions, SteamCMD runtime dependencies, or its interactive input prevent an in-app download, use **Export Terminal Download**, open the generated `.command` yourself, then import `steamapps/workshop/content/431960/<item-id>`. Existing downloaded folders can always be imported.

Official API references: [Workshop search](https://partner.steamgames.com/doc/webapi/IPublishedFileService#QueryFiles), [item details](https://partner.steamgames.com/doc/webapi/ISteamRemoteStorage#GetPublishedFileDetails), [SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD).

## Scene compatibility

Import a complete project folder containing `project.json` and `scene.pkg` or loose scene files. A standalone `.pkg` can also be imported. For original built-in textures/fonts/shaders, select the `assets` folder from your own Windows Wallpaper Engine installation in Settings. Luma bundles no proprietary engine assets.

The native application is Swift; the scene runtime is bundled JavaScript/WebGL in WKWebView. This is broad scene compatibility, not a claim of complete fidelity with Wallpaper Engine. Some effects, scripts, video codecs, and models may differ or fail; Diagnostics shows renderer warnings. Application wallpapers cannot run on macOS. Local web projects cannot load arbitrary remote resources under the renderer's content policy. A standalone HTML import copies just that file; import a project folder to include its assets.

System-audio capture, music/Now Playing integration, Workshop publishing, and cloud synchronization are not implemented. Audio spectrum input is explicitly silent rather than simulated. SceneScript is disabled by default for imported projects; enable it in the wallpaper details only for projects you trust.

## Scene editor

The **Scene Editor** page creates, opens, duplicates, renames, imports, and exports scene projects. It keeps editor projects in Luma's managed `EditorProjects` folder, separate from the wallpaper library. Import makes a copy; export writes a copy. The editor rejects symbolic links and unsafe relative paths, preserves unknown scene JSON fields and unedited PKGV package entries, validates scene data before saving, and atomically replaces edited files. Layer edits have up to 100 in-memory undo steps. Layer deletion asks for confirmation.

The preview is the existing `SceneHost` backed by the bundled WebWallGL `editorOf` API. It provides scene playback, seeking, frame stepping, playback speed, layer snapshots and hit testing. The layer panel supports selection, multi-selection, reorder, rename, visibility, lock, duplicate, and delete. The viewport supports pan, zoom, move, resize, rotate, 16-unit grid snapping, and center guides. Text layers can be added. Existing image, video, text, particle, model, and effect layers can be inspected and edited through their complete JSON, with structured controls for common text, font, size, opacity, and transform fields. Project assets can be copied into a project-local `assets` folder and previewed; source files are left alone. **Show project files** opens the managed copy in Finder for editing loose project files.

The pinned renderer bundle does not document a general animation or keyframe file schema. Its `setAnimationLayers` editor method accepts model animation references, so Luma uses the verified scene clock for playback and scrubbing, and leaves keyframe authoring disabled instead of inventing a serialized format. Grouping and creating new image/video/particle/model/effect layers are unavailable because this bundled API does not provide verified payload templates. Existing layer data for these types remains editable through JSON. Color, anchor, material, effect, and layer-specific playback properties are available there. Scene resolution and renderer general settings use the scene JSON inspector; anti-aliasing, particle quality, and post-processing controls affect the preview, while output frame rate and Retina rendering follow Luma preferences. Audio-reactive data follows the existing playback runtime and is not synthesized by the editor.

SceneScript review remains read-only and separate from the run toggle. Inline script properties can be edited in the layer JSON inspector; loose script files can be edited from the project copy in Finder. Packed package script entries can be reviewed but cannot be edited directly in the review sheet. Any scene edit clears the project's approval, and enabling execution rechecks the reviewed fingerprint. The Scripts inspector shows diagnostics reported by WebWallGL. The editor preview never opts into script execution by itself.

## Native lock screen

### Experimental live scene overlay

The Lock Screen page has a separate opt-in live scene overlay. It dynamically resolves private SkyLight symbols, creates a space at the lock-screen notification level, assigns a non-interactive `NSWindow` to it, and reacts to lock, unlock, sleep, and wake notifications. It pauses SceneHost while unlocked/asleep and resumes it while locked. Disabling the option or a normal Luma shutdown closes the WebKit scene windows, hides the private space, and calls `SLSSpaceDestroy`. If the required symbols or calls fail, Luma disables the overlay and shows an error. A force quit or crash cannot run Luma's cleanup handler.

This is an unsupported experiment. [Atoll](https://github.com/Ebullioscopic/Atoll) and [SkyLightWindow's SkyLight operator](https://github.com/Lakr233/SkyLightWindow/blob/main/Sources/SkyLightWindow/SkyLightOperator.swift) demonstrate private-space windows for small lock-screen widgets; [its topmost window](https://github.com/Lakr233/SkyLightWindow/blob/main/Sources/SkyLightWindow/TopmostWindow.swift) sets `canBecomeVisibleWithoutLogin` and a very high window level. That does not establish that a continuously animated WKWebView/WebGL scene will keep rendering through every lock, sleep, display, and macOS transition. Apple can change the APIs, WebKit can be suspended, and the overlay may disappear or render a frozen frame. The toggle remains off by default. SceneScript still runs only when its existing review fingerprint and execution toggle both allow it.

**Static fallback:** **Prepare Static Fallback** saves a PNG under Luma's managed data. For a scene it tries source images first, then a representative video frame, then a captured renderer frame; a project preview is the last resort if rendering cannot start. The preview can be opened in System Settings → Wallpaper for manual selection. Apple's [custom-photo instructions](https://support.apple.com/guide/mac-help/choose-your-desktop-picture-mchlp3013/mac) describe setting the desktop picture, and its public [`NSWorkspace.setDesktopImageURL`](https://developer.apple.com/documentation/appkit/nsworkspace/setdesktopimageurl%28_%3Afor%3Aoptions%3A%29) API also targets the desktop. macOS provides no supported public API for setting a separate lock-screen-only photo, so Luma cannot apply this still to the lock screen without risking a desktop wallpaper change. Luma only prepares and previews the file; choosing it manually in System Settings may also change the desktop. If you selected the PNG there, choose another wallpaper before removing the file in Luma; Luma cannot track or restore that manual selection.

The older Aerial catalog workflow below is separate. It edits an undocumented Apple catalog and is not used by the live overlay or the PNG fallback.

1. Open **Lock Screen** and choose a video or scene.
2. Connect the user's `~/Library/Application Support/com.apple.wallpaper` folder through the macOS file picker (⇧⌘G can enter that path).
3. For a scene, choose **Render loop with fallback**, **Use scene video or image**, or **Capture a still frame**. Loop rendering uses the chosen duration at 1920×1080/30 fps; video input retains its source size and transform. Automatic mode falls back from loop rendering to usable scene media, then a captured scene still, then the project preview. Capture mode tries a still first. Source media is found in loose folders and PKGV packages, including decoded image/video textures. Unreadable media is skipped. Static fallbacks are packaged as constant-image native videos and remain visually still. The installed receipt shows the source used. These checks do not guarantee that every private macOS wallpaper schema will accept the installed asset. Ordinary images can also be installed.
4. Click **Install for Lock Screen**. Luma encodes HEVC Main10 with temporal layers and refuses to install the movie if `tscl`/`tsas` groups are absent.
5. In System Settings → Wallpaper, select the new **Luma** collection. Enable its screen saver option if desired. Optional automatic selection understands observed `Idle` and `Linked` store shapes and preserves other fields. Linked selections may also change the native desktop.

This uses Apple's undocumented Aerials catalog format. It can change across macOS releases. The installer preserves unknown catalog fields, writes app-owned records, stages media before publishing, checks for concurrent changes, and keeps backups in Luma's `NativeBackups` directory. It does not restart wallpaper services on launch or fight a user's later wallpaper choice. If macOS caches the old catalog, log out and back in. **Remove Luma Collection** removes owned assets and restores a selection backup only if the current store still matches Luma's previous write.

A rendered scene loop is a video: it cannot stay interactive, react to future music, or keep a live clock on the lock screen. Loop continuity depends on the scene. macOS controls motion at lock/unlock and during screen saver/idle/sleep; constant movement behind the password prompt is not guaranteed. FileVault preboot is separate.

## Wallper catalog

Static inspection of the local Wallper 1.12.1 app confirms its CDN roots and backend host, but does not establish the catalog search route, request schema, required headers, or response-signature protocol. Luma skips the Wallper catalog connection rather than sending guessed requests. The evidence and missing details are recorded in [WALLPER_CATALOG_PROTOCOL.md](research/WALLPER_CATALOG_PROTOCOL.md). Local imports and direct video URLs work independently.

## Validation

```sh
./Scripts/test.sh
./Scripts/test-scenes.sh
./Scripts/test-editor.sh
```

Focused checks use generated temporary media and do not modify the system wallpaper catalog. They cover path traversal/symlinks, Workshop IDs, overlapping pause holds, native catalog/selection preservation, import rollback, persistence, original-source preservation, and real HEVC temporal encoding. The scene integration check creates a PKGV0012 package, loads it in WebKit, checks rendered pixels, and exports a playable scene movie. Native lock/unlock, multiple physical displays, Steam account downloads, and arbitrary Workshop scene fidelity require testing in the user's environment.

The renderer is pinned and its licenses/source links are recorded in [Vendor/DEPENDENCIES.md](Vendor/DEPENDENCIES.md). Swift source is under `Luma/`.

Verified locally: Release build succeeded; 56 focused assertions passed; the packed-scene/WebGL-capture/movie-export, image/video texture extraction, and captured-still checks passed; procedural preview, scene preview, and desktop application were exercised in the running app. The unsandboxed app also launched the selected SteamCMD executable successfully with `+quit`, without logging in; library and folder connections survived the build profile change. Actual account login and Workshop downloads require user credentials and remain unverified. No native system wallpaper catalog was changed during these checks.

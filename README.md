# Luma

A custom Swift live wallpaper app for macOS 14 and later. SwiftUI controls and AppKit desktop windows, AVFoundation video playback, and a bundled WebWallGL renderer for Wallpaper Engine scenes.

## Run

The built app is at `build/Build/Products/Release/Luma.app`. Open it, choose a Luma Original or import a video/project folder, then click **Set Wallpaper**. Wallpapers remain behind desktop icons. Closing or hiding the library leaves them running; the menu bar provides pause, resume, reload, playlist advance, and quit. Luma runs as one process per user; launching it again brings the existing library forward. It starts as a menu-bar app and shows its Dock icon only while a Luma window is visible.

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

## Display adjustments

Choose a display on **Displays** to adjust its wallpaper in a frame matching that screen's current aspect ratio. The name, backing-pixel resolution, and persistent display identifier identify the target. Fill, Fit, Stretch, zoom, and horizontal/vertical positioning share the desktop placement geometry; dragging updates the same offsets. Center is available for images and videos and uses one source pixel per display backing pixel. Reset Placement previews the default Fill framing without changing the assignment, sound, or playback settings.

Changes remain a draft until **Apply** saves that display's existing library settings. **Discard Changes** reloads its saved configuration. Switching displays warns about a dirty draft; disconnection preserves the target identity and blocks Apply, and edits made elsewhere require reloading the saved settings. Display rotation and resolution changes resize the preview without redirecting the draft to another display.

Image previews use a bounded thumbnail; video and scene previews play independently and are muted. Scene previews run at 24 fps with the existing script review, approval fingerprint, execution toggle, and worker safeguards. Their smaller viewport can change screen-size-dependent script behavior, cursor parallax, and pixel-sized effects. Web projects retain their own responsive layout. Center is unavailable for scenes/web projects. Uncovered preview areas are black; macOS's underlying desktop may show through on screen. Preview playback pauses while its window is hidden or closed.

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

The native application is Swift; the scene runtime is bundled JavaScript/WebGL in WKWebView. Automatic quality first reduces expensive rendering work and video texture dimensions. If video uploads still exceed their frame budget at the smallest useful texture size, it lowers only the video texture upload rate; scene animation and scripts keep their configured frame rate. Video motion can look less smooth at that final step, and Diagnostics reports the active rate. This is broad scene compatibility, not a claim of complete fidelity with Wallpaper Engine. Some effects, scripts, video codecs, and models may differ or fail; Diagnostics shows renderer warnings. Application wallpapers cannot run on macOS. Local web projects cannot load arbitrary remote resources under the renderer's content policy. A standalone HTML import copies just that file; import a project folder to include its assets.

The native host sends scene playback and configuration commands only when their values change. Cursor polling runs only while an active scene can use it; paused playback and native video/image wallpapers leave that timer stopped.

Settings → **Scene media information** can share track metadata from **Music** or **Spotify** with approved scene scripts. This is off by default, uses a fixed read-only Apple Events query once per second, and requires macOS Automation permission and the standard local build. It supplies title, artist, album, album artist, track number, playback state, duration, and position. Other players, artwork, lyrics, player control, and system-audio capture are unavailable. Audio spectrum input is explicitly silent rather than simulated. SceneScript is disabled by default for imported projects; enable it in the wallpaper details only for projects you trust. The [SceneScript compatibility notes](research/SCENESCRIPT_COMPATIBILITY.md) describe the bridge, supported API families, and remaining renderer limits.

## Scene editor

The **Scene Editor** page creates, opens, duplicates, renames, imports, and exports scene projects. It keeps editor projects in Luma's managed `EditorProjects` folder, separate from the wallpaper library. Import makes a copy; export writes a copy. The editor rejects symbolic links and unsafe relative paths, preserves unknown scene JSON fields and unedited PKGV package entries, validates scene data before saving, and atomically replaces edited files. A project index changed outside the loaded editor blocks further index writes and Clear Data until Luma is reopened. Layer edits have up to 100 in-memory undo steps. Layer deletion asks for confirmation.

The preview is the existing `SceneHost` backed by the bundled WebWallGL `editorOf` API. It provides scene playback, seeking, frame stepping, playback speed, layer snapshots and hit testing. The layer panel supports selection, multi-selection, reorder, rename, visibility, lock, duplicate, and delete. The viewport supports pan, zoom, move, resize, rotate, 16-unit grid snapping, and center guides. Text layers can be added. Existing image, video, text, particle, model, and effect layers can be inspected and edited through their complete JSON, with structured controls for common text, font, size, opacity, and transform fields. Project assets can be copied into a project-local `assets` folder and previewed; source files are left alone. **Show project files** opens the managed copy in Finder for editing loose project files.

Preview status is read in one bounded snapshot. Clock samples update the timeline without rebuilding the asset/layer panels or seeking playback; only user scrubbing requests a seek. Playback can advance beyond the slider's 60-second display range.

The pinned renderer bundle does not document a general animation or keyframe file schema. Its `setAnimationLayers` editor method accepts model animation references, so Luma uses the verified scene clock for playback and scrubbing, and leaves keyframe authoring disabled instead of inventing a serialized format. Grouping and creating new image/video/particle/model/effect layers are unavailable because this bundled API does not provide verified payload templates. Existing layer data for these types remains editable through JSON. Color, anchor, material, effect, and layer-specific playback properties are available there. Scene resolution and renderer general settings use the scene JSON inspector; anti-aliasing, particle quality, and post-processing controls affect the preview, while output frame rate and Retina rendering follow Luma preferences. Audio-reactive data follows the existing playback runtime and is not synthesized by the editor.

SceneScript review remains read-only and separate from the run toggle. Inline script properties can be edited in the layer JSON inspector; loose script files can be edited from the project copy in Finder. Packed package script entries can be reviewed but cannot be edited directly in the review sheet. Any scene edit clears the project's approval, and enabling execution rechecks the reviewed fingerprint. The Scripts inspector shows diagnostics reported by WebWallGL. The editor preview never opts into script execution by itself.

## Native lock screen

### Experimental live scene overlay

The Lock Screen page has a separate opt-in live scene overlay. It dynamically resolves private SkyLight symbols, creates a space at the lock-screen notification level, assigns a non-interactive `NSWindow` to it, and reacts to lock, unlock, sleep, and wake notifications. It pauses SceneHost while unlocked/asleep and resumes it while locked. Disabling the option or a normal Luma shutdown closes the WebKit scene windows, hides the private space, and calls `SLSSpaceDestroy`. If the required symbols or calls fail, Luma disables the overlay and shows an error. A force quit or crash cannot run Luma's cleanup handler.

Space IDs retain their full 64-bit width. SkyLight's show/hide, set-level, attachment, and destroy mutators are called without interpreting undefined return registers as error codes. Luma verifies the level, window membership, and space removal using readback APIs; these checks do not prove macOS actually composites the scene while locked. A desktop-level window inside a private space can still cover authentication controls. Luma now keeps it transparent until WindowServer's global window list verifies that it is below the detected loginwindow/SecurityAgent windows. It requests that ordering and rechecks while locked; if authentication windows or their ordering cannot be verified, the scene stays hidden and paused and the UI recommends the static fallback. This can prevent the live overlay from appearing on some macOS versions. Session-state polling supplements lock/unlock notifications, and the Lock Screen page reports session, display, renderer readiness, and renderer warnings. `./Scripts/test-scenes.sh --live-lock-overlay` additionally checks a temporary space and transparent window against the current WindowServer without locking the Mac or changing wallpaper settings.

This is an unsupported experiment. [Atoll](https://github.com/Ebullioscopic/Atoll) and [SkyLightWindow's SkyLight operator](https://github.com/Lakr233/SkyLightWindow/blob/main/Sources/SkyLightWindow/SkyLightOperator.swift) demonstrate private-space windows for small lock-screen widgets; [its topmost window](https://github.com/Lakr233/SkyLightWindow/blob/main/Sources/SkyLightWindow/TopmostWindow.swift) sets `canBecomeVisibleWithoutLogin` and a very high window level. That does not establish that a continuously animated WKWebView/WebGL scene will keep rendering through every lock, sleep, display, and macOS transition. Apple can change the APIs, WebKit can be suspended, and the overlay may disappear or render a frozen frame. The toggle remains off by default. SceneScript still runs only when its existing review fingerprint and execution toggle both allow it.

**Static fallback:** **Prepare Static Fallback** saves a PNG under Luma's managed data. For a scene it tries source images first, then a representative video frame, then a captured renderer frame; a project preview is the last resort if rendering cannot start. The preview can be opened in System Settings → Wallpaper for manual selection. Apple's [custom-photo instructions](https://support.apple.com/guide/mac-help/choose-your-desktop-picture-mchlp3013/mac) describe setting the desktop picture, and its public [`NSWorkspace.setDesktopImageURL`](https://developer.apple.com/documentation/appkit/nsworkspace/setdesktopimageurl%28_%3Afor%3Aoptions%3A%29) API also targets the desktop. macOS provides no supported public API for setting a separate lock-screen-only photo, so Luma cannot apply this still to the lock screen without risking a desktop wallpaper change. Luma only prepares and previews the file; choosing it manually in System Settings may also change the desktop. If you selected the PNG there, choose another wallpaper before removing the file in Luma; Luma cannot track or restore that manual selection.

The older Aerial catalog workflow below is separate. It edits an undocumented Apple catalog and is not used by the live overlay or the PNG fallback.

1. Open **Lock Screen** and choose a video or scene.
2. Connect the user's `~/Library/Application Support/com.apple.wallpaper` folder through the macOS file picker (⇧⌘G can enter that path).
3. For a scene, choose **Render loop with fallback**, **Use scene video or image**, or **Capture a still frame**. Loop rendering uses the chosen duration at 1920×1080/30 fps; video input retains its source size and transform. Automatic mode falls back from loop rendering to usable scene media, then a captured scene still, then the project preview. Capture mode tries a still first. Source media is found in loose folders and PKGV packages, including decoded image/video textures. Unreadable media is skipped. Static fallbacks are packaged as constant-image native videos and remain visually still. The installed receipt shows the source used. These checks do not guarantee that every private macOS wallpaper schema will accept the installed asset. Ordinary images can also be installed.
4. Click **Install for Lock Screen**. Luma encodes HEVC Main10 with temporal layers and refuses to install the movie if `tscl`/`tsas` groups are absent.
5. In System Settings → Wallpaper, select the new **Luma** collection. Enable its screen saver option if desired. Optional automatic selection understands observed `Idle` and `Linked` store shapes and preserves other fields. Linked selections may also change the native desktop.

This uses Apple's undocumented Aerials catalog format. It can change across macOS releases. The installer preserves unknown catalog fields, writes app-owned records, stages media before publishing, checks for concurrent changes, and keeps catalog snapshots plus per-install ownership state in Luma's `NativeBackups` directory. That state records whether the catalog manifest existed before Luma and the exact bytes Luma installed. Cleanup follows the saved snapshots through consecutive installs before removing an originally absent manifest; edits by another writer between installs preserve the manifest. It also tracks empty catalog directories Luma created. It does not restart wallpaper services on launch or fight a user's later wallpaper choice. If macOS caches the old catalog, log out and back in. **Remove Luma Collection** removes owned assets and restores a selection backup only if the current store still matches Luma's previous write.

A rendered scene loop is a video: it cannot stay interactive, react to future music, or keep a live clock on the lock screen. Loop continuity depends on the scene. macOS controls motion at lock/unlock and during screen saver/idle/sleep; constant movement behind the password prompt is not guaranteed. FileVault preboot is separate.

## Wallper catalog

Static inspection of the local Wallper 1.12.1 app confirms its CDN roots and backend host, but does not establish the catalog search route, request schema, required headers, or response-signature protocol. Luma skips the Wallper catalog connection rather than sending guessed requests. The evidence and missing details are recorded in [WALLPER_CATALOG_PROTOCOL.md](research/WALLPER_CATALOG_PROTOCOL.md). Local imports and direct video URLs work independently.

## Validation

```sh
./Scripts/test.sh
./Scripts/test-scenes.sh
./Scripts/test-editor.sh
./Scripts/test-instance.sh
```

Focused checks use generated temporary media and do not modify the system wallpaper catalog. They cover path traversal/symlinks, Workshop IDs, overlapping pause holds, native catalog/selection preservation, import rollback, persistence, original-source preservation, and real HEVC temporal encoding. The scene integration check creates a PKGV0012 package, loads it in WebKit, checks rendered pixels, and exports a playable scene movie. Native lock/unlock, multiple physical displays, Steam account downloads, and arbitrary Workshop scene fidelity require testing in the user's environment.

The standalone test binaries compile for the app's macOS 14 minimum target and use isolated temporary directories. Core media and scene tests call AVFoundation encoders and WebKit/GPU services; run them on a normal macOS host with those system services available. A restricted process sandbox can prevent the H.264 encoder from being discovered (`AVFoundation -11834 Cannot Encode`) or deny WebKit/GPU service access. Such a run is an environment failure, not a passing test or evidence of an app regression; rerun with host media/graphics access and keep the reported phase/error when diagnosing it. CI runs these same scripts on the configured Xcode 27 macOS runner.

Xcode may also print `Metadata extraction skipped, no AppIntents.framework dependency found` during the Release build. Luma does not use AppIntents, so this metadata notice is expected and the build result is determined by `** BUILD SUCCEEDED **`.

The renderer is pinned and its licenses/source links are recorded in [Vendor/DEPENDENCIES.md](Vendor/DEPENDENCIES.md). Swift source is under `Luma/`.

The core regressions include corrupt or externally changed library ownership records, failed-save retry behavior, active-import cleanup refusal and cancellation, pending video pause/readiness/configuration, library-window selection, Clear Data path/symlink preflight, desktop-still receipts that point outside their managed folder, malformed or externally edited native receipts, native selection restoration, and consecutive native installs with intervening external catalog edits. Editor regressions cover failed index writes, corrupt or externally changed indexes, retrying Clear Data from a valid index after a missing or malformed project, accurate review counts, preservation of unindexed folders, changes made outside the editor, self-export rejection, invalid layer IDs, and history. The instance test races six child processes against the same temporary lock and checks that it is released after exit. The scene suite also exercises reviewed scripts, stale and disabled approvals, init-only scripts, syntax rejection, constructor capability checks, and infinite loops during source evaluation, init, and updates. These fixtures use temporary directories and do not modify the real system wallpaper catalog. Hidden AppKit pending-playback/window checks run when a host display is available; the core test reports a skip if none is present.

## Continuous integration

[Build and test](.github/workflows/ci.yml) runs on pushes to `main`, pull requests, and manual dispatch. Build and test jobs use GitHub's Apple Silicon `xcode-27` image with Xcode 27.1 selected explicitly, matching the local toolchain. See the [runner's installed Xcode versions](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md). The workflow builds the standard and sandboxed Release profiles, verifies and packages each locally signed app, uploads the ZIP and build logs, and runs the core, editor, instance, and WebKit scene suites in separate jobs. Source checks validate shell and workflow syntax. Action revisions are pinned to commits; [Dependabot](.github/dependabot.yml) proposes monthly GitHub Actions updates.

Artifacts are local development builds, without Developer ID signing or notarization. The HEVC and WebGL integration suites require the runner's media and graphics services; failures are reported in their uploaded logs. Lock/unlock, actual login-item registration, multiple physical displays, authenticated Steam downloads, and the private wallpaper APIs still require checks on a real Mac. The source review and fixes from October 20, 2026 are recorded in [REVIEW_2026-10-20.md](research/REVIEW_2026-10-20.md).

The October 21 audit and verification results are recorded in [REVIEW_2026-10-21.md](research/REVIEW_2026-10-21.md).

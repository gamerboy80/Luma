# Bundled scene renderer

- WebWallGL: https://github.com/oneincase/webwallgl
- Pinned commit: `197abe54266c31d346cebc314e49a26b70c960cc`
- License: MIT; included in Vendor/WebWallGL-LICENSE and the app's Resources.
- Mediabunny: 1.56.0, MPL-2.0, bundled transitively by the scene renderer. Its license is in Resources/Mediabunny-LICENSE.txt; corresponding source is available at https://github.com/Vanilagy/mediabunny/tree/v1.56.0. No Mediabunny source was modified.
- Generated bundle: `Luma/Resources/webwallgl.js`.
- Luma's SceneScript compatibility overlay is preserved in `Vendor/webwallgl-scenescript.patch` and applied to the pinned source by `Scripts/build-renderer.sh`. It wires lifecycle events and live layer/scene APIs, including runtime text creation, general settings, and dynamic parenting.

Luma bundles a tree-shaken IIFE built from `mount`, `httpSource`, `createMediaSource`, `editorOf`, `parseTex`, and `decodeMips`. Playback and frame export share one renderer instance. The renderer runs in a nonpersistent WKWebView with a separate resource handler for each wallpaper. Only that imported project, the bundled renderer, and the user-selected shared assets folder are exposed. SceneScript is disabled by default for imports. Imported web pages execute JavaScript and should come from a trusted source.

No Wallpaper Engine runtime assets or Workshop content are bundled. The two user-provided repositories were consulted as references, not copied: MotorcycleEnjoyer/wallpaper-engine-viewer browses video projects; redpfire/we documents its PKGV package extractor. Neither is the scene runtime.

## SceneScript runtime boundary

Wallpaper scripts run in a dedicated Worker with SES lockdown, separate from the WebGL render thread. The host sends bounded JSON snapshots and accepts validated layer patches and commands. Initialization, update, resize, cursor, user and general settings, media, animation, timer, and destruction events use this bridge. Worker updates are coalesced and skipped while the worker is busy; a main-thread watchdog terminates a stalled worker and disables scripts for that scene. Script approval remains tied to the wallpaper and reviewed script contents.

The bridge carries the `engine` clock (`runtime`, `frametime`, and `timeOfDay`), canvas and screen dimensions, cursor input, layer snapshots and writes, text, animation commands, audio-buffer snapshots, and bounded particle emission calls. `registerAsset` accepts only normalized relative paths within the wallpaper. Shortcut and media-control requests are validated and rate limited. Timers and bridge messages have fixed limits.

Some APIs still need renderer-specific data or live object handles and are unavailable through the bridge: bone transform queries and overrides, puppet attachment matrices, `createSceneModelData` / `destroySceneModelData`, particle-system enumeration and direct particle-system methods, and executable functions passed through `shared` between scripts. `getParticleSystems()` currently returns an empty list, while `emitParticles()` is bridged. `localStorage` currently uses a per-script in-memory store; wallpaper-wide and persistent storage are not bridged. Browser Workers do not expose a portable per-worker heap limit; source, snapshot, message, structure, command, timer, and event sizes are capped, and the watchdog can terminate excessive work.

## Rebuilding the renderer

Run `Scripts/build-renderer.sh` with Node.js and pnpm available. It downloads the pinned upstream source into a temporary directory, installs the pinned lockfile with lifecycle scripts disabled, and generates the checked-in bundle. Native Swift builds use the existing bundle and require no network or Node installation.

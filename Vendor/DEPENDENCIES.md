# Bundled scene renderer

- WebWallGL: https://github.com/oneincase/webwallgl
- Pinned commit: `197abe54266c31d346cebc314e49a26b70c960cc`
- License: MIT; included in Vendor/WebWallGL-LICENSE and the app's Resources.
- Mediabunny: 1.56.0, MPL-2.0, bundled transitively by the scene renderer. Its license is in Resources/Mediabunny-LICENSE.txt; corresponding source is available at https://github.com/Vanilagy/mediabunny/tree/v1.56.0. No Mediabunny source was modified.
- Generated bundle: `Luma/Resources/webwallgl.js`.
- Luma's SceneScript compatibility overlay is preserved in `Vendor/webwallgl-scenescript.patch` and applied to the pinned source by `Scripts/build-renderer.sh`. It wires lifecycle events, bridge-backed SceneScript, live layer/scene APIs, runtime text creation, general settings, and dynamic parenting.

Luma bundles a tree-shaken IIFE built from `mount`, `httpSource`, `createMediaSource`, `editorOf`, `parseTex`, and `decodeMips`. Playback and frame export share one renderer instance. The renderer runs in a nonpersistent WKWebView with a separate resource handler for each wallpaper. Only that imported project, the bundled renderer, and the user-selected shared assets folder are exposed. SceneScript is disabled by default for imports. Imported web pages execute JavaScript and should come from a trusted source.

No Wallpaper Engine runtime assets or Workshop content are bundled. The two user-provided repositories were consulted as references, not copied: MotorcycleEnjoyer/wallpaper-engine-viewer browses video projects; redpfire/we documents its PKGV package extractor. Neither is the scene runtime.

## SceneScript runtime boundary

Wallpaper scripts run in SES compartments inside a dedicated Worker, separate from the WebGL render thread. The host sends bounded snapshots and accepts validated layer patches and typed commands. All lifecycle, update, resize, cursor, user/general settings, media, animation, timer, and destroy events use this bridge. At most one event runs at a time; updates are coalesced/skipped while busy. The host watchdog terminates a stalled Worker, discards its work/timers, and disables scripts for that scene. Review and the separate execution toggle are both required; approval is tied to the wallpaper and reviewed source fingerprint.

Scene snapshots preserve renderer-relevant fields and are bounded by count, nesting, nodes, and bytes. Result validation checks generation, layer identity, field allowlists, types, finite values/ranges, normalized project-relative asset paths, command/payload limits, and action rates. Worker scripts do not receive DOM, filesystem, native app bridges, arbitrary network, or ambient Worker timers/messages. `Date` and engine time values use an advancing host timestamp sampled per event. Vectors and matrices retain their methods inside SES, and mutable layer vector components write through validated scene mutations.

Particle state includes bounded live-system counts and up to eight decoded control points; supported instance numeric/color/control-point fields and bounded emission reach the current particle backend. There are deliberate limitations: dynamic model geometry, bone transforms/physics, attachment matrices, some animation/material callbacks, decoder completion callbacks, and artwork/lyrics are unavailable and report diagnostics. Missing effects, material passes, animations, media decoders, and particle systems do not return fake success-shaped handles. Missing media providers report unavailable data instead of guessed track fields. For the full per-declaration status and limits, see [`research/SCENESCRIPT_API_COVERAGE.md`](../research/SCENESCRIPT_API_COVERAGE.md) and [`research/SCENESCRIPT_COMPATIBILITY.md`](../research/SCENESCRIPT_COMPATIBILITY.md).

`shared` functions remain inside the Worker; only bounded serializable values cross the host bridge. `localStorage` is typed and limited to 100 KiB / 256 keys in scene memory, with no persistence after scene teardown. Browser Workers have no portable hard heap limit. Timers, source, snapshots, messages, structure, commands, storage, event queues, and per-frame work are capped; the host watchdog handles hangs.

## Rebuilding the renderer

Run `Scripts/build-renderer.sh` with Node.js and pnpm available. It downloads the pinned upstream source into a temporary directory, installs the pinned lockfile with lifecycle scripts disabled, applies the checked-in compatibility patch, and generates the checked-in bundle. Native Swift builds use the existing bundle and require no network or Node installation.

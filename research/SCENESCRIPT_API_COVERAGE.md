# SceneScript API coverage matrix

Source: [official reference](https://docs.wallpaperengine.io/en/scene/scenescript/reference.html) and [official version 2.8 declarations](https://docs.wallpaperengine.io/reference/lib.sceneScript.d.ts), retrieved 2026-10-20.

Pinned declaration: SCENESCRIPT_API_TYPES.d.ts. SHA-256: `d9ccc5cd1383bbb91c8a589a34874833d13798d163f2b427117023ea2bfac3f4`. All declarations, declared members, overloads, modules and globals have an individual row. Interface rows include inherited surfaces; `ILayer` combines those interfaces. Website-only aliases are listed at the end. Constructors are listed once with their declared union/optional arguments. The upstream file refers to undeclared `IModel`, `IAssetHandle` and `Any`; Luma does not invent an extra public API for those unresolved type names.

510 entries: 431 implemented, 60 unsupported, 19 external provider.

**Implemented** means the stated Luma scope, with the limits in each row; it is not a claim of full Wallpaper Engine fidelity. **External provider** means the type/event bridge exists but live data requires the named provider. **Unsupported** produces an error/diagnostic on use; no success-shaped dummy object is supplied. Event/data classes describe callback payloads, not ambient native constructors. See [compatibility and safeguards](SCENESCRIPT_COMPATIBILITY.md) for exact resource limits and verification scope.

## Code paths

- **Pure**: `text.js` / `scene-script-matrices.js`, inside SES; no host action.
- **Layer**: `scene-script-runtime.ts.snapshotLayer` → `scene-script-worker.ts.updateLayers` → `text.js` facade → layer patches → `applyPatches` / `applyStructuredChanges` → renderer.
- **Command**: worker command → generation/ID/type/range/path/size/rate checks in `applyCommands` → host renderer controller. Commands are asynchronous; mutations become visible on a later frame.
- **Event**: renderer/native provider → bounded worker event → compartment argument revival → callbacks → validated result/patches.
- **Storage/shared**: Worker-owned data; serialized shared data only crosses to the host. Functions never cross to the native app.

## IComponent

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IComponent` | implemented | Event: serialized and dispatched in the Worker with a host watchdog; callback values/patches are validated. |
| `IComponent.init` | implemented | Event: serialized and dispatched in the Worker with a host watchdog; callback values/patches are validated. |
| `IComponent.update` | implemented | Event: serialized and dispatched in the Worker with a host watchdog; callback values/patches are validated. |
| `IComponent.destroy` | implemented | Event: serialized and dispatched in the Worker with a host watchdog; callback values/patches are validated. |
| `IComponent.resizeScreen` | implemented | Event: serialized and dispatched in the Worker with a host watchdog; callback values/patches are validated. |
| `IComponent.applyUserProperties` | implemented | Event: serialized and dispatched in the Worker with a host watchdog; callback values/patches are validated. |
| `IComponent.applyGeneralSettings` | implemented | Event: serialized and dispatched in the Worker with a host watchdog; callback values/patches are validated. |
| `IComponent.cursorEnter` | implemented | Event: serialized and dispatched in the Worker with a host watchdog; callback values/patches are validated. Native desktop host supplies movement; global clicks through other applications are unavailable. |
| `IComponent.cursorLeave` | implemented | Event: serialized and dispatched in the Worker with a host watchdog; callback values/patches are validated. Native desktop host supplies movement; global clicks through other applications are unavailable. |
| `IComponent.cursorMove` | implemented | Event: serialized and dispatched in the Worker with a host watchdog; callback values/patches are validated. Native desktop host supplies movement; global clicks through other applications are unavailable. |
| `IComponent.cursorDown` | implemented | Event: serialized and dispatched in the Worker with a host watchdog; callback values/patches are validated. Native desktop host supplies movement; global clicks through other applications are unavailable. |
| `IComponent.cursorUp` | implemented | Event: serialized and dispatched in the Worker with a host watchdog; callback values/patches are validated. Native desktop host supplies movement; global clicks through other applications are unavailable. |
| `IComponent.cursorClick` | implemented | Event: serialized and dispatched in the Worker with a host watchdog; callback values/patches are validated. Native desktop host supplies movement; global clicks through other applications are unavailable. |
| `IComponent.mediaStatusChanged` | external provider | Event: real selected Music/Spotify source and a current track required; no generic macOS Now Playing source. No fabricated track data. |
| `IComponent.mediaPlaybackChanged` | external provider | Event: real selected Music/Spotify source and a current track required; no generic macOS Now Playing source. No fabricated track data. |
| `IComponent.mediaPropertiesChanged` | external provider | Event: real selected Music/Spotify source and a current track required; no generic macOS Now Playing source. No fabricated track data. |
| `IComponent.mediaThumbnailChanged` | external provider | Event: real selected Music/Spotify source and a current track required; no generic macOS Now Playing source. No fabricated track data. |
| `IComponent.mediaTimelineChanged` | external provider | Event: real selected Music/Spotify source and a current track required; no generic macOS Now Playing source. No fabricated track data. |
## Vec2

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `Vec2` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.x` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.y` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.constructor` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.length` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.lengthSqr` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.distance` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.distanceSqr` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.normalize` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.copy` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.equals` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.isFinite` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.negate` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.add` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.subtract` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.multiply` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.divide` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.dot` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.reflect` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.perpendicular` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.project` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.angle` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.angleBetween` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.rotate` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.mix` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.min` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.max` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.clamp` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.abs` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.sign` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.round` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.floor` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.ceil` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.fract` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.mod` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.step` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.smoothStep` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec2.toString` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
## Vec3

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `Vec3` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.x` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.y` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.z` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.constructor` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.fromSpherical` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.length` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.lengthSqr` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.distance` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.distanceSqr` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.normalize` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.copy` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.equals` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.isFinite` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.negate` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.add` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.subtract` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.multiply` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.divide` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.cross` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.dot` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.reflect` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.refract` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.project` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.angleBetween` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.toSpherical` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.mix` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.min` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.max` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.clamp` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.abs` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.sign` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.round` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.floor` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.ceil` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.fract` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.mod` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.step` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.smoothStep` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec3.toString` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
## Mat4

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `Mat4` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.m` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.constructor` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.identity` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.fromTranslation` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.fromScale` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.fromRotation` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.fromEuler` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.fromBasis` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.lookAt` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.compose` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.translation` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.right` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.up` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.forward` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.add` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.subtract` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.multiply` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.translate` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.rotate` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.scale` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.transformPoint` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.transformDirection` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.transpose` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.inverse` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.determinant` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.extractEuler` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.normalMatrix` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.decompose` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.copy` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.equals` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat4.toString` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
## Mat3

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `Mat3` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.m` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.constructor` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.identity` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.fromTranslation` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.fromScale` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.fromRotation` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.fromBasis` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.fromMat4` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.compose` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.translation` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.angle` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.add` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.subtract` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.multiply` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.translate` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.rotate` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.scale` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.transformPoint` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.transformDirection` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.transpose` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.determinant` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.inverse` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.decompose` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.copy` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.equals` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Mat3.toString` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
## Vec4

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `Vec4` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.x` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.y` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.z` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.w` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.constructor` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.length` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.lengthSqr` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.distance` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.distanceSqr` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.normalize` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.copy` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.equals` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.isFinite` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.negate` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.add` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.subtract` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.multiply` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.divide` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.dot` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.reflect` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.project` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.mix` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.min` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.max` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.clamp` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.abs` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.sign` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.round` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.floor` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.ceil` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.fract` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.mod` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.step` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.smoothStep` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `Vec4.toString` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
## CameraTransforms

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `CameraTransforms` | implemented | Layer: Vec3 eye/center and zoom read/write through bounded camera snapshots; renderer applies host-timestamped camera override. |
| `CameraTransforms.eye` | implemented | Layer: Vec3 eye/center and zoom read/write through bounded camera snapshots; renderer applies host-timestamped camera override. |
| `CameraTransforms.center` | implemented | Layer: Vec3 eye/center and zoom read/write through bounded camera snapshots; renderer applies host-timestamped camera override. |
| `CameraTransforms.up` | unsupported | Renderer uses a fixed camera up vector; arbitrary camera up orientation is unavailable. |
| `CameraTransforms.zoom` | implemented | Layer: Vec3 eye/center and zoom read/write through bounded camera snapshots; renderer applies host-timestamped camera override. |
## AnimationEvent

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `AnimationEvent` | implemented | Event: bounded callback payload; cursor world/local positions revived as Vec3, animation name/frame preserved. |
| `AnimationEvent.name` | implemented | Event: bounded callback payload; cursor world/local positions revived as Vec3, animation name/frame preserved. |
| `AnimationEvent.frame` | implemented | Event: bounded callback payload; cursor world/local positions revived as Vec3, animation name/frame preserved. |
## CursorEvent

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `CursorEvent` | implemented | Event: bounded callback payload; cursor world/local positions revived as Vec3, animation name/frame preserved. |
| `CursorEvent.worldPosition` | implemented | Event: bounded callback payload; cursor world/local positions revived as Vec3, animation name/frame preserved. |
| `CursorEvent.localPosition` | implemented | Event: bounded callback payload; cursor world/local positions revived as Vec3, animation name/frame preserved. |
| `CursorEvent.hitBox` | unsupported | Renderer hit testing does not supply named model hit boxes; field remains absent. |
## MediaPropertiesEvent

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `MediaPropertiesEvent` | external provider | Event: real selected Music/Spotify metadata; strings/numbers bounded; playback constants available independently. |
| `MediaPropertiesEvent.title` | external provider | Event: real selected Music/Spotify metadata; strings/numbers bounded; playback constants available independently. |
| `MediaPropertiesEvent.artist` | external provider | Event: real selected Music/Spotify metadata; strings/numbers bounded; playback constants available independently. |
| `MediaPropertiesEvent.subTitle` | unsupported | Fixed native metadata query does not provide this field; absent/empty with provider limitation diagnostic. |
| `MediaPropertiesEvent.albumTitle` | external provider | Event: real selected Music/Spotify metadata; strings/numbers bounded; playback constants available independently. |
| `MediaPropertiesEvent.albumArtist` | external provider | Event: real selected Music/Spotify metadata; strings/numbers bounded; playback constants available independently. |
| `MediaPropertiesEvent.genres` | unsupported | Fixed native metadata query does not provide this field; absent/empty with provider limitation diagnostic. |
| `MediaPropertiesEvent.contentType` | unsupported | Fixed native metadata query does not provide this field; absent/empty with provider limitation diagnostic. |
## MediaThumbnailEvent

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `MediaThumbnailEvent` | external provider | Event: real selected Music/Spotify metadata; strings/numbers bounded; playback constants available independently. |
| `MediaThumbnailEvent.hasThumbnail` | external provider | Event: real selected Music/Spotify metadata; strings/numbers bounded; playback constants available independently. |
| `MediaThumbnailEvent.primaryColor` | unsupported | Music/Spotify provider does not retrieve artwork or derive artwork colors. No colors should be treated as album-derived; diagnostic states unavailable. |
| `MediaThumbnailEvent.secondaryColor` | unsupported | Music/Spotify provider does not retrieve artwork or derive artwork colors. No colors should be treated as album-derived; diagnostic states unavailable. |
| `MediaThumbnailEvent.tertiaryColor` | unsupported | Music/Spotify provider does not retrieve artwork or derive artwork colors. No colors should be treated as album-derived; diagnostic states unavailable. |
| `MediaThumbnailEvent.textColor` | unsupported | Music/Spotify provider does not retrieve artwork or derive artwork colors. No colors should be treated as album-derived; diagnostic states unavailable. |
| `MediaThumbnailEvent.highContrastColor` | unsupported | Music/Spotify provider does not retrieve artwork or derive artwork colors. No colors should be treated as album-derived; diagnostic states unavailable. |
## MediaPlaybackEvent

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `MediaPlaybackEvent` | external provider | Event: real selected Music/Spotify metadata; strings/numbers bounded; playback constants available independently. |
| `MediaPlaybackEvent.state` | external provider | Event: real selected Music/Spotify metadata; strings/numbers bounded; playback constants available independently. |
| `MediaPlaybackEvent.PLAYBACK_STOPPED` | implemented | Pure: frozen numeric playback-state enum (0 stopped, 1 playing, 2 paused). |
| `MediaPlaybackEvent.PLAYBACK_PLAYING` | implemented | Pure: frozen numeric playback-state enum (0 stopped, 1 playing, 2 paused). |
| `MediaPlaybackEvent.PLAYBACK_PAUSED` | implemented | Pure: frozen numeric playback-state enum (0 stopped, 1 playing, 2 paused). |
## MediaTimelineEvent

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `MediaTimelineEvent` | external provider | Event: real selected Music/Spotify metadata; strings/numbers bounded; playback constants available independently. |
| `MediaTimelineEvent.position` | external provider | Event: real selected Music/Spotify metadata; strings/numbers bounded; playback constants available independently. |
| `MediaTimelineEvent.duration` | external provider | Event: real selected Music/Spotify metadata; strings/numbers bounded; playback constants available independently. |
## MediaStatusEvent

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `MediaStatusEvent` | external provider | Event: real selected Music/Spotify metadata; strings/numbers bounded; playback constants available independently. |
| `MediaStatusEvent.enabled` | external provider | Event: real selected Music/Spotify metadata; strings/numbers bounded; playback constants available independently. |
## WEMath

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `WEMath` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `WEMath.smoothStep` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `WEMath.mix` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `WEMath.deg2rad` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `WEMath.rad2deg` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
## WEVector

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `WEVector` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `WEVector.angleVector2` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `WEVector.vectorAngle2` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
## WEColor

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `WEColor` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `WEColor.rgb2hsv` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `WEColor.hsv2rgb` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `WEColor.normalizeColor` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
| `WEColor.expandColor` | implemented | Pure: compartment math; vectors retain methods. Matrix Euler/decomposition limits apply for shear/reflection/degenerate inputs. |
## AudioBuffers

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `AudioBuffers` | implemented | Bounded, stable Float32Array channels at 16/32/64 samples update from Luma’s active audio source: optional live system capture, wallpaper audio, deterministic fallback, or silence when audio is disabled. The bridge does not invent song metadata. |
| `AudioBuffers.left` | implemented | Bounded, stable Float32Array channels at 16/32/64 samples update from Luma’s active audio source: optional live system capture, wallpaper audio, deterministic fallback, or silence when audio is disabled. The bridge does not invent song metadata. |
| `AudioBuffers.right` | implemented | Bounded, stable Float32Array channels at 16/32/64 samples update from Luma’s active audio source: optional live system capture, wallpaper audio, deterministic fallback, or silence when audio is disabled. The bridge does not invent song metadata. |
| `AudioBuffers.average` | implemented | Bounded, stable Float32Array channels at 16/32/64 samples update from Luma’s active audio source: optional live system capture, wallpaper audio, deterministic fallback, or silence when audio is disabled. The bridge does not invent song metadata. |
## IObject

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IObject` | implemented | Layer/command: bound property or existing named layer animation. Missing controllers report unavailable. Effect/material/nested clip animations are unsupported. |
| `IObject.getAnimation` | implemented | Layer/command: bound property or existing named layer animation. Missing controllers report unavailable. Effect/material/nested clip animations are unsupported. |
## IThisPropertyObjectBase

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IThisPropertyObjectBase` | implemented | Layer/command: bound property or existing named layer animation. Missing controllers report unavailable. Effect/material/nested clip animations are unsupported. |
## IMaterial

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IMaterial` | implemented | Layer: existing numeric shader constants through validated material passes; scalar/Vec2/Vec3/Vec4 assignments and component write-back. Unknown constants rejected. Inherited getAnimation is unsupported. |
## IEffect

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IEffect` | implemented | Layer: decoded effect visibility/name and existing material-pass constants; no dummy material bags. |
| `IEffect.getMaterial` | implemented | Layer: decoded effect visibility/name and existing material-pass constants; no dummy material bags. |
| `IEffect.getMaterialCount` | implemented | Layer: decoded effect visibility/name and existing material-pass constants; no dummy material bags. |
| `IEffect.setMaterialProperty` | implemented | Layer: decoded effect visibility/name and existing material-pass constants; no dummy material bags. |
| `IEffect.executeMaterialFunction` | unsupported | Renderer exposes no safe custom material render-function dispatcher. Explicit unavailable error. |
| `IEffect.visible` | implemented | Layer: decoded effect visibility/name and existing material-pass constants; no dummy material bags. |
| `IEffect.name` | implemented | Layer: decoded effect visibility/name and existing material-pass constants; no dummy material bags. |
## ITextureAnimation

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `ITextureAnimation` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `ITextureAnimation.frameCount` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `ITextureAnimation.duration` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `ITextureAnimation.rate` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `ITextureAnimation.play` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `ITextureAnimation.pause` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `ITextureAnimation.stop` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `ITextureAnimation.isPlaying` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `ITextureAnimation.getFrame` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `ITextureAnimation.setFrame` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `ITextureAnimation.join` | unsupported | Synchronous blocking until animation completion is incompatible with bounded worker event execution. Use state/events. |
## IVideoTexture

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IVideoTexture` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IVideoTexture.duration` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IVideoTexture.rate` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IVideoTexture.loop` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IVideoTexture.play` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IVideoTexture.pause` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IVideoTexture.stop` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IVideoTexture.isPlaying` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IVideoTexture.getCurrentTime` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IVideoTexture.setCurrentTime` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IVideoTexture.addEndedCallback` | unsupported | Renderer decoder/clip completion callbacks are not transported as Worker events. Explicit unavailable error. |
## IAnimationLayer

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IAnimationLayer` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimationLayer.fps` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimationLayer.frameCount` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimationLayer.duration` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimationLayer.name` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. Reads supported; clip identity renaming is unavailable. |
| `IAnimationLayer.rate` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimationLayer.blend` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimationLayer.visible` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimationLayer.play` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimationLayer.pause` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimationLayer.stop` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimationLayer.isPlaying` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimationLayer.getFrame` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimationLayer.setFrame` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimationLayer.addEndedCallback` | unsupported | Renderer decoder/clip completion callbacks are not transported as Worker events. Explicit unavailable error. |
## ISoundLayer

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `ISoundLayer` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `ISoundLayer.isPlaying` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `ISoundLayer.play` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `ISoundLayer.stop` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `ISoundLayer.pause` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `ISoundLayer.volume` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
## IEffectLayer

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IEffectLayer` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `IEffectLayer.getEffect` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `IEffectLayer.getEffectCount` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `IEffectLayer.transformAttachmentToTexture` | unsupported | Model bone matrices, blend shapes, named attachments and physics are not serialized by current backend/bridge. Explicit unavailable error. |
| `IEffectLayer.size` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `IEffectLayer.perspective` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `IEffectLayer.solid` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
## ITextLayer

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `ITextLayer` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ITextLayer.text` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ITextLayer.color` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ITextLayer.alpha` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ITextLayer.opaquebackground` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ITextLayer.backgroundcolor` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ITextLayer.pointsize` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ITextLayer.font` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ITextLayer.padding` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ITextLayer.horizontalalign` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ITextLayer.verticalalign` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ITextLayer.anchor` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ITextLayer.limitrows` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ITextLayer.maxrows` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ITextLayer.limitwidth` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ITextLayer.maxwidth` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
## IParticleSystemInstance

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IParticleSystemInstance` | implemented | Per-layer shared state and live typed properties; bounded host commands apply scalar multipliers, normalized color, and existing control points. Renderer/backend limits are recorded per member. |
| `IParticleSystemInstance.alpha` | implemented | Command: bounded numeric multipliers to renderer particle overrides, state shared per layer across scripts. |
| `IParticleSystemInstance.size` | implemented | Command: bounded numeric multipliers to renderer particle overrides, state shared per layer across scripts. |
| `IParticleSystemInstance.count` | implemented | Command: bounded numeric multipliers to renderer particle overrides, state shared per layer across scripts. |
| `IParticleSystemInstance.speed` | implemented | Command: bounded numeric multipliers to renderer particle overrides, state shared per layer across scripts. |
| `IParticleSystemInstance.lifetime` | implemented | Command: bounded numeric multipliers to renderer particle overrides, state shared per layer across scripts. |
| `IParticleSystemInstance.rate` | implemented | Command: bounded numeric multipliers to renderer particle overrides, state shared per layer across scripts. |
| `IParticleSystemInstance.colorn` | implemented | Finite normalized scalar 0..1 or Vec3 color writes reach the particle backend; host validates range, layer identity and rate. Renderer currently applies the value to new particles. |
| `IParticleSystemInstance.controlpoint0` | implemented | Vec3 snapshots and component write-back for existing control points 0..7; host limits coordinates and verifies the live particle layer/backend. Missing points are diagnosed. |
| `IParticleSystemInstance.controlpoint1` | implemented | Vec3 snapshots and component write-back for existing control points 0..7; host limits coordinates and verifies the live particle layer/backend. Missing points are diagnosed. |
| `IParticleSystemInstance.controlpoint2` | implemented | Vec3 snapshots and component write-back for existing control points 0..7; host limits coordinates and verifies the live particle layer/backend. Missing points are diagnosed. |
| `IParticleSystemInstance.controlpoint3` | implemented | Vec3 snapshots and component write-back for existing control points 0..7; host limits coordinates and verifies the live particle layer/backend. Missing points are diagnosed. |
| `IParticleSystemInstance.controlpoint4` | implemented | Vec3 snapshots and component write-back for existing control points 0..7; host limits coordinates and verifies the live particle layer/backend. Missing points are diagnosed. |
| `IParticleSystemInstance.controlpoint5` | implemented | Vec3 snapshots and component write-back for existing control points 0..7; host limits coordinates and verifies the live particle layer/backend. Missing points are diagnosed. |
| `IParticleSystemInstance.controlpoint6` | implemented | Vec3 snapshots and component write-back for existing control points 0..7; host limits coordinates and verifies the live particle layer/backend. Missing points are diagnosed. |
| `IParticleSystemInstance.controlpoint7` | implemented | Vec3 snapshots and component write-back for existing control points 0..7; host limits coordinates and verifies the live particle layer/backend. Missing points are diagnosed. |
## IParticleSystem

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IParticleSystem` | implemented | Layer/command: emission pause/resume, pool-clearing stop, bounded burst emission and numeric instance multipliers; decoded particle layer required. |
| `IParticleSystem.play` | implemented | Layer/command: emission pause/resume, pool-clearing stop, bounded burst emission and numeric instance multipliers; decoded particle layer required. |
| `IParticleSystem.pause` | implemented | Layer/command: emission pause/resume, pool-clearing stop, bounded burst emission and numeric instance multipliers; decoded particle layer required. |
| `IParticleSystem.stop` | implemented | Layer/command: emission pause/resume, pool-clearing stop, bounded burst emission and numeric instance multipliers; decoded particle layer required. |
| `IParticleSystem.isPlaying` | implemented | Layer/command: emission pause/resume, pool-clearing stop, bounded burst emission and numeric instance multipliers; decoded particle layer required. |
| `IParticleSystem.emitParticles` | implemented | Layer/command: emission pause/resume, pool-clearing stop, bounded burst emission and numeric instance multipliers; decoded particle layer required. |
| `IParticleSystem.instance` | implemented | Layer/command: emission pause/resume, pool-clearing stop, bounded burst emission and numeric instance multipliers; decoded particle layer required. |
## IImageLayer

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IImageLayer` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `IImageLayer.alpha` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `IImageLayer.color` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `IImageLayer.alignment` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `IImageLayer.getTextureAnimation` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `IImageLayer.getVideoTexture` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `IImageLayer.getAnimationLayerCount` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `IImageLayer.getAnimationLayer` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `IImageLayer.createAnimationLayer` | unsupported | Dynamic clip definitions/lifecycle are not transported/validated by current model bridge. Existing clips can be controlled; explicit unavailable error. |
| `IImageLayer.playSingleAnimation` | unsupported | Dynamic clip definitions/lifecycle are not transported/validated by current model bridge. Existing clips can be controlled; explicit unavailable error. |
| `IImageLayer.destroyAnimationLayer` | unsupported | Dynamic clip definitions/lifecycle are not transported/validated by current model bridge. Existing clips can be controlled; explicit unavailable error. |
| `IImageLayer.getBoneCount` | unsupported | Model bone matrices, blend shapes, named attachments and physics are not serialized by current backend/bridge. Explicit unavailable error. |
| `IImageLayer.getBoneTransform` | unsupported | The official Mat4 contract is unsupported and diagnosed. WebWallGL has an older translation-only puppet path; it is not exposed as a Mat4. |
| `IImageLayer.setBoneTransform` | unsupported | Model bone matrices, blend shapes, named attachments and physics are not serialized by current backend/bridge. Explicit unavailable error. |
| `IImageLayer.getLocalBoneTransform` | unsupported | Model bone matrices, blend shapes, named attachments and physics are not serialized by current backend/bridge. Explicit unavailable error. |
| `IImageLayer.setLocalBoneTransform` | unsupported | Model bone matrices, blend shapes, named attachments and physics are not serialized by current backend/bridge. Explicit unavailable error. |
| `IImageLayer.getLocalBoneAngles` | unsupported | Model bone matrices, blend shapes, named attachments and physics are not serialized by current backend/bridge. Explicit unavailable error. |
| `IImageLayer.setLocalBoneAngles` | unsupported | Model bone matrices, blend shapes, named attachments and physics are not serialized by current backend/bridge. Explicit unavailable error. |
| `IImageLayer.getLocalBoneOrigin` | unsupported | Model bone matrices, blend shapes, named attachments and physics are not serialized by current backend/bridge. Explicit unavailable error. |
| `IImageLayer.setLocalBoneOrigin` | unsupported | Model bone matrices, blend shapes, named attachments and physics are not serialized by current backend/bridge. Explicit unavailable error. |
| `IImageLayer.getBoneIndex` | unsupported | Model bone matrices, blend shapes, named attachments and physics are not serialized by current backend/bridge. Explicit unavailable error. |
| `IImageLayer.getBoneParentIndex` | unsupported | Model bone matrices, blend shapes, named attachments and physics are not serialized by current backend/bridge. Explicit unavailable error. |
| `IImageLayer.applyBonePhysicsImpulse` | unsupported | Model bone matrices, blend shapes, named attachments and physics are not serialized by current backend/bridge. Explicit unavailable error. |
| `IImageLayer.resetBonePhysicsSimulation` | unsupported | Model bone matrices, blend shapes, named attachments and physics are not serialized by current backend/bridge. Explicit unavailable error. |
| `IImageLayer.getBlendShapeIndex` | unsupported | Model bone matrices, blend shapes, named attachments and physics are not serialized by current backend/bridge. Explicit unavailable error. |
| `IImageLayer.getBlendShapeWeight` | unsupported | Model bone matrices, blend shapes, named attachments and physics are not serialized by current backend/bridge. Explicit unavailable error. |
| `IImageLayer.setBlendShapeWeight` | unsupported | Model bone matrices, blend shapes, named attachments and physics are not serialized by current backend/bridge. Explicit unavailable error. |
## IModelLayer

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IModelLayer` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `IModelLayer.perspective` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `IModelLayer.rootmotion` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `IModelLayer.getAnimationLayerCount` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `IModelLayer.getAnimationLayer` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `IModelLayer.createAnimationLayer` | unsupported | Dynamic clip definitions/lifecycle are not transported/validated by current model bridge. Existing clips can be controlled; explicit unavailable error. |
| `IModelLayer.playSingleAnimation` | unsupported | Dynamic clip definitions/lifecycle are not transported/validated by current model bridge. Existing clips can be controlled; explicit unavailable error. |
| `IModelLayer.destroyAnimationLayer` | unsupported | Dynamic clip definitions/lifecycle are not transported/validated by current model bridge. Existing clips can be controlled; explicit unavailable error. |
## ICamera

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `ICamera` | unsupported | Per-layer camera projection is not bridged; use supported scene settings/camera transforms where applicable. |
| `ICamera.fov` | unsupported | Per-layer camera projection is not bridged; use supported scene settings/camera transforms where applicable. |
| `ICamera.zoom` | unsupported | Per-layer camera projection is not bridged; use supported scene settings/camera transforms where applicable. |
## IModelData

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IModelData` | unsupported | No dynamic geometry buffer or render-context capabilities cross the Worker boundary. Explicit diagnostic; no host/native context. |
| `IModelData.applyData` | unsupported | No dynamic geometry buffer or render-context capabilities cross the Worker boundary. Explicit diagnostic; no host/native context. |
| `IModelData.replaceData` | unsupported | No dynamic geometry buffer or render-context capabilities cross the Worker boundary. Explicit diagnostic; no host/native context. |
| `IModelData.POSITION` | unsupported | No dynamic geometry buffer or render-context capabilities cross the Worker boundary. Explicit diagnostic; no host/native context. |
| `IModelData.NORMAL` | unsupported | No dynamic geometry buffer or render-context capabilities cross the Worker boundary. Explicit diagnostic; no host/native context. |
| `IModelData.TANGENT_SIGNED` | unsupported | No dynamic geometry buffer or render-context capabilities cross the Worker boundary. Explicit diagnostic; no host/native context. |
| `IModelData.UV` | unsupported | No dynamic geometry buffer or render-context capabilities cross the Worker boundary. Explicit diagnostic; no host/native context. |
| `IModelData.COLOR` | unsupported | No dynamic geometry buffer or render-context capabilities cross the Worker boundary. Explicit diagnostic; no host/native context. |
## ILayer

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `ILayer` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ILayer.origin` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ILayer.angles` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ILayer.scale` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ILayer.parallaxDepth` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ILayer.name` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ILayer.visible` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ILayer.getTransformMatrix` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ILayer.rotateObjectSpace` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ILayer.lookAt` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ILayer.lookAtYaw` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ILayer.setParent` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ILayer.setParent.overload2` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ILayer.getParent` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ILayer.getChildren` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `ILayer.getAttachmentIndex` | unsupported | Model bone matrices, blend shapes, named attachments and physics are not serialized by current backend/bridge. Explicit unavailable error. |
| `ILayer.getAttachmentMatrix` | unsupported | Model bone matrices, blend shapes, named attachments and physics are not serialized by current backend/bridge. Explicit unavailable error. |
| `ILayer.getAttachmentOrigin` | unsupported | Model bone matrices, blend shapes, named attachments and physics are not serialized by current backend/bridge. Explicit unavailable error. |
| `ILayer.getAttachmentAngles` | unsupported | Model bone matrices, blend shapes, named attachments and physics are not serialized by current backend/bridge. Explicit unavailable error. |
## global

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `global.thisLayer` | implemented | Compartment-owned API facade; Worker snapshots/commands only, no ambient native/DOM/network capabilities. |
## IScene

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IScene` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.getLayer` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.getLayerByID` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.getLayerCount` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.enumerateLayers` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.destroyLayer` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.createLayer` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.sortLayer` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.getLayerIndex` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.getInitialLayerConfig` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.getCameraTransforms` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.setCameraTransforms` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.getAnimation` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.createModelData` | unsupported | Dynamic model vertex/index buffers are not bridged to renderer. Explicit unavailable error. |
| `IScene.destroyModelData` | unsupported | Dynamic model vertex/index buffers are not bridged to renderer. Explicit unavailable error. |
| `IScene.bloom` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.bloomstrength` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.bloomthreshold` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.clearenabled` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.clearcolor` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.ambientcolor` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.skylightcolor` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.fov` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.nearz` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.farz` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.camerafade` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.camerashake` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.camerashakespeed` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.camerashakeamplitude` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.camerashakeroughness` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.cameraparallax` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.cameraparallaxamount` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.cameraparallaxdelay` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
| `IScene.cameraparallaxmouseinfluence` | implemented | Layer/command: live scene settings, validated layer identity/hierarchy/order and supported renderer factory definitions; creation asynchronous, factory failures diagnosed. |
## global

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `global.thisScene` | implemented | Compartment-owned API facade; Worker snapshots/commands only, no ambient native/DOM/network capabilities. |
## IConsole

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IConsole` | implemented | Command: bounded diagnostics, 5 log messages/second; max 1600 characters/message, no host console or native handle. |
| `IConsole.log` | implemented | Command: bounded diagnostics, 5 log messages/second; max 1600 characters/message, no host console or native handle. |
| `IConsole.error` | implemented | Command: bounded diagnostics, 5 log messages/second; max 1600 characters/message, no host console or native handle. |
## global

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `global.console` | implemented | Command: bounded diagnostics, 5 log messages/second; max 1600 characters/message, no host console or native handle. |
## IRenderContext

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IRenderContext` | unsupported | No dynamic geometry buffer or render-context capabilities cross the Worker boundary. Explicit diagnostic; no host/native context. |
## global

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `global.renderContext` | unsupported | No dynamic geometry buffer or render-context capabilities cross the Worker boundary. Explicit diagnostic; no host/native context. |
## IInput

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IInput` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `IInput.cursorWorldPosition` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `IInput.cursorScreenPosition` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
| `IInput.cursorLeftDown` | implemented | Layer: bounded live snapshots and validated write-back; supported decoded renderer layer types only. |
## global

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `global.input` | implemented | Compartment-owned API facade; Worker snapshots/commands only, no ambient native/DOM/network capabilities. |
## ILocalStorage

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `ILocalStorage` | implemented | Storage/shared: typed memory-only storage, 100 KiB / 256 keys, global/screen namespaces. No persistent or cross-display synchronization; capability diagnostic states session scope. |
| `ILocalStorage.LOCATION_GLOBAL` | implemented | Storage/shared: typed memory-only storage, 100 KiB / 256 keys, global/screen namespaces. No persistent or cross-display synchronization; capability diagnostic states session scope. |
| `ILocalStorage.LOCATION_SCREEN` | implemented | Storage/shared: typed memory-only storage, 100 KiB / 256 keys, global/screen namespaces. No persistent or cross-display synchronization; capability diagnostic states session scope. |
| `ILocalStorage.set` | implemented | Storage/shared: typed memory-only storage, 100 KiB / 256 keys, global/screen namespaces. No persistent or cross-display synchronization; capability diagnostic states session scope. |
| `ILocalStorage.get` | implemented | Storage/shared: typed memory-only storage, 100 KiB / 256 keys, global/screen namespaces. No persistent or cross-display synchronization; capability diagnostic states session scope. |
| `ILocalStorage.delete` | implemented | Storage/shared: typed memory-only storage, 100 KiB / 256 keys, global/screen namespaces. No persistent or cross-display synchronization; capability diagnostic states session scope. |
| `ILocalStorage.clear` | implemented | Storage/shared: typed memory-only storage, 100 KiB / 256 keys, global/screen namespaces. No persistent or cross-display synchronization; capability diagnostic states session scope. |
## global

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `global.localStorage` | implemented | Storage/shared: typed memory-only storage, 100 KiB / 256 keys, global/screen namespaces. No persistent or cross-display synchronization; capability diagnostic states session scope. |
## IEngine

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IEngine` | implemented | Event: bounded engine snapshots refreshed per event/frame; clock fields advance, dimension Vec2 methods retained. |
| `IEngine.isRunningInEditor` | implemented | Event: bounded engine snapshots refreshed per event/frame; clock fields advance, dimension Vec2 methods retained. |
| `IEngine.isPortrait` | implemented | Event: bounded engine snapshots refreshed per event/frame; clock fields advance, dimension Vec2 methods retained. |
| `IEngine.isLandscape` | implemented | Event: bounded engine snapshots refreshed per event/frame; clock fields advance, dimension Vec2 methods retained. |
| `IEngine.isDesktopDevice` | implemented | Event: bounded engine snapshots refreshed per event/frame; clock fields advance, dimension Vec2 methods retained. |
| `IEngine.isMobileDevice` | implemented | Event: bounded engine snapshots refreshed per event/frame; clock fields advance, dimension Vec2 methods retained. |
| `IEngine.isWallpaper` | implemented | Event: bounded engine snapshots refreshed per event/frame; clock fields advance, dimension Vec2 methods retained. |
| `IEngine.isScreensaver` | implemented | Event: bounded engine snapshots refreshed per event/frame; clock fields advance, dimension Vec2 methods retained. |
| `IEngine.AUDIO_RESOLUTION_16` | implemented | Event: bounded engine snapshots refreshed per event/frame; clock fields advance, dimension Vec2 methods retained. |
| `IEngine.AUDIO_RESOLUTION_32` | implemented | Event: bounded engine snapshots refreshed per event/frame; clock fields advance, dimension Vec2 methods retained. |
| `IEngine.AUDIO_RESOLUTION_64` | implemented | Event: bounded engine snapshots refreshed per event/frame; clock fields advance, dimension Vec2 methods retained. |
| `IEngine.registerAudioBuffers` | implemented | Bounded, stable Float32Array channels at 16/32/64 samples update from Luma’s active audio source: optional live system capture, wallpaper audio, deterministic fallback, or silence when audio is disabled. The bridge does not invent song metadata. |
| `IEngine.registerAsset` | implemented | Pure/command: validated normalized project-relative path handle; lazy renderer loading, precache request is not implemented and diagnosed. |
| `IEngine.setTimeout` | implemented | Command: Worker timers, cancel closure; 16/script, 32/scene; intervals ≥16ms; callbacks watched by host; cleared on script/scene destruction. |
| `IEngine.setInterval` | implemented | Command: Worker timers, cancel closure; 16/script, 32/scene; intervals ≥16ms; callbacks watched by host; cleared on script/scene destruction. |
| `IEngine.openUserShortcut` | unsupported | No native shortcut/process launcher exposed to wallpaper scripts. Explicit unavailable error. |
| `IEngine.screenResolution` | implemented | Event: bounded engine snapshots refreshed per event/frame; clock fields advance, dimension Vec2 methods retained. |
| `IEngine.canvasSize` | implemented | Event: bounded engine snapshots refreshed per event/frame; clock fields advance, dimension Vec2 methods retained. |
| `IEngine.userProperties` | implemented | Event: bounded engine snapshots refreshed per event/frame; clock fields advance, dimension Vec2 methods retained. |
| `IEngine.timeOfDay` | implemented | Event: bounded engine snapshots refreshed per event/frame; clock fields advance, dimension Vec2 methods retained. |
| `IEngine.frametime` | implemented | Event: bounded engine snapshots refreshed per event/frame; clock fields advance, dimension Vec2 methods retained. |
| `IEngine.runtime` | implemented | Event: bounded engine snapshots refreshed per event/frame; clock fields advance, dimension Vec2 methods retained. |
## global

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `global.engine` | implemented | Compartment-owned API facade; Worker snapshots/commands only, no ambient native/DOM/network capabilities. |
## IAnimation

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IAnimation` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimation.fps` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimation.frameCount` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimation.duration` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimation.name` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimation.rate` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimation.play` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimation.pause` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimation.stop` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimation.isPlaying` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimation.getFrame` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
| `IAnimation.setFrame` | implemented | Layer/command: existing decoded controller state and bounded playback commands; missing animation or decoder reports unavailable. |
## global

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `global.shared` | implemented | Storage/shared: Worker-owned shared data/functions; bounded serializable data only sent to host; helpers keep current clocks. |
| `global.thisObject` | implemented | Layer: current bound layer/effect facade; current effect visible routed correctly. Material-property object identity is not bridged; no material-animation claim. |
## Shared

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `Shared` | implemented | Storage/shared: arbitrary Worker-owned values/helper functions; bounded serializable host snapshots. Website alias for shared. |
## IThisPropertyObject

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IThisPropertyObject` | implemented | Layer: website alias of current property object; bound-property getAnimation supported. Effect/material property animation identity is unavailable. |
## IEffect

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IEffect.getAnimation` | unsupported | Effect property animation controller identity is not transported; explicit unavailable error. |
## IMaterial

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IMaterial.getAnimation` | unsupported | Material constant animation controller identity is not transported; explicit unavailable error. |
## IAnimationLayer

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `IAnimationLayer.getAnimation` | unsupported | Nested clip property animations are not transported; explicit unavailable error. |
## global

| API | Status | Bridge and limitation |
| --- | --- | --- |
| `global.Date` | implemented | Pure: compartment Date uses host numeric wall-clock samples refreshed on each event, timer and frame; no ambient Date/native capabilities. |
| `global.Date.now` | implemented | Pure: current numeric wall-clock event sample, synchronized with Date construction. |
| `global.Math.random` | implemented | Pure: private compartment pseudorandom generator; no native capabilities. |

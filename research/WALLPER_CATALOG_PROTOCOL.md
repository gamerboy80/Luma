# Wallper catalog protocol findings

Luma's local research inspected the compiled Wallper 1.12.1 app bundle. This was static inspection, not access to Wallper's original Swift source. Wallper's public GitHub repository describes the app as closed source and provides releases and documentation rather than application source.

## Observed in the local app

- Type and method names include `VideoLibraryStore`, `loadRemoteLibrary()`, `downloadVideoIfNeeded(canonicalID:)`, `downloadWithProgress(session:delegate:url:)`, and `ExploreSearchRequest`.
- CDN roots include `https://cdn.wallper.app/wallper-video/`, `https://cdn.wallper.app/wallper-user-generated/`, and `https://cdn.wallper.app/previews/`.
- The backend base URL is `https://services.wallper.app/`.
- `library-metadata.json` appears in a local metadata-cache path. This does not establish that the same path is remotely hosted.
- `WallperAPISecurity`, `Response signature verification failed`, and a base64-encoded public key appear in the binary. The evidence does not identify which responses are verified, the signature header or format, or the signed bytes.

## Not verified

The inspected binary and public documentation do not establish the search URL or HTTP method; request fields, filters, pagination, or sorting; required headers or authentication; response and error schemas; signature verification details; or how catalog IDs map to video and preview object paths.

The CDN roots and backend host are not enough to implement a compatible client. Luma leaves Wallper catalog search and download disabled rather than guessing requests or bypassing a possibly required signature check. A published API contract or a verified request/response capture from Wallper is needed.

The local evidence files and the Wallper app bundle are kept in a separate research workspace and are not part of this Luma repository.

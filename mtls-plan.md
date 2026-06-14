# mTLS Client Certificate Authentication for Finamp

## Goal
Enable Finamp to connect to Jellyfin servers that require mutual TLS (mTLS) client certificate authentication.

## Test Environment
- **Test file**: `finamp.p12` (password: `123`) at project root
- **Test servers**: `https://j.terraaustralis.mywire.org/` or `https://j2.terraaustralis.mywire.org/`
- **Simulator**: iPhone 16 (Xcode 16.4, iOS 18.5 SDK)
- **Physical device**: iPhone 13 mini "Aussiebro" (iOS 26.5) via USB — Xcode 16.4 successfully deploys to iOS 26.5

## Approach
Pure Dart via `SecurityContext` + PKCS12 file on disk. Since native players (AVPlayer, libmpv) and `background_downloader` (URLSession) bypass Dart's `HttpClient`, a local HTTP proxy is used to inject mTLS.

## Architecture
`SecurityContext.useCertificateChain(path)` + `SecurityContext.usePrivateKey(path, password:)` → `HttpClient(context:)`

## Tasks
- [x] Write mtls-plan.md
- [x] 1. Add `clientCertificatePath`, `clientCertificatePassword`, `clientCertificateName` fields to `FinampUser`
- [x] 2. Create `ClientCertificateSelector` widget in `NetworkSettingsScreen`
- [x] 3. Implement PKCS12 file import flow (file picker → copy to app docs dir → store path + password)
- [x] 4. Implement certificate removal flow (delete file + clear fields)
- [x] 5. Configure `SecurityContext` with client cert in `JellyfinApi.create()` via `createClientCertSecurityContext()`
- [x] 6. Background isolate gets mTLS automatically (same `create()` method)
- [x] 7. Run `build_runner` to regenerate models + build + install on simulator
- [x] 8a. Debug pre-login cert import: `PreLoginCertificate` class + import before login
- [x] 8b. Fix `authenticateViaName` to create fresh API with pre-login cert
- [x] 8c. Fix `_pingSpecificServer` and `loadCustomServerPublicInfo` to use pre-login cert
- [x] 8d. Fix background isolate mTLS: recreate `backgroundApi` on each request + null signal
- [x] 8e. Fix stale cert path after iOS sim container change: `File.existsSync()` check + derived path fallback
- [x] 8f. Never delete `pre_login.p12` during migration; keep `PreLoginCertificate` as fallback
- [x] 9. **Local audio proxy** — `LocalAudioProxy` serves `localhost:PORT/proxy?url=...`, forwards to Jellyfin with mTLS HttpClient; `_trackUri()` rewrites audio URIs through it
- [x] 10. **Download routing** — `_rewriteForProxy()` in `downloads_service_backend.dart` rewrites download URLs through the proxy
- [x] 11. **WebSocket fix** — `IOWebSocketChannel.connect(wsUrl, customClient: HttpClient(context: secCtx))` in `playon_service.dart`
- [x] 12. **`cachedDocumentsPath` global** — set at startup in both main and background isolates for sync cert path derivation
- [x] 13. **Commit `ceadaf0c`** on `redesign` branch with all changes above
- [x] 14. **Manual test**: full login → import cert → restart → API/audio/downloads/WebSocket all work — tested on physical iPhone 13 mini (iOS 26.5)
- [ ] 15. **Debug auto-import** (`kDebugMode` auto-detects .p12 in `{documentsDir}/certificates/`) — works when a user is logged in
- [x] 16. **Diagnose and fix app freeze** when switching tracks while music plays
- [x] 17. **Route images through proxy** to fix TLS errors on album art
- [x] 18. **Investigate (-11849) Operation Stopped** — pre-existing libmpv error when switching albums while a song is playing; confirmed not caused by mTLS changes

## Known Limitations
- **Chicken-and-egg**: Can't configure a certificate before logging in. If the server requires mTLS for all endpoints (including login), the user won't be able to reach the login screen to configure the cert. **Resolved**: Pre-import cert on the login screen before connecting to the server.
- **`_pingSpecificServer`** now uses `PreLoginCertificate.createSecurityContext()` as fallback.
- **No reconnect**: After importing a cert, `refreshJellyfinApi()` is called to create a fresh API instance.
- **Main-thread proxy streaming**: `proxyResponse.pipe(request.response)` runs on the main isolate's event loop. High-throughput audio streaming may compete with UI events.

## Decisions
- **Pure Dart over method channel**: Simpler, cross-platform, no native code. Fall back to native channel only if Flutter engine doesn't handle PKCS12 on iOS.
- **PKCS12 file on disk over Isar bytes**: File system is better for binary data; path is stored in Isar.
- **Password in Isar**: Acceptable for personal use.
- **Per-user certificate**: Each `FinampUser` can have its own client cert, stored as `{documentsDir}/certificates/{userId}.p12`.
- **Pre-login certificate**: Stored separately as `{documentsDir}/certificates/pre_login.p12`, used before a user is logged in. Never deleted after login — kept as a fallback.
- **Stale path recovery**: `createClientCertSecurityContext()` checks if the cert file exists at the stored path; if not, it derives the path from the current documents directory + user ID (handles iOS simulator container changes).
- **Local HTTP proxy over native method channel**: Simplest cross-platform way to inject mTLS into native players without writing Swift/ObjC code.
- **Keep `pre_login.p12` after migration**: Prevents path-staleness bug when iOS container changes between launches.

## Bug/Issue History

### Round 1: Login fails with TLSV1_ALERT_CERTIFICATE_REQUIRED
- **Root cause**: `authenticateViaName()` used the existing `jellyfinApi` instance which didn't have the imported cert.
- **Fix**: `JellyfinApi.create()` falls back to `PreLoginCertificate.createSecurityContext()`. Called `refreshJellyfinApi()` after cert import.

### Round 2: Background isolate TLS errors
- **Root cause**: Background isolate created `backgroundApi` once at startup, never refreshed.
- **Fix**: Recreate `backgroundApi` on every request. Null signal from main thread triggers recreation.

### Round 3: PathNotFoundException for cert file
- **Root cause**: `_migratePreLoginCertificate` deleted `pre_login.p12` and cleared `PreLoginCertificate`. On next app start, iOS sim container changed, stored absolute path was stale, and the fallback was gone.
- **Fix**: Keep `pre_login.p12` after migration. Keep `PreLoginCertificate` configured. Add `File.existsSync()` check in `createClientCertSecurityContext()` with derived-path fallback.

### Round 4: App freezes after switching tracks while music plays
- **Symptoms**: After selecting a new track from Favorites while music is playing, the app becomes completely unresponsive. Last log entry at 08:19:51 shows proxy request [13] started but never completed. No crashes, errors, or timeouts logged afterward.
- **Timeline**: User was playing a shuffled queue (~250 items). At 08:19:51 the queue was replaced with 5 Favorites tracks. Three proxy requests were made simultaneously: [11] → Done (206), [12] and [13] → started but only [11] completed. Request [13] (Billie Jean) never returned.
- **Root cause**: Two contributing factors:
  1. Each proxy request created a **new `HttpClient`** instance → new TCP connection + TLS handshake + PKCS12 parsing on every request, starving the event loop.
  2. When the native player disconnected from the proxy socket (during queue replacement), `proxyResponse.pipe(request.response)` never detected the disconnection and hung forever, blocking the proxy from handling new requests.
- **Fix 1** (`local_audio_proxy.dart`): Cache a single `HttpClient` + `SecurityContext` instance. `stop()` clears both caches. Removed per-request `finally { client.close() }`.
- **Fix 2** (`local_audio_proxy.dart`): Race `pipe` with `request.response.done` so the proxy detects client disconnection and stops piping instead of hanging.
- **Status**: Fixed and verified. App ran for 10+ minutes with queue replacement, Track switching, image loading, and audio streaming all completing normally. No freeze or TLS errors observed.

### Round 5: Image TLS errors (TLSV1_ALERT_CERTIFICATE_REQUIRED)
- **Symptoms**: All album art and user avatar images fail to load with `TLSV1_ALERT_CERTIFICATE_REQUIRED`. Affects both `flutter_cache_manager` (disk cache) and `NetworkImage` (in-memory cache).
- **Root cause**: `getImageUrl()` and `getUserImageUrl()` in `jellyfin_api_helper.dart` returned direct Jellyfin server URLs. `flutter_cache_manager` and `NetworkImage` use the `http` package's default `IOClient`, which creates a plain `HttpClient` without mTLS client certificates.
- **Fix** (`jellyfin_api_helper.dart:1171-1204, 1206-1233`): Both functions now rewrite URLs through `LocalAudioProxy.urlForProxy()` when the proxy is running, so all image requests use mTLS.
- **Status**: Fixed and verified. Proxy requests for `Images/Primary` return 200 with no TLS errors.

### Round 6: (-11849) Operation Stopped when switching albums mid-playback
- **Symptoms**: After playing a song and then navigating to another album and tapping a track, the player shows `(-11849) Operation Stopped` error. The queue is replaced and proxy requests succeed, but the native player fails to start.
- **Timeline**: Queue replaced → player pauses → proxy serves new audio (Done 206 in ~60-80ms) → media-kit returns `(-11849) Operation Stopped` → app shows error snackbar.
- **Root cause**: Pre-existing media-kit/libmpv issue — the native player's pipeline is still transitioning when `play()` is called after a queue replacement. Not caused by mTLS changes.
- **Upstream research**:
  - `media-kit/media-kit` issue **#1115** (closed duplicate of **#964**): *"Deactivating an audio session that has running I/O"* — when switching tracks on iOS, the old player's audio session is deactivated while I/O is still running, triggering `AVErrorOperationStopped (-11849)`. Issue #964 is still open.
  - `Pato05/just_audio_media_kit`: No relevant issues or PRs. Only 4 open issues, none about audio sessions or freezes.
  - `media-kit/media-kit` is now in **[Limited Maintenance](https://github.com/media-kit/media-kit/issues/1337)** (issue #1337).
  - Qiita article (2021) suggests `AudioPlayer.clearAssetCache()` to fix cache inconsistency causing this error in vanilla `just_audio`.
- **Likelihood**: Previously masked because audio failed silently with TLS errors when mTLS was required. Now that audio actually reaches the native player, this edge case surfaces.
- **Status**: No upstream fix available. Workaround is app restart. Could potentially be mitigated by adding a small delay between `pause()` and `play()` in the queue service, but root cause is in media-kit/libmpv's iOS audio session management.

### Round 7: Physical device deployment (iPhone 13 mini on iOS 26.5)
- **Symptoms**: `flutter run` fails with signing errors, CarPlay/Siri capabilities not supported by free personal team, app crashes when launched by tapping icon (debug mode restriction).
- **Fixes applied**:
  1. Changed `DEVELOPMENT_TEAM` from `PFNS8PTRM7` (original team) to `MR74D9LZ3H` (user's personal team) in `ios/Runner.xcodeproj/project.pbxproj` (3 occurrences).
  2. Changed `PRODUCT_BUNDLE_IDENTIFIER` from `com.unicornsonlsd.finamp-ios` to `com.thiagocsf.finamp-ios` (3 occurrences).
  3. Removed Siri entitlement (`com.apple.developer.siri`) from `Runner.entitlements`.
  4. Removed CarPlay audio entitlement (`com.apple.developer.carplay-audio`) from `Runner.entitlements`.
- **Result**: App builds, deploys, and runs successfully on iPhone 13 mini with iOS 26.5. All mTLS flows confirmed working: API calls, audio streaming, image loading, WebSocket. The immediate crash when tapping the icon is expected — debug-mode Flutter apps cannot be launched from the home screen on iOS 14+. Use `flutter run` to launch.
- **Status**: Working. These changes are device-specific and should be kept local (not committed).

## Relevant Files
| File | Change |
|------|--------|
| `lib/models/finamp_models.dart` | Add cert fields to `FinampUser` |
| `lib/models/finamp_models.g.dart` | Regenerated by build_runner |
| `lib/services/jellyfin_api.dart` | `createClientCertSecurityContext()` with stale path recovery + PreLoginCertificate fallback |
| `lib/services/pre_login_certificate.dart` | Static holder for pre-login cert |
| `lib/services/jellyfin_api_helper.dart` | `importP12File()`, `_importPreLoginCertificate()`, `_migratePreLoginCertificate()` (no delete), background isolate API recreation |
| `lib/services/documents_path.dart` | Global `cachedDocumentsPath` for sync cert path derivation |
| `lib/services/local_audio_proxy.dart` | Local HTTP proxy — `handleRequest` creates `HttpClient(context: secCtx)` per request, pipes response |
| `lib/services/music_player_background_task.dart` | `_trackUri()` rewrites through proxy; proxy lifecycle in `MusicPlayerBackgroundTask` |
| `lib/services/downloads_service_backend.dart` | `_rewriteForProxy()` rewrites download URLs |
| `lib/services/playon_service.dart` | `IOWebSocketChannel.connect` with `customClient` for mTLS WebSocket |
| `lib/components/NetworkSettingsScreen/client_certificate_selector.dart` | Import/remove cert UI |
| `lib/screens/network_settings_screen.dart` | Add cert selector |
| `lib/components/LoginScreen/login_flow.dart` | Pre-login cert flow |
| `lib/components/LoginScreen/login_server_selection_page.dart` | Pre-login cert import on login screen |
| `lib/services/finamp_user_helper.dart` | User load, cert path initialization |

## Risks
- Flutter engine's `SecurityContext` on iOS may not handle PKCS12 correctly → fallback to method channel
- Password in plaintext in Isar → acceptable for personal use
- Need to run `dart run build_runner build --delete-conflicting-outputs` after model changes
- Proxy on main isolate may cause UI jank or freezes during high-throughput streaming

## Next Steps
1. **Verify auto-import**: `kDebugMode` should auto-detect `.p12` in `{documentsDir}/certificates/` when a user is logged in.
2. **Restore iOS capabilities**: If deploying with a paid Apple Developer account, restore CarPlay and Siri entitlements in `Runner.entitlements` and revert `DEVELOPMENT_TEAM`/`PRODUCT_BUNDLE_IDENTIFIER` to original values.

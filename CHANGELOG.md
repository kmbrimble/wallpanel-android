# Changelog

## [Unreleased]

### 2026-08-30 — WebView renderer-crash recovery, service handler leak fix

Plan:
- Verify `onRenderProcessGone` recovery path (already present via `InternalWebClient` →
  `BrowserActivityNative.onWebViewRenderProcessGone`, returns `true` so Chromium does not
  abort the host process). Fix: rebuild path hardcodes `LAYER_TYPE_SOFTWARE`, dropping the
  user's hardware-acceleration preference — mirror the conditional already used in `onStart()`.
  Report the always-true `binding.swipeContainer != null` warning at `complete()` (unrelated
  to renderer-crash handling, ViewBinding non-null field, no fix needed).
- Fix `WallPanelService`: deferred-init `mainHandler.postDelayed(::runDeferredInit, 1200)`
  posted in `onCreate()` is never cancelled in `onDestroy()` (only `reconnectHandler` is).
  Cancel `mainHandler` in `onDestroy()` and add a destroyed-guard in `runDeferredInit()`.
- Investigate LeakCanary (already `debugImplementation` on master — no fix needed) and report
  Firebase dependency state (unconditional `implementation`, decision deferred to user).
- No JVM test added for the service handler fix: `WallPanelService` requires Dagger injection
  and a real Android `Looper`, not meaningfully testable without Robolectric, which is out of
  scope to add. Verification is a clean build plus device install.

Result:
- Change 1 needed a real fix (hardware-acceleration regression on the crash-rebuild path);
  the renderer-crash recovery itself was already correct on master (Darknetzz's diff).
- Change 2 needed a real fix (deferred-init handler leak in `WallPanelService.onDestroy()`).
- Change 3 needed no fix — LeakCanary was already `debugImplementation`-scoped on master.
  Firebase deps (`firebase-core`, `firebase-bom`, `firebase-analytics`,
  `firebase-crashlytics-ktx`) remain unconditional `implementation` in
  `WallPanelApp/build.gradle` — reported only, left for a separate decision.
- `prod` flavour applicationId collided with the currently-installed TheTimeWalker build
  (`xyz.wallpanel.app`), and that build is signed with a different key, so a same-ID install
  would have been rejected (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`) rather than silently
  replacing it. Added `applicationIdSuffix ".kmb"` (→ `xyz.wallpanel.app.kmb`) and a
  prod-only app label override ("WallPanel (KM)") via `src/prod/res/values/strings.xml`,
  so both builds can be installed side by side and distinguished in the launcher.
- versionName `0.12.0 Build 0` → `0.12.0 Build 0-kmb.1`, versionCode `12000` → `12001`.
- Built `assembleProdRelease` (unsigned — no signingConfig in build.gradle, none added),
  zipaligned, and signed out-of-band with apksigner using the keystore at
  `/projects/wallpanel-release.jks`. Verified signature: SHA-256
  `4d:a6:a8:5a:62:86:f6:85:68:d7:ed:e5:52:f6:d2:6c:bd:d4:ba:66:c1:15:a5:e1:8a:9e:24:c5:ef:5f:22:91`.

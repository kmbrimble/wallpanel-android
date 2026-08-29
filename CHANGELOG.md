# Changelog

## [Unreleased]

### 2026-08-30 — Test infrastructure: scoped lint gate, dev app ID, on-device smoke test

Plan:
- Re-enable lint (`WallPanelApp/build.gradle`): remove the blanket
  `tasks.configureEach { ... t.enabled = false }` kill switch (scope it to JDK 25+ only,
  matching its original stated purpose, since this container runs JDK 17) and set
  `checkReleaseBuilds = true` so AGP's built-in `lintVital<Variant>` task (which only
  checks Fatal-severity issues by design) gates `assembleProdRelease`. The full `lint`
  task remains available on demand for a complete severity report without gating any
  build. Report the severity breakdown from a `lintProdDebug` run.
- `buildTypes { debug { applicationIdSuffix ".dev" } }` — combined with the `prod`
  flavour's existing `applicationIdSuffix ".kmb"`, `prodDebug` gets
  `xyz.wallpanel.app.kmb.dev`, distinct from both installed apps. Distinguishable label
  via `src/debug/res/values/strings.xml` (buildType resources win over flavour
  resources for the same variant). `release` buildType untouched — verify
  `xyz.wallpanel.app.kmb` is unchanged on the built release APK.
- `scripts/smoke-device.sh <apk>`: verifies the APK's applicationId (via `aapt2 dump
  badging`, not the filename) exactly matches the dev ID before doing anything, installs,
  launches, waits, checks process/crash-buffer/window-focus/service-running, runs
  `adb shell monkey`, re-checks, uninstalls on exit regardless of outcome, and fails
  closed (clear message, non-zero exit, no hang) if the device is unreachable.
- Verified `WallPanelService` starts unconditionally from `BaseBrowserActivity.onStart()`
  and DEBUG builds force `configuration.isFirstTime = false` in `BrowserActivityNative`,
  so a fresh dev-APK install reaches the main activity and starts the service without
  any first-run gating — the smoke test's checks are reachable on a clean install.
- Test-the-test: build a deliberately broken debug APK, confirm smoke-device.sh reports
  FAIL, then confirm a clean build reports PASS; revert the deliberate breakage.

Result:
- Lint gate: re-enabling it surfaced one genuine fatal (`UnspecifiedImmutableFlag` in
  `AppExceptionHandler.kt`, the crash-handler's own PendingIntent) which was fixed as an
  approved scope exception (separate commit). `assembleProdRelease` now passes with the
  gate live. Severity report from `lintProdDebug`: 0 Fatal, 18 Error, 304 Warning,
  2 Information -- none of the 18 Errors are in AGP's Fatal set (confirmed empirically:
  `lintVitalProdRelease` passes clean).
- Dev app ID: `prodDebug` variant now installs as `xyz.wallpanel.app.kmb.dev`, label
  "WallPanel (KM) DEV". Verified with `aapt2 dump badging` on the built APKs (not the
  filename) that the release APK's applicationId is unchanged at `xyz.wallpanel.app.kmb`.
- `scripts/smoke-device.sh`: two device-behaviour issues found and fixed during testing,
  not app bugs: (1) the device's screen-timeout puts it back to sleep during the ~60s
  wait, at which point `dumpsys window`'s `mCurrentFocus` reports null regardless of
  what's actually in front -- fixed by waking the device immediately before every focus
  check, not just once at launch; (2) a single flaky adb round-trip could report an empty
  `pidof` for a process that was actually still running -- fixed with a one-shot retry.
  `monkey --pct-syskeys 0` could not actually inject touch/motion events in this
  environment (`/dev/input/event0: EACCES`) -- it still ran and reported its own
  exit status/crash text, so the check remains meaningful, but real input coverage
  from this step is currently near zero; noted as a harness gap, not fixed here.
- `run_checks` compares against a pid baseline (not just "process alive") because,
  from reading the code, `AppExceptionHandler` intercepts uncaught exceptions and
  relaunches via an alarm without writing "FATAL EXCEPTION" to the crash buffer --
  a real crash there could otherwise look like a healthy app to a naive
  process-alive/crash-grep check. Tried to verify this end-to-end with
  `adb shell am crash <pkg|pid>` on the physical device; it did not reliably produce
  a confirmable result (no output, inconsistent exit codes, no pid change traceable
  to the injection specifically) after several attempts on this device/ROM
  (Lenovo TB-J616F). Not chasing further per the "say so and move on" guidance --
  the pid-baseline check is a reasoned design response to a real code-level finding,
  not an empirically confirmed one.
- FAIL demonstrated by throwing in `WallPanel.onCreate()` (before any activity/handler
  exists, so it hits the default crash handler): smoke-device.sh reported
  `RESULT: FAIL` with `[startup] process did not come up after launch`, exit 1. Reverted
  the throw (diff against HEAD is clean), rebuilt, reran: `RESULT: PASS`, exit 0.
  Also demonstrated the applicationId-refusal FAIL (against the release APK) and the
  device-unreachable FAIL (`SMOKE_SERIAL=192.168.0.99:5555`, fails closed in ~3s, no
  hang). `SERIAL` is now overridable via `SMOKE_SERIAL` for exactly this kind of test.
  Note: the crash-buffer-grep branch of the checks never fired in any demo run (every
  FAIL demo died at startup instead) -- that branch is untested, not just unexercised
  by a passing run.
- Not built, and why: a way to force a real touch-input-driven crash for the monkey step
  (blocked by the `/dev/input` permission issue above, not attempted); a way to
  independently verify `AppExceptionHandler`'s relaunch actually completes end-to-end
  post-fix without an artificial `Application.onCreate` crash (out of scope -- would need
  application-code changes beyond the approved PendingIntent fix, or `adb shell am crash`
  which is untested here); CI wiring for this script (no CI in this repo, out of scope).
- Also noticed, unrelated to this feature and not touched: the `logcat` tmux session
  named in the task instructions isn't running (`tmux list-sessions` doesn't show it),
  and its log file stopped growing hours ago. Did not restart or investigate further.

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

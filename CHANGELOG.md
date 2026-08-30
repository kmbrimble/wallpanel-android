# Changelog

## [Unreleased]

### 2026-08-30 — Reduce camera capture rate at the sensor

The front camera drives motion detection so the screensaver dismisses on walk-up. It was
running far faster than that job needs, burning CPU, power and log bandwidth.

What changed:
- `default_camera_fps` 15 → 10 (`donottranslate.xml`), and the matching parse-failure
  fallback in `Configuration.cameraFPS` 15.0F → 10.0F. 10 rather than 5 because 10fps is
  this hardware's lowest *fixed* preview range (see below) — defaulting to a rate the
  sensor cannot deliver would advertise a lie in the settings UI, the same class of
  problem as the hardcoded `android:summary="15"` fixed below. The user-facing **Camera FPS**
  preference already existed and already reached `CameraSource.setRequestedFps` via
  `Configuration.cameraFPS` → `CameraReader.initCamera`, so this is a default change on
  an already-wired setting, not a new mechanism.
- `pref_camera.xml` had a hardcoded `android:summary="15"` that never tracked the value;
  pointed it at `@string/pref_camera_fps_summary` and updated that string.
- New `CameraFpsPin` (`modules/CameraFpsPin.kt`), called after every successful
  `cameraSource.start()` in `CameraReader.startCamera` (all three paths, including both
  camera-facing fallbacks). `CameraSource.setRequestedFps` only selects the *closest*
  supported range by an undocumented min+max metric, which can land on a wide range such
  as `[5000,30000]` that the HAL floats up to its ceiling in good light. `CameraFpsPin`
  reaches the underlying `Camera` and sets a range chosen by its **ceiling**, which is
  what actually caps frame delivery. Guarded in try/catch — a camera running too fast
  still works, one we've thrown out of does not.
- Unit test `CameraFpsPinTest` covers the range-selection logic against the ranges this
  Lenovo really reports.

Measured on `xyz.wallpanel.app.kmb.dev` (Lenovo TB-J616F, Android 12), 30s windows.
Each delivered frame emits two `Camera3-OutputStream` line groups (`format:17` and
`format:35`), so frame rate is derived from timestamps, not raw line counts:

| | before (pref 15) | after (default 10) |
|---|---|---|
| delivered frame rate | 15.0 fps (frames 66ms apart) | 10.0 fps (frames 100ms apart) |
| `Camera3-OutputStream` lines/s | 88.0 | 60.4 |
| `dumpsys meminfo` TOTAL PSS | 170.6 MB | 174.5 MB |

Supported preview FPS ranges on this device, read from the hardware:
`[10000,10000] [15000,15000] [15000,20000] [20000,20000] [5000,30000] [30000,30000]`

**5fps is not reachable on this hardware**, which is why the default is 10. The lowest
*fixed* range is 10fps; the only range with a 5fps floor is `[5000,30000]`, which floats
to 30fps. So the reduction is 1.5x, not the 6x originally hoped for — 10fps is the sensor
floor, and the pin holds it there. The measurements above were taken with the default at
5, which `CameraFpsPin` resolved to `[10000,10000]`; a default of 10 resolves to the same
range, so the numbers are unchanged and the UI no longer advertises an unachievable rate.
No frame-level throttling was added: it would cut detection CPU but leave the HAL, power
draw and log noise untouched, and the sensor is already at its floor.

The Camera FPS preference is a free-text `EditTextPreference`, not a fixed option list, so
nothing advertises unachievable values — but any number can be typed, and `CameraFpsPin`
maps whatever is entered onto the nearest supported ceiling.

**Memory did not improve** (170.6 → 174.5 MB PSS, within run-to-run noise). The
hypothesis that capture rate drives the renderer memory pressure is not supported.

Also noted: `setting_camera_processinginterval` (default 500ms) is defined in resources
but read by no Kotlin code — a dead preference, left alone as out of scope.

**NOT PROMOTED — blocked by a device-side fault, not by this change.**

`scripts/smoke-device.sh` PASSes. `scripts/smoke-renderer-crash.sh` FAILs at cycle 1
with "no renderer process found", and fails **identically on unmodified master** with the
same device state — a camera-only diff cannot affect WebView renderer processes.

Diagnosis: the tablet will not spawn a WebView renderer for this app at all. Its
`ServiceRecord{... xyz.wallpanel.app.kmb.dev/org.chromium.content.app.SandboxedProcessService1:0}`
stays **Pending** with no bound `app=ProcessRecord`, and logcat shows
`cr_ChildProcLH: ScopedServiceBindingBatch.tryActivate: false` plus
`ProcessStats: Binding service ... without owner`. So a WebView is created and *does*
request a renderer; the OS never starts the process. Ruled out during investigation:
- app not foreground / screen asleep — reproduced with `svc power stayon true`, screen
  verifiably `mWakefulness=Awake` and the activity holding window focus;
- **the production app holding the only renderer slot** — retested with
  `am force-stop xyz.wallpanel.app.kmb` confirmed stopped for the whole run: the dev
  app's ServiceRecord still stayed `Pending` and the script still FAILed at cycle 1.
  Exclusive use of the panel is *not* the missing ingredient;
- screensaver config — the debug build's forced *clock* screensaver was confirmed by
  screenshot, and `settings_screensaver` turns out to be the same key as
  `hasClockScreenSaver`; switching to `pref_web_screensaver=true` changed nothing;
- stale process state — the tablet was rebooted and the fault persisted;
- WebView being broken system-wide — another app's sandboxed process was running fine.

**Implication beyond this feature:** if renderers cannot spawn for this app, the
screensaver renderer-crash protection added earlier cannot engage on the panel either,
and `smoke-renderer-crash.sh` cannot gate any release until this is resolved. Worth
investigating separately.

Per CLAUDE.md ("If either script fails, do not promote"), the branch is pushed and master
is untouched. Production `xyz.wallpanel.app.kmb` was left running and foregrounded,
measured at ~14.8 fps (still the old default).

### 2026-08-30 — Replace adb-device.sh's mdns fallback with a port scan

`scripts/adb-device.sh` fell back to `adb mdns services` when the pinned `<ip>:5555` was
unreachable after a tablet reboot. That path can never work in this container: mDNS relies
on multicast, which does not cross the Docker bridge, so it always returned zero services.
It failed closed (correct) but read as functional while being dead code.

Replaced with a bounded parallel port scan over `30000-60999` (Android assigns wireless
debugging a port from the ephemeral range), using bash's `/dev/tcp` — this container has
no `ping`, `nc` or `nmap`. 200 concurrent probes at a 0.3s timeout, wrapped in a 90s hard
cap so it cannot hang a capture loop; worst case (every port dropped) is ~47s. Open ports
are then verified serially with `adb connect` + `get-state`, since an open port is not
necessarily adbd, and failed candidates are disconnected so they don't linger in
`adb devices`. On success it re-pins 5555 via `adb tcpip` so the fast path works again.
Structure, fail-closed contract, stdout-is-the-serial convention and the `SMOKE_SERIAL`
bypass are all unchanged.

Verified against the live tablet: the full 30000-60999 sweep completed in **14s** and
found port **37159**, which `adb connect` + `get-state` confirmed as a real device. (The
5555 pin happened to be live again by then, so the resolver itself took the 0.14s fast
path; the scan was verified directly against the same device rather than as a fallback.)
No port is hardcoded — 42049 from the earlier reboot was already gone by this run, which
is exactly why discovery has to be dynamic.

CLAUDE.md now documents the port-scan approach and why mDNS must not be reinstated.

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

**Correction (2026-08-30, follow-up session):** the "did not reliably produce a
confirmable result" line above was wrong. `am crash xyz.wallpanel.app.kmb.dev` (by
package name) DID work -- it crashed the app's WebView renderer process, and the
crash buffer shows the main app process aborted two seconds later with the exact
"Render process ...'s crash wasn't handled by all associated webviews" signature.
This was missed at the time because manual `pidof` polling happened to sample around
the event rather than through it. See REVIEW.md, "Renderer-crash recovery: reproduced,
and it does not always hold" for the full writeup and `scripts/smoke-renderer-crash.sh`
for the reusable repro. The user caught this from the device's crash buffer after the
fact; corrected here rather than left standing.

### 2026-08-30 — WebView renderer-crash recovery, service handler leak fix, signed release

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

### 2026-08-30 — Renderer-crash repro script and investigation

Follow-up to the test-infrastructure session: the "`am crash` did not reliably
produce a confirmable result" line in that entry was wrong (see the correction
note above it). The user caught it from the device's crash buffer; this session
turned it into a reusable, deterministic repro and investigated why recovery
doesn't always hold.

- `scripts/smoke-renderer-crash.sh`: requires the dev app already installed and
  running. Finds the current WebView renderer's PID via `dumpsys activity services`
  (a `ServiceRecord` under the app's own component ties directly to the renderer's
  PID, avoiding the non-determinism of `am crash <package>`, which can hit either
  the main process or an associated renderer depending on what's alive), crashes it
  with `am crash <pid>`, and asserts the app process survives, holds window focus,
  and gets a fresh renderer. Loops several cycles, each waiting 35s untouched first
  so the screensaver's 30s inactivity timeout has a chance to fire -- a first version
  without that wait passed reliably for up to 6 rapid cycles, which turned out to be
  a false PASS: it never left the app idle long enough for the failure condition to
  occur. With the idle wait, it fails deterministically and reproducibly on the first
  cycle with the exact historical abort signature.
- Investigation (full writeup in REVIEW.md): a repository-reader inventory of every
  `WebView` instantiation found the screensaver's `WebViewClient`
  (`ScreenSaverView.kt:199`) has no `onRenderProcessGone` override, unlike the main
  browser's `InternalWebClient`. Chromium shares one renderer process across all
  `WebView` objects in an app and only considers a crash "handled" if every attached
  `WebViewClient` returns `true` from `onRenderProcessGone` -- if the screensaver
  (default `false`) is alive when the shared renderer crashes, the whole app aborts
  regardless of the main browser's correct handler. This matches the abort message's
  plural wording ("wasn't handled by all associated **webviews**") exactly, and
  matches debug builds forcing `hasClockScreenSaver = true` with a 30s default
  inactivity timeout.
- Per advisor: the repro is representative of a real renderer crash (same abort
  signature as the original organic crash on the archived build) and does deliver
  `onRenderProcessGone` (proven by the clean-recovery case producing a fresh renderer
  `ServiceRecord`) -- it is not a harsher teardown than an organic crash for this
  codebase's recovery logic, since `InternalWebClient` doesn't branch on
  `RenderProcessGoneDetail.didCrash()`.
- Also fixed on this branch (script bug, not app code): `smoke-device.sh`'s
  `device_time()` passed an unquoted date format string through `adb shell`, so the
  remote shell only ever saw `+%m-%d` -- every crash-buffer time filter in every
  smoke-device.sh run to date has been scanning an unparseable/wrong range. Fixed by
  quoting the whole format string as one argument for the remote shell.
- CLAUDE.md: release process now specifies signing the `arm64-v8a` split (19.6MB, our
  tablet's actual ABI) instead of the universal APK (36.1MB), with the verified
  `zipalign` + `apksigner sign --ks-pass file:/projects/.env.keystore-pass` +
  `apksigner verify` invocation, and a note not to attach the `.idsig` sidecar to
  releases.
- No app code changed in this session; `feature/test-infrastructure` was merged to
  `master` first (unchanged, pre-approved), and this work is on
  `feature/renderer-crash-repro`, pushed but not merged.

### 2026-08-30 — Fix screensaver WebView's unhandled renderer crash

Plan (branch `feature/screensaver-renderer-crash`, stacked on
`feature/renderer-crash-repro`):
- `ScreenSaverView.kt`: attach a crash-handling `WebViewClient` (matching
  `InternalWebClient`'s `onRenderProcessGone` semantics) to `screenSaverWebView`
  unconditionally in `init()`, not just inside `loadWebPage()` — debug builds only
  force clock-mode (`hasClockScreenSaver = true`, `webScreenSaver` defaults `false`),
  which never calls `loadWebPage()`, so the WebView the repro actually crashes has no
  client attached in any mode today. Per advisor: dismiss the screensaver rather than
  rebuild its WebView in place, since `DialogUtils.showScreenSaver`/
  `hideScreenSaverDialog` already discard and freshly re-inflate the whole dialog
  (including the WebView) on every show/hide cycle — rebuilding in place would just
  reimplement what dismiss+re-show already does for free.
- Delete `CustomWebView.kt` and `WebClientRenderWrapper.kt` (separate commit): both
  confirmed dead by repository-reader — zero live references anywhere in the
  codebase, the only mention of the latter is a commented-out line inside the former.
- Verify with `scripts/smoke-renderer-crash.sh`, both with and without the 35s idle
  wait, across multiple cycles; then `scripts/smoke-device.sh` for regression.
- Release: version bump `-kmb.1` → `-kmb.2`, build/sign the arm64-v8a split per
  CLAUDE.md. Do not install to the production panel.

Result:
- Fix confirmed correct: `smoke-renderer-crash.sh` with the 35s idle wait (the
  scenario that deterministically FAILed before this fix) now PASSes across 4
  consecutive cycles; without the idle wait, PASSes across 6. `smoke-device.sh`
  also PASSes (regression check). Root cause matched exactly what REVIEW.md
  predicted: the repro exercises debug builds' forced clock-mode, where
  `loadWebPage()` never runs, so the fix had to attach the crash handler
  unconditionally in `init()`, not just inside `loadWebPage()`.
- `CustomWebView.kt` and `WebClientRenderWrapper.kt` deleted (separate commit,
  confirmed zero live references, clean build after deletion).
- Mid-task, the user overrode two standing instructions: (1) "do not merge" for
  this feature and its stacked base `feature/renderer-crash-repro` — both
  merged to master; (2) the manual-install release policy — replaced with
  auto-promotion (CLAUDE.md "Deploy and verify — release policy"): verify on
  the dev app with both smoke scripts, and if green, install the signed
  arm64-v8a APK straight to `xyz.wallpanel.app.kmb` with no confirmation
  prompt. Both scripts passed, so this release was auto-promoted per that
  policy. versionCode 12001 → 12002, versionName `... -kmb.1` → `... -kmb.2`.
  Signature SHA-256 confirmed unchanged:
  `4d:a6:a8:5a:62:86:f6:85:68:d7:ed:e5:52:f6:d2:6c:bd:d4:ba:66:c1:15:a5:e1:8a:9e:24:c5:ef:5f:22:91`.
- Whether the *previously installed* production build was already exposed to
  this bug depends on its own screensaver setting (REVIEW.md's still-open
  question) — this release fixes it either way, going forward.

### 2026-08-30 — Resilient tablet address for logcat-capture.sh, smoke-device.sh, smoke-renderer-crash.sh

All three scripts hardcoded `192.168.0.52:5555`, which breaks whenever the tablet
reboots: Android 11+ wireless debugging assigns a random port on each boot, so the
`adb tcpip 5555` pin used to reach it over the LAN is lost.

- Added `scripts/adb-device.sh`, a sourced (not executed) helper exposing
  `wallpanel_resolve_adb_serial`: tries the pinned `<ip>:5555` first, and if
  unreachable, discovers the tablet's current port via `adb mdns services`,
  connects to it, re-pins port 5555 (`adb tcpip 5555`) so the fast path works
  again next time, and reconnects to `<ip>:5555`. Fails with a clear message on
  stderr and a non-zero return — never falls through to a false success — if
  neither the pin nor mdns discovery works.
- The tablet's IP is read from `$WALLPANEL_TABLET_IP` (default `192.168.0.52`),
  not hardcoded.
- `smoke-device.sh` / `smoke-renderer-crash.sh`: `SMOKE_SERIAL` still works as a
  raw serial override that bypasses the resolver entirely, preserving the
  existing fast (~3s) deterministic device-unreachable test path unchanged.
  Verified: that FAIL path still completes in ~3s: `SMOKE_SERIAL=192.168.0.99:5555
  bash scripts/smoke-device.sh <apk>`; a real run with no override resolves via
  the fast path (`[smoke] Connected to 192.168.0.52:5555`) and both scripts still
  PASS end-to-end.
- `logcat-capture.sh`: resolves the serial fresh on every retry-loop iteration
  (source, not one-shot), so a mid-capture tablet reboot is recovered from
  automatically on the next 30s retry rather than looping forever against a dead
  port.
- Verified the fallback path's failure mode directly (pointed the resolver at a
  nonexistent IP): logs the pinned-port failure, runs mdns discovery, and fails
  closed with a clear diagnostic when mdns finds nothing — this container's
  network did not receive any mdns services in testing (multicast is often
  blocked across Docker network bridges), so the mdns discovery path itself is
  implemented and fails closed as specified, but wasn't exercised against a real
  port change (would require actually rebooting the tablet, which wasn't done).

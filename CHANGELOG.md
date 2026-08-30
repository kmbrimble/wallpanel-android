# Changelog

## [Unreleased]

### 2026-08-30 — Run the renderer-crash test against the production app

`scripts/smoke-renderer-crash.sh` now takes a signed production APK, installs it over
`xyz.wallpanel.app.kmb` and runs its crash cycles there, instead of against the `.dev` ID.
`scripts/smoke-device.sh` is unchanged — it works fine on `.dev`.

Why: the dev app cannot obtain a WebView renderer on this tablet. It requests
`SandboxedProcessService1`, whose ServiceRecord never gets a bound process, while
production gets `SandboxedProcessService0` and works normally. The cause is unexplained
and deliberately closed — it affects only the harness, never the shipping app. Testing
the signed production artifact is better evidence anyway: it's exactly what ships, on
exactly the config it ships onto.

Safety, all checked before the device is touched — each refuses outright:
- the candidate must carry the production applicationId (blocks ever pointing it at a
  debug build);
- it must be signed with the same key as the app already installed, compared digest to
  digest against the restore APK rather than a hardcoded value — that's the exact
  predicate for both the install and the rollback being accepted;
- a `release-out/` APK must match the installed versionCode, selected by reading each
  APK's badging rather than munging the filename (versionNames contain spaces, filenames
  use dashes). No match means no way back, so the script refuses to run;
- a downgrade is refused with our own message rather than adb's.

Restore is an EXIT trap gated on an `INSTALLED` flag, so it covers a mid-run death or
interrupt — not just a graceful FAIL — while a preflight refusal can never "restore" over
something that was never installed. The cycles are the verdict: each cycle already checks
window focus and a fresh renderer, so PASS is committed as soon as the loop completes
clean, before any further probing. A final focus check is reported as a warning only —
letting it flip the verdict would let one flaky read roll back a build that had just
survived every cycle.

The script also holds the display on for the duration (`svc power stayon`, original value
restored on exit) and wakes it after install. Without this the test cannot run at all:
Chromium does not activate renderer service bindings for an app that isn't visible, so the
display sleeping during the 35s idle wait made the renderer vanish and produced a spurious
"no renderer process found" failure on the first real run. This does not weaken the idle
wait — it injects no input, so the app's inactivity timer still fires and the screensaver
still mounts.

**Result on master (0.12.0 Build 0-kmb.2, versionCode 12002): PASS, 4/4 cycles.** The app
process was unchanged across every renderer kill, window focus held, and a fresh renderer
appeared each time. The screensaver renderer-crash fix does hold on production.

Sequence, stated plainly: the first run FAILed at cycle 1 for the display-sleep reason
above, the restore trap reinstalled the previous release and confirmed it foregrounded,
and the second run — after the `stayon` fix — PASSed 4/4. So the rollback path is not just
written but field-tested. Note the renderer is *not* bound once the run ends and the
display timeout is restored; that is the same mechanism, not a defect.

The panel is left running the master-signed candidate. It is identical in content to
`release-out/WallPanelApp-arm64-0.12.0-Build-0-kmb.2.apk` but has a different signing
timestamp; `adb install -r -d` with that file puts the exact release artifact back if
that matters.

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

# Security & Reliability Review: TheTimeWalker (archive) → Darknetzz (master)

**Scope:** `archive/master` (TheTimeWalker/wallpanel-android at its May 2025 archive
point, commit `2775abc1`) vs `upstream/master` (Darknetzz/wallpanel-android,
commit `c0242aac`). Merge-base equals the archive HEAD, so this is a clean,
linear 13-commit descent — not a rebase or history rewrite. `origin/master`
(this fork) is identical to `upstream/master` at time of review, so this
assessment applies to the exact code we'd build from.

**Size:** 32 files changed, +292/-263 lines. Small enough to read in full; it
was read in full, not sampled.

## Real problems

**1. Deferred service init handler is never cancelled on teardown.**
`WallPanelService.onCreate()` now defers `configureMqtt()`, `configureCamera()`,
`startHttp()` (the MJPEG server), `configureAudioPlayer()`,
`configureTextToSpeech()`, and `startSensors()` by 1200ms via a new
`mainHandler.postDelayed(::runDeferredInit, 1200)`, to let the launcher
activity draw before the deferred work runs (works around an Android 12+
splash-screen glitch). `onDestroy()` only clears the pre-existing
`reconnectHandler` (`reconnectHandler.removeCallbacksAndMessages(null)`) —
`mainHandler` is never cancelled. If the service is destroyed and recreated
inside that 1.2s window (quick settings change, Android killing/restarting
the service under memory pressure), `runDeferredInit()` still fires against
the torn-down instance and re-runs MQTT/camera/HTTP/sensor setup. This is a
plausible crash/leak source, and it's exactly the kind of thing that would
manifest as "crashes frequently" on a long-running kiosk tablet.
*Recommendation: fix before installing — one line, `mainHandler.removeCallbacksAndMessages(null)` in `onDestroy()`. Not done in this session (assessment only).*

## Genuine improvements

**2. WebView renderer-crash recovery.** The old `InternalWebClient.onRenderProcessGone`
destroyed the crashed WebView and did nothing else — the kiosk was left on a
blank, dead view until the user or a watchdog intervened. The new code
(`onWebViewRenderProcessGone` in `BrowserActivityNative` + `WebClientCallback`)
tears down the dead WebView and builds a fresh one, reattaches listeners, and
reloads the page. WebView renderer crashes under memory pressure are a common
cause of exactly the symptom driving this migration (frequent crashes on the
tablet), so this is a meaningful, targeted fix — not incidental cleanup.

**3. Settings-code and hardware-acceleration-key migrations** (`Configuration.kt`)
fix real bugs (leading-zero codes stored as `Int` lost their zero-padding; a
typo'd preference key `key_hadware_accelerated_enabled` is migrated to the
corrected name). Both are narrow, self-contained, and migrate existing
SharedPreferences data rather than dropping it. Fine.

**4. Progress-view timeout watchdog** (`progressHideTimeoutRunnable`, 20s) — if
a page load never completes, the loading spinner is force-hidden instead of
leaving the UI stuck. Reasonable defensive addition, properly cancelled in
`onDestroy()`.

## Fine, but not what it looks like

**5. `android:usesCleartextTraffic="true"` → `android:networkSecurityConfig="@xml/network_config"`
is cosmetic, not hardening.** `network_config.xml` is unchanged from the
archive version and contains `<base-config cleartextTrafficPermitted="true" />`,
which permits cleartext HTTP to *every* domain — identical behavior to the
attribute it replaced. If the tablet talks to Home Assistant or an MQTT
broker over plain HTTP/TCP on the LAN, credentials still go out in the
clear, same as before this fork. Not a regression Darknetzz introduced
(pre-existing in the archive), but don't read the manifest change as a TLS
fix — nothing here enforces TLS. If credential confidentiality on the LAN
matters, that's a configuration/deployment decision (HTTPS + valid cert on
the HA side), not something this diff changes.

**6. Dependencies are unremarkable.** New/bumped coordinates (Gradle 9.1.0,
AGP 8.5.2, Kotlin 2.0.21, Dagger 2.52, `com.google.mlkit:barcode-scanning:17.2.0`,
`com.google.mlkit:face-detection:16.1.6`, `google-services:4.4.2`) are all
canonical `google()`/`mavenCentral()` artifacts from their expected
publishers — nothing typosquatted or pulled from a third-party/unknown repo.
Not independently verified by running a full Gradle resolve (not warranted
for this review), but nothing in the coordinates or repositories block is
suspicious. Neither the archive nor this fork pins a `distributionSha256Sum`
on the Gradle wrapper or uses dependency verification — a pre-existing gap,
worth adding to *our* fork as cheap supply-chain hardening, but not something
Darknetzz broke.

**7. No build-time code execution added.** No `exec`, `ProcessBuilder`, or
shell-out in any `.gradle`/`.gradle.kts` file in either branch. `.gitignore`
gained an entry for `build-and-copy.ps1` (a local convenience script) — it's
gitignored, not committed, and not invoked by any Gradle task, so it has no
effect on our build.

**8. No permission or manifest surface changes.** The `uses-permission` list
is byte-for-byte identical to the archive.

## Incomplete work-in-progress (matches the author's own warning)

**9. Vision API and ML Kit both present.** `play-services-vision:20.1.3` (the
deprecated API) is still a dependency alongside the new
`mlkit:barcode-scanning`/`mlkit:face-detection`, with a comment acknowledging
"migration in progress." Not a security issue, just unfinished cleanup — extra
APK weight and two competing detection paths.

**10. Recreated WebView drops the hardware-acceleration preference.** The
normal WebView creation path respects `configuration.hardwareAccelerated`,
choosing `LAYER_TYPE_HARDWARE` or `LAYER_TYPE_SOFTWARE` accordingly. The
renderer-crash recovery path (`onWebViewRenderProcessGone`, finding #2) always
forces `LAYER_TYPE_SOFTWARE` regardless of that preference. Cosmetic/behavioral
inconsistency after a crash-recovery, not a vulnerability — worth a follow-up
patch but not blocking.

**11. Firebase Analytics/Crashlytics/BoM dependencies are still unconditional
`implementation` entries**; only the *plugin application* (`google-services`,
`firebase-crashlytics`) is now gated on `google-services.json` existing. The
SDKs compile into every build regardless. Without the config file and without
the plugin applying, Analytics has nothing to initialize against and is
effectively inert — but a telemetry SDK sitting in a build for an app that
holds LAN/HA credentials is worth knowing about rather than assuming absent.
Not a live problem as long as we don't add `google-services.json`.

**12. Lint is unconditionally disabled** (`tasks.configureEach { t -> if
(t.name.startsWith('lint')) t.enabled = false }`), worked around a real JDK 25
lint-worker bug. This removes Android Lint's static analysis (including its
own security checks) from our safety net until upstream fixes the underlying
Gradle/JDK issue or someone re-scopes the disable. Not a vulnerability by
itself, just a reduced signal we should be aware we're not getting.

## Renderer-crash recovery: reproduced, and it does not always hold (2026-08-30)

The WebView renderer-crash recovery verified in an earlier feature (see
CHANGELOG.md, 2026-08-30 "WebView renderer-crash recovery, service handler leak
fix") turns out to be incomplete. This section documents a reproducible on-device
trigger and the root cause of why recovery sometimes fails.

### The trigger

`adb shell am crash <target>` injects a `RemoteServiceException` ("shell-induced
crash") into a running process. Two forms were tested against the
`xyz.wallpanel.app.kmb.dev` (dev) build on the physical tablet:

- **By package name** (`adb shell am crash xyz.wallpanel.app.kmb.dev`): this is
  the form that produced the historical evidence below. Android resolves the
  package name against all processes associated with that app's uid, including
  isolated WebView renderer child processes bound via `bindService` -- so this
  form can hit either the main process or an associated renderer process,
  non-deterministically, depending on which are alive at call time.
- **By explicit PID, targeting the renderer specifically**: find the renderer's
  PID via `adb shell dumpsys activity services`, which lists a `ServiceRecord`
  under the owning app's component
  (`xyz.wallpanel.app.kmb.dev/org.chromium.content.app.SandboxedProcessService0:N`)
  followed by `app=ProcessRecord{... <pid>:com.google.android.webview:sandboxed_process0:...}`.
  `am crash <pid>` on that PID deterministically kills the renderer, not the
  main process.

### Two outcomes observed from the same trigger technique

- **App abort** (package-name form, 2026-08-30 09:55:14-09:55:16): renderer PID
  29137 received the shell-induced `RemoteServiceException` at 09:55:14.323, then
  at 09:55:16.408 the main app process (pid 28922) aborted with:
  ```
  Abort message: '[FATAL:third_party/crashpad/crashpad/client/crashpad_client_linux.cc:744]
  Render process (29137)'s crash wasn't handled by all associated  webviews,
  triggering application crash.
  ```
  This is byte-for-byte the same abort signature as the original organic crash
  captured from the TheTimeWalker build on 2026-08-26 (`logs/crash-history.log`)
  that motivated the recovery fix in the first place -- same terminal state,
  same Crashpad message. Confirmed representative of a real renderer crash, not
  an artifact of the injection method.
- **Clean recovery** (explicit-PID form, 2026-08-30 11:14:57): renderer PID 7128
  received the same kind of shell-induced crash (`Abort message: '[FATAL:...
  java_exception_reporter.cc:93] Uncaught exception'`, tid 7128), and the app's
  main process (pid 7014) was unaffected -- no pid change, no abort. The
  renderer's `ServiceRecord` was observed to move from
  `SandboxedProcessService0:0` to `:1` immediately after, confirming
  `BrowserActivityNative.onWebViewRenderProcessGone` ran and rebuilt the WebView.
  This also answers whether a shell-induced kill even delivers
  `onRenderProcessGone` at all: **yes** -- the only code path that produces a new
  renderer service instance is that callback, so its being reached is direct
  evidence the callback fired, not speculation about Android internals.

  One caveat: an organic OOM-kill likely arrives with `RenderProcessGoneDetail
  .didCrash()=false` where a shell-induced kill arrives with `didCrash()=true`.
  `InternalWebClient.onRenderProcessGone` does not branch on `didCrash()`, so
  this difference does not change recovery behaviour here -- the repro is
  representative for this codebase's recovery logic either way.

### Root cause of the intermittency: an unprotected second WebView

A full inventory of every `WebView` instantiation in the codebase:

| WebView | Location | `WebViewClient` | `onRenderProcessGone` |
|---|---|---|---|
| Main browser | `activity_browser.xml:35`, bound in `BrowserActivityNative.kt:373` | `InternalWebClient` (`BrowserActivityNative.kt:400`) | **Yes** -- `InternalWebClient.kt:113-123`, returns `true`, triggers rebuild |
| Post-crash replacement | Created in `BrowserActivityNative.kt:299` (`onWebViewRenderProcessGone`) | Same `InternalWebClient`, reattached at `configureWebViewClient()` | **Yes** -- inherits the same handler |
| Screensaver | `dialog_screen_saver.xml` (6 layout variants), bound in `ScreenSaverView.kt:199` | Anonymous `object : WebViewClient() { ... }` | **No** -- no override present, falls back to the framework default (`return false`) |
| `CustomWebView` | `ui/views/CustomWebView.kt` | `WebClientRenderWrapper` (has the override) but wiring is **commented out** (`CustomWebView.kt:48`) | Dead code, never instantiated anywhere |

Chromium's WebView implementation shares one OS-level renderer process across
all `WebView` Java objects live in the same app process (by default, without
per-site process isolation). When that shared renderer crashes, Crashpad
invokes `onRenderProcessGone` on every attached `WebViewClient`; the crash is
only considered "handled" if **all of them** return `true`. The abort message's
plural wording -- "wasn't handled by all associated **webviews**" -- is Chromium
naming this exact condition. If the screensaver's WebView (default handler,
implicitly returns `false`) is alive at the moment the shared renderer crashes,
the crash is unhandled regardless of the main browser's correct handler, and
the whole app aborts. If the screensaver was never shown, only the protected
main WebView is attached, and recovery succeeds.

Debug builds force `configuration.hasClockScreenSaver = true`
(`BrowserActivityNative.kt:112`), and the screensaver's default inactivity
timeout is 30s (`Configuration.kt:292`, `key_screensaver_inactivity_time`
default `30000`). This matches the observed intermittency: crashes triggered
immediately after a fresh launch (screensaver not yet shown) recovered cleanly;
the crash that produced the historical abort was preceded by several minutes of
idle test activity, consistent with the screensaver having appeared by then.
This was confirmed live: a rapid-fire loop of renderer-crash cycles (each a
few seconds apart) survived cleanly every time, because it never left the app
idle long enough for the screensaver to mount. Once `scripts/smoke-renderer-crash.sh`
was changed to wait 35s untouched (past the 30s default) before each crash,
it reliably reproduced the exact same abort signature on the first cycle:
```
Abort message: '[FATAL:third_party/crashpad/crashpad/client/crashpad_client_linux.cc:744]
Render process (10467)'s crash wasn't handled by all associated  webviews,
triggering application crash.
```
This closes the loop: idle time is the discriminating variable, matching the
screensaver's inactivity-gated mount exactly. Directly confirmed by inspecting
`dumpsys window windows` after a 35s untouched wait (no wake beforehand, since
waking the device dismisses the screensaver): two distinct `Window` entries are
present under the app's package/token, not one -- the main activity's content
window plus the screensaver dialog's window. The unprotected second WebView is
provably mounted at the moment the crash trigger fires.

### Production exposure -- not yet known

`hasClockScreenSaver` is forced `true` on debug builds only
(`BrowserActivityNative.kt:112`, gated on `BuildConfig.DEBUG`). Whether the
**production** panel (`xyz.wallpanel.app.kmb`) is exposed to this exact failure
depends on whether its screensaver is enabled in its own persisted settings,
which live in app-private SharedPreferences and are not readable from outside
the app via adb -- this needs checking in the app's Settings UI on the device.
If the production screensaver is enabled, the unprotected WebView is mounted
during the panel's dominant real-world state (idle on the wall, which is most
of the time), meaning current recovery protects the rare actively-in-use case
and not the one that matters for a kiosk display. If it's disabled, this
failure mode is effectively dev-only until/unless it's turned on. This
materially changes how urgent the `ScreenSaverView.kt` fix is and was not
determined in this investigation.

**Not fixed in this task** (out of scope, no app-code changes made): wiring
`onRenderProcessGone` on the screensaver's `WebViewClient` in
`ScreenSaverView.kt` -- the same pattern as `InternalWebClient`, either by
having it call back to rebuild the screensaver's WebView or, more simply,
returning `true` and letting the screensaver dialog be dismissed/recreated on
next show. `scripts/smoke-renderer-crash.sh` (see CHANGELOG) exercises this gap
and is currently expected to fail.

## Recommendation

**Proceed on the Darknetzz base**, with finding #1 (deferred-init handler not
cancelled in `WallPanelService.onDestroy()`) fixed before we install a build
on the tablet. Nothing else here rises to "revert before use" — the rest is
either a genuine fix directly relevant to our crash problem (#2), cosmetic
non-issues (#5–8), or acknowledged unfinished work consistent with the
"not yet fully working" warning in Darknetzz's README (#9–12), none of which
touch trust boundaries, credential storage, or network security in a way that
makes this base worse than the archive it replaces.

No alternative base is warranted: the archive itself is unmaintained and
capped at Android 13, and `000-i/wallpanel-plus` was explicitly out of scope
for comparison in this review (fetched, not diffed) and not proposed as a
base by anyone on this task.

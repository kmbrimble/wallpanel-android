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

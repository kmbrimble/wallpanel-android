# Changelog

## [Unreleased]

### Plan — 2026-09-02 — dagger.android -> Hilt migration

Motivation: `android.builtInKotlin=false`/`android.newDsl=false` (needed for kapt) are
removed in AGP 10.0; kapt->KSP for `dagger-android-processor` is a closed avenue (no KSP
build upstream). Hilt supports KSP today, so it's the route off kapt. Also deletes a lot
of Dagger boilerplate.

Verified against master (Dagger 2.59.2, minSdk 26, compileSdk 35, AGP 9.3.2): 15
`@ContributesAndroidInjector` targets, 1 base activity (`BaseBrowserActivity`, 1 leaf:
`BrowserActivityNative`), 1 base fragment (`BaseSettingsFragment`, **8** leaves —
Settings/Camera/Mqtt/Http/Motion/Face/QrCode/Sensors — the brief said 7, grep says 8),
1 service (`WallPanelService`), 1 receiver (`BootUpReceiver`, no `@Inject` fields ->
needs no Hilt annotation), 1 `@ViewModelKey`-bound ViewModel (`DetectionViewModel`, used
by `LiveCameraActivity`).

Plan (per Dagger's own incremental migration guide, building between stages):
1. Add Hilt 2.59.2 gradle plugin + deps (paired with Dagger 2.59.2), remove dagger-android
   deps. `WallPanel` -> `@HiltAndroidApp`, drop `DaggerApplication`.
2. Migrate `ApplicationModule`/`ActivityModule` to `@InstallIn(SingletonComponent::class)`
   (single-component collapse is a semantic no-op here, already verified in CLAUDE.md).
3. Activities: `BrowserActivityNative`, `SettingsActivity`, `LiveCameraActivity` ->
   `@AndroidEntryPoint`. `BaseBrowserActivity` stops extending `DaggerAppCompatActivity`,
   becomes plain `AppCompatActivity`, no annotation (Hilt rejects it on abstract classes;
   member-injection walks the leaf's superclass chain).
4. Fragments: all 8 `BaseSettingsFragment` leaves -> `@AndroidEntryPoint`.
   `BaseSettingsFragment` -> plain `PreferenceFragmentCompat`, no annotation.
5. `WallPanelService` -> `@AndroidEntryPoint`. `DetectionViewModel` -> `@HiltViewModel` +
   `@Inject constructor`; `LiveCameraActivity` switches from `DaggerViewModelFactory` to
   `by viewModels()`.
6. Delete: `ApplicationComponent`, `AndroidBindingModule`, `DaggerViewModelFactory`,
   `ViewModelKey`, `DaggerViewModelInjectionModule`, `ApplicationScope`, `ActivityScope`,
   and the already-dead `ServiceSubcomponent`/`ServicesModule.java`.

Explicitly out of scope: switching `dagger-compiler`/`hilt-compiler` from kapt to KSP —
separate change once Hilt itself is verified working under this project's
`android.newDsl=false` AGP 9.3.2 setup (unverified going in, flagged as the likeliest
hard blocker by advisor review).

Verification: `assembleProdDebug`, unit tests, lint, `smoke-device.sh`,
`panel-render-probe.sh`, then a full on-device walk of every injected screen (all 8
settings sub-screens, About, browser activity, live camera view) since a missed
`@AndroidEntryPoint` compiles clean and only fails at runtime with null fields — no
automated check catches that.

### BLOCKED — 2026-09-02 — dagger.android -> Hilt migration hits a build-tooling wall

All code changes from the plan above were made (`WallPanel` -> `@HiltAndroidApp`,
`BrowserActivityNative`/`SettingsActivity`/`LiveCameraActivity` -> `@AndroidEntryPoint`,
all 8 `BaseSettingsFragment` leaves -> `@AndroidEntryPoint`, `WallPanelService` ->
`@AndroidEntryPoint`, `DetectionViewModel` -> `@HiltViewModel` + `by viewModels()`,
`ApplicationModule`/`ActivityModule` -> `@InstallIn(SingletonComponent::class)`,
`ApplicationComponent`/`AndroidBindingModule`/`DaggerViewModelFactory`/`ViewModelKey`/
`DaggerViewModelInjectionModule`/`ApplicationScope`/`ActivityScope`/
`ServiceSubcomponent`/`ServicesModule.java` all deleted).

**Confirmed hard blocker, not a code bug — advisor's predicted risk turned out to be
the real one.** The Hilt Gradle plugin (2.59.2, paired with Dagger 2.59.2) applies
without error and registers its tasks (`hiltAggregateDeps*`, `hiltJavaCompile*`,
`hiltSync*`), but `kaptProdDebugKotlin` fails on every entry point with `[Hilt]
Expected @AndroidEntryPoint to have a value. Did you forget to apply the Gradle
Plugin?`. Inspected the generated kapt stub directly
(`build/tmp/kapt3/stubs/prodDebug/.../WallPanel.java`): the annotation is emitted as
literal `@dagger.hilt.android.HiltAndroidApp()` with an empty value — the Hilt Kotlin
compiler plugin that's supposed to fill that value in during Kotlin compilation never
ran, or its output never reached the kapt stub-generation task. Same result whether
invoked via `compileProdDebugKotlin`, `assembleProdDebug`, or
`hiltAggregateDepsProdDebug` directly — not a task-ordering fluke.

**Root cause, to the extent verifiable without upstream source access:** this project
runs `android.newDsl=false` + `android.builtInKotlin=false` (gradle.properties:36-37),
restoring the legacy AGP variant API and classic `kotlin-android` plugin specifically
so kapt keeps working under AGP 9 — a combination CLAUDE.md already documented as
necessary but unusual. The Hilt Gradle plugin's value-injection mechanism appears to
depend on Kotlin/AGP wiring that this dual opt-out disrupts. No configuration flag in
Hilt's public Gradle DSL was found to force the transform to run independently of that
wiring.

**Per the feature brief's own instruction, stopping here rather than fighting it.**
This is a real, reproducible finding: Hilt 2.59.2 does not currently work in this
project's build under `android.newDsl=false`. All migration code is committed on
`feature/hilt-migration` (not merged to `master`) for whoever picks this back up.
Options going forward, none attempted:
1. Wait for kapt->KSP to become viable for this project generally (closed avenue today
   per CLAUDE.md, but Hilt's own KSP path might behave differently — untested, KSP was
   explicitly out of scope for this feature anyway).
2. File/search for this exact failure against `google/dagger` and AGP 9's `newDsl`
   flag — may already be a known, tracked incompatibility.
3. Try an older Hilt/Dagger pairing to see if the value-injection mechanism changed
   between versions — not attempted; no evidence yet that it's version-specific rather
   than AGP-9-specific.

Not promoted, not merged. `master` is untouched.

### 2026-09-02 — Post-minSdk cleanup tail (0.12.0 Build 0-kmb.7)

Five items unlocked by the minSdk 19->26 raise (kmb.6), plus the previously-unmerged
`feature/dependency-sweep` branch folded in as part of the same pass:

- Merged `feature/dependency-sweep` (Gradle 9.7.1, AGP 9.3.2, Kotlin 2.2.21, Dagger 2.59.2),
  then re-swept AndroidX to current stable now that minSdk 26 lifts the version caps that
  branch had recorded: appcompat 1.8.0, material 1.14.0, navigation 2.10.0, lifecycle 2.11.0.
  navigation 2.10.0 forced compileSdk 34->35 (targetSdk unchanged at 34, per policy).
- Removed 5 dead `SDK_INT >= O` (API 26) branches, now always-true: `BaseBrowserActivity`
  startup, `ScreenSaverView`/`InternalWebClient`'s `onRenderProcessGone`, and
  `NotificationUtils`' channel/notification builders. Deleted the resulting dead
  `getAndroidNotification()` fallback.
- Dropped `legacy-support-v13`/`legacy-support-v4`/`legacy-preference-v14`; replaced
  `androidx.legacy.widget.Space` with plain `Space` in `fragment_about.xml`. Made two
  transitive dependencies explicit (`SwipeRefreshLayout`, `LocalBroadcastManager`) that were
  riding along via the removed legacy artifacts.
- Removed obsolete `android.enableJetifier=true`.
- Bumped `constraintlayout` 2.1.4 -> 2.2.2 (was pinned only for minSdk 19).
- Fixed `InternalWebClient.dialogUtils`: passed through the constructor instead of relying on
  never-populated `@Inject` field injection (the class is manually constructed, not built
  through Dagger) - was a live `UninitializedPropertyAccessException` on any SSL error.
- CLAUDE.md's cleanup-tail notes corrected: previously cited 8+1 SDK_INT sites and
  dependency-sweep's post-bump versions instead of master's actual state.

Lint delta: 0 Fatal (unchanged), 9 Error (was 8 - new `KotlinNullnessAnnotation`/
`NotificationPermission`/`ForegroundServiceType` findings surfaced by the AGP bump, none
Fatal, not chased), 387 Warning (`ObsoleteSdkInt` 14->6 from the SDK_INT cleanup).

### 2026-09-02 — Fix the renderer-crash wedge (0.12.0 Build 0-kmb.5)

A single injected renderer crash reproducibly wedged the panel: `onWebViewRenderProcessGone`
rebuilt the WebView correctly, but Home Assistant's frontend never re-initialised — the
panel sat on HA's own loading screen indefinitely.

**Root cause: not a missing reload.** `initWebPageLoad()` already reloaded the page on every
rebuild; that part worked. The actual bug was in `BrowserActivityNative.configureWebSettings`:
`WebSettings` was cached in an activity-lifetime field, assigned once behind an
`if (webSettings == null)` guard. `WebSettings` is per-WebView-instance, not shared, so after
`onWebViewRenderProcessGone` destroyed the old WebView and built a new one, every
`javaScriptEnabled = true` / `domStorageEnabled = true` call kept mutating the destroyed
WebView's settings object. The new WebView was left on Android's defaults — JavaScript and
DOM storage both disabled — so HA's JS frontend never booted, while its CSS-driven loading
spinner kept animating.

**Fix:** `configureWebSettings` now reads `webView.settings` into a local `val` on every call
instead of caching it. Checked for the same pattern elsewhere (any field holding a
WebView-instance-owned object not re-established on rebuild) — found none; `webView` itself,
both client objects, and `ScreenSaverView`'s separate WebView were all already correct.

Verified with 3 consecutive `smoke-renderer-crash.sh` passes (35s idle wait intact),
`smoke-device.sh`, and `panel-render-probe.sh`. Version bumped to `0.12.0 Build 0-kmb.5`
(versionCode 12005) per the existing `+N`/`-kmb.N` bump convention in `build.gradle`.

### 2026-08-30 — Remove Firebase, Crashlytics and LeakCanary from the build

There is no `google-services.json` in this project, so Firebase had nothing to talk to,
yet `FirebaseInitProvider` was still a published content provider on the running
production app — init code on every launch, on a device that holds our Home Assistant
credentials, for zero benefit.

**What Darknetzz's conditional already covered, and what it didn't.** The
`if (file('google-services.json').exists())` block at the bottom of
`WallPanelApp/build.gradle` gated only *plugin application* — the `google-services` and
`firebase-crashlytics` Gradle plugins. The Firebase **SDK dependencies** were declared
unconditionally, and it is the SDK, not the plugin, that contributes
`FirebaseInitProvider` to the merged manifest. So the conditional never prevented
Firebase from shipping or initialising; it only stopped the build-time config processing.

Removed:

- Root `build.gradle`: the `firebase-crashlytics-gradle` and `google-services`
  buildscript classpaths, which existed only to serve the conditional block.
- Module deps: `firebase-analytics:21.1.1` (declared a second time, buried mid-way
  through the lifecycle block), `firebase-core`, the `firebase-bom` platform, the BoM
  `firebase-analytics`, and `firebase-crashlytics-ktx`.
- The conditional `apply plugin` block itself.
- `CrashlyticsDebugTree.kt` and `CrashlyticsTree.java`, both deleted whole. The four
  `com.google.firebase.*` imports in `BrowserActivityNative.kt` were already dead — the
  file had no body references to them.
- The `-dontwarn com.google.firebase.**` proguard rule.

**Release builds now plant no Timber tree, deliberately.** The only release tree was
`CrashlyticsDebugTree`, which wrote exclusively to Crashlytics and never to logcat — so
release Timber output already went nowhere. Planting nothing preserves the existing
behaviour exactly. `WallpanelDebugTree` was *not* planted in release to compensate: that
would add prod logcat volume the previous commit just spent effort cutting.

**LeakCanary was already `debugImplementation`** and was never in the shipped production
APK — `dumpsys package xyz.wallpanel.app.kmb | grep -i leak` returns nothing, and the
production provider list has no LeakCanary entry. The monkey that selected
`LeakLauncherActivity` was running against the **dev** app, which is a debug build. It
has been removed entirely rather than left on debug: its only observed effect in this
project has been costing a diagnostic session, no leak report has ever been read, and it
publishes a launchable activity that the smoke monkey keeps finding. Reinstating it is
one line if a real leak hunt ever needs it.

`MlKitInitProvider` remains in the provider list. It comes from ML Kit (camera), which is
explicitly out of scope here. The `com.google.firebase.components:*` metadata entries
still in the manifest are ML Kit component registrars for the same reason — ML Kit is
built on firebase-components. Neither is Firebase itself.

**Measured on the panel, same dashboard, both samples at comparable process uptime:**

- APK (arm64-v8a split, signed): 19,691,442 → 19,218,883 bytes, **−461 KB (−2.4%)**.
- Published content providers: `MlKitInitProvider`, `FirebaseInitProvider`,
  `InitializationProvider` → `MlKitInitProvider`, `InitializationProvider`.
  `FirebaseInitProvider` is confirmed gone from the release artifact's manifest, not just
  from the running app.
- TOTAL PSS: **no improvement, and the comparison is not valid.** Before 227–231MB
  (pid 20761, 27:56 uptime); after 447–450MB (pid 25234, 28:56 uptime). Total PSS went
  *up* by ~220MB, and none of that movement is attributable to this change. The two
  samples differ in ways that swamp anything Firebase could contribute: GL mtrack
  33.8MB → 225.9MB and EGL mtrack 31.5MB → 55.9MB, with 3 live WebViews in the before
  sample against 2 in the after, and the before-process had been through four renderer
  crashes while the after-process was a clean start. **Treat the PSS before/after as a
  null result at best.** Firebase was never a plausible contributor to a 116–174MB
  working set, and this measurement does not show that it was.

  The one component that moved in the right direction is Code PSS, 58.2MB → 43.3MB
  (.apk mmap −6.1MB, .so −3.2MB, .dex −2.1MB, .jar −2.6MB). That is the right shape for
  deleting the Firebase SDKs, but it is **also confounded** by the differing WebView
  count and renderer history between the two samples, so it should not be quoted as a
  clean −14.8MB win.

  **The memory hypothesis for this change is disproven.** Init providers were the
  named suspect for the panel's footprint after camera capture rate was ruled out in
  kmb.3. They are now ruled out too: removing `FirebaseInitProvider` shrank the APK
  and the provider list and did nothing for memory. Both hypotheses are recorded as
  tested-and-rejected in `CLAUDE.md` so neither gets retested.

  **The dominant term is GL mtrack — GPU memory for WebView compositing — measured at
  225.9MB in a single process**, against 43.3MB of code and 31.8MB of Java heap. That
  is where the panel's footprint actually lives, and where any further memory work
  should start. This change was still worth making on the grounds it was actually
  argued on: Firebase init code no longer runs on every launch on a device holding
  Home Assistant credentials. It was never going to be a memory fix.

### 2026-08-30 — Known gap: the smoke scripts do not detect a hung app

Recorded, not fixed. Neither `smoke-device.sh` nor `smoke-renderer-crash.sh`
distinguishes a working panel from a functionally hung one. Both assert process
liveness, window focus, and a bound renderer — and all three were true while the panel
displayed a dead Home Assistant loading screen: the app process was alive and GCing
every few seconds, focus was held, and renderer 24949 stayed bound from 19:44:48 until
it was force-stopped at 19:46:49. `smoke-renderer-crash.sh` passed on that exact build
minutes earlier.

Deliberately left open. The undecided question is what a liveness check should assert —
page-load completion, a DOM probe, the MQTT heartbeat — and building one before that is
settled would just add a second check that passes on a dead screen.

### 2026-08-30 — Cut logcat volume at source, and add retention

The capture was writing ~250MB/h, almost all of it MediaTek camera HAL chatter. The tag
filters only silenced `Camera3-OutputStream`, but the HAL logs across a dozen tags per
frame.

Silenced 15 more tags: `AeAlgo`, `GPUIMAGEROTATE`, `S_Bokeh`, `ifunc_cam_dmax`, `cam_dfs`,
`MtkCam/TPI_S_FB`, `GPUAUX`, `NormalPipe`, `LMVDrv`, `Hal3ARaw`, `MtkCam/fdNodeImp`,
`tsf_core`, `CompositionEngine`, `libPerfCtl`, `hwcomposer`. Deliberately **no `*:S`
catch-all** — the point is silencing known noise while still capturing unexpected tags.
The crash buffer and `adbd` are untouched.

Tag names have to match exactly or the filter silently does nothing, so they were taken
from a histogram of real capture and confirmed against it afterwards: in `threadtime`
output the trailing colon is the format's delimiter and tags are padded to 8 characters —
neither is part of the tag. Re-running the histogram after the change shows all 15 gone,
with `adbd`, `BatteryService`, `WindowManager`, `crashpad`, `AndroidRuntime` and the rest
still captured.

Retention: the supervisor loop now deletes `logs/wallpanel-*.log` older than 7 days each
time round. No cron needed — the loop is the only thing guaranteed to be alive whenever
logs are growing. Verified in a scratch directory that it removes only aged
`wallpanel-*.log` files and leaves `capture-supervisor.log` and recent captures alone.

**Measured, not estimated** — both windows over 16+ minutes of steady-state capture:

| | write rate |
|---|---|
| before | 241.5 MB/h (16.1 min) |
| after | 6.39 MB/h (16.8 min) |

A 97.4% reduction, ~38x. Daily volume goes from ~5.8GB to ~150MB, so the 7-day retention
window costs about 1GB rather than 40GB.

### 2026-08-30 — Make the logcat capture idempotent and self-restarting

The continuous capture had died twice in one day for the same reason: it runs as a plain
background process, so a container restart kills it and nothing brings it back. That left
no record of how the panel behaves in normal use — exactly the evidence needed to tell
whether renderer crashes still happen organically now that the fix is verified.

- `logcat-capture.sh` now guards on a PID file in `logs/capture.pid`, verified through
  `/proc` (`ps` is not installed in this container) and matched against the command line
  so PID reuse can't produce a false positive. Running it twice is a no-op, which is what
  makes a start hook safe.
- It kills its `adb logcat` child on exit. Killing only the supervisor previously left an
  orphaned reader still appending to its file; the next start then ran a *second* reader
  against the same device, doubling the write rate and splitting the record across two
  files. This was observed for real while testing, not theorised.
- Signal handling: a trap that only cleaned up let bash resume the loop afterwards, so the
  supervisor survived its own SIGTERM having already deleted its PID file — and the next
  start, seeing no owner, ran a second supervisor. Also observed for real. `INT`/`TERM` now
  exit explicitly.
- `--status` reports whether a capture is live and which file it's writing.
- `.claude/settings.json` adds a `SessionStart` hook that fires the script unconditionally;
  the PID guard makes that safe.

**Caveat, stated rather than buried:** the hook restores the capture when a Claude session
starts in this project — it does not make the capture survive a container restart on its
own. Nothing in the container can: there is no cron, systemd or supervisord, and the
container's own start-up is not editable from inside. This shortens the outage from
"until someone notices" to "until the next session", which is the best available here.

Not addressed: the logs are unbounded. The 11:01-13:00 capture alone was 501MB (~250MB/h,
~6GB/day) and nothing rotates or expires them. Disk is fine for now (597G free) but this
will need retention.

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

**PROMOTED** as 0.12.0 Build 0-kmb.3 (versionCode 12003).

Verification was originally blocked: `smoke-renderer-crash.sh` could not run against the
`.dev` app, which cannot obtain a WebView renderer on this tablet. That blocker was
resolved separately by moving the renderer test onto the production app (see that entry);
this branch was then re-verified against the signed release artifact.

- `scripts/smoke-device.sh`: PASS
- `scripts/smoke-renderer-crash.sh` (prod-based, idle wait intact): PASS, 4/4 cycles on
  the signed versionCode 12003 candidate

**Action still needed on the panel.** Post-promotion the panel measures 14.8 fps, not 10:
changing an XML default does nothing where a value is already persisted, and prod has
`setting_camera_fps` stored as 15 from before. It is a release build, so its shared_prefs
cannot be written over adb. Set **Camera FPS to 10** in the app's Camera Settings to pick
up the new rate. This also confirms `CameraFpsPin` is live on production: 15 requested
resolves to the fixed `[15000,15000]` range and delivers 14.8 fps, exactly as the
selection logic predicts.

For the record, the dev app's renderer fault was investigated and ruled out as unrelated
to this change — it reproduced identically on unmodified master, and a camera-only diff
cannot affect WebView renderer processes. Screen-asleep, screensaver config, a reboot, the
production app holding a renderer slot, and system-wide WebView breakage were all
eliminated. The cause is unexplained and deliberately closed; see CLAUDE.md.


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

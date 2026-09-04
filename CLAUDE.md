# WallPanel (kmbrimble fork)

Android kiosk browser for a Home Assistant dashboard, running on a wall-mounted
tablet on the home LAN. The app holds HA credentials (and optionally MQTT
broker credentials), so trust in every change matters more than usual for a
hobby project.

Single Gradle module `:WallPanelApp` (`settings.gradle`), package
`xyz.wallpanel.app`, Kotlin with some legacy Java, Hilt + KSP. App code sits
under `WallPanelApp/src/main/java/xyz/wallpanel/app/`: `network/` (the
foreground service, MQTT, the HTTP server), `ui/activities` + `ui/fragments`
(browser and settings), `modules/` (camera, motion, sensors, TTS),
`persistence/Configuration.kt`, `utils/`, `di/`. Device tooling lives in
`scripts/` and `logcat-capture.sh`.

## Why this fork exists

- **TheTimeWalker/wallpanel-android** is the original project. Maintained
  2022-2025, archived May 2025. Last SDK bump was to Android 13 in Oct 2023.
  Our tablet currently runs this build and crashes frequently — that's the
  problem we're fixing.
- **Darknetzz/wallpanel-android** forked it after the archive and modernised
  the build: Gradle 9.x, Kotlin 2.x, current AGP, JDK 17-25, Android SDK 34,
  Firebase/Play Services made conditional on `google-services.json` being
  present, and prod/dev product flavours. Darknetzz's own README states the
  fork is "not yet fully working" and some features may be unfinished or
  unstable — treat anything touching network/TLS/storage with extra scrutiny
  until verified.
- **This fork (kmbrimble/wallpanel-android)** is forked from Darknetzz, not
  from the archive, because Darknetzz did the SDK/toolchain modernisation work
  we need. We build and maintain our own fixes on top of it.

See `REVIEW.md` for the full security/reliability diff assessment between the
archive baseline and Darknetzz's master, and its go/no-go recommendation.

## Remotes

- `origin` — kmbrimble/wallpanel-android — this fork, where we push our work.
- `upstream` — Darknetzz/wallpanel-android — our fork's parent; pull
  Darknetzz's fixes from here.
- `archive` — TheTimeWalker/wallpanel-android — the archived baseline
  everything descends from. Kept for history/diff comparison only, not for
  merging.
- `plus` — 000-i/wallpanel-plus — a parallel fork, kept around for future
  comparison only. **Do not merge anything from it** without a separate
  review.

## Code review

Calibration for `code-diff-reviewer`, `code-audit` and `code-security-audit`.
All three are repo-scoped and advisory; the four items below are what this
repository cannot tell them about itself.

**Exposure — LAN-only, with an unauthenticated control surface on the LAN.**
The panel is a Lenovo TB-J616F at `192.168.0.52` on the flat home LAN. It is
**not** in the Cloudflare tunnel ingress list, is behind no reverse proxy, and
has no port forward — nothing outside the LAN can reach it. On the LAN it
exposes:

- **HTTP on TCP 2971**, `AsyncHttpServer` started in `WallPanelService.startHttp`
  (`:445`), port from `default_setting_http_port`. On this panel the REST
  endpoints are **on** (`httpRestEnabled`) and MJPEG is **off**. Both default to
  `false` in resources, so the repo alone reads as "no listener is ever started" —
  that is wrong for this deployment.
- **No authentication on it at all** — no token, no TLS, no origin check.
  `POST /api/command` reaches `processCommand`, which includes `eval` →
  `BROADCAST_ACTION_JS_EXEC` → `webView.evaluateJavascript`
  (`WallPanelService.kt:747` → `BaseBrowserActivity.kt:85` →
  `BrowserActivityNative.kt:229`), so anything on the LAN can run arbitrary
  JavaScript inside the authenticated Home Assistant session. Inherited from
  upstream and **accepted for a LAN-only panel — report it as context, not as a
  finding.** It stops being accepted the moment the exposure line above changes.
- **MQTT**, enabled against a LAN broker. The `command` topic
  (`MqttUtils.TOPIC_COMMAND`) feeds the same `processCommand`, so it has
  identical reach, `eval` included.
- **adb over TCP on 5555**, left enabled for the harness (`scripts/adb-device.sh`).

**Modules that own data users rely on.** There is no database, no money, no
quantities and no audit trail here — no Room, no SQLite, no file writes outside
logs. What little state exists is small and physically expensive to lose:

- `persistence/Configuration.kt` — the **only** store, default SharedPreferences.
  Holds the HA dashboard URL, MQTT broker/username/password, and the settings
  PIN. Corrupt or drop it and somebody re-enters all of it by hand on a
  wall-mounted tablet. `settingsCode` (`:37`) runs a one-way, one-shot legacy
  int→string migration **inside its getter**, overwriting the old key on first
  read, with no test over it.
- `utils/ScreenUtils.kt` — writes device-global
  `Settings.System.SCREEN_BRIGHTNESS` / `..._MODE` (`:69`, `:71`, `:84`, `:105`,
  `:132`, `:137`) under `WRITE_SETTINGS`. A bug here changes the tablet, not the
  app: brightness 1 is indistinguishable from a dead panel and needs physical
  recovery.
- `scripts/promote.sh` with `release-out/` — the rollback set. `release-out/` is
  **gitignored**, so the rollback glob points at a directory that does not exist
  in the checkout. It exists on the container, and deleting from it is what
  makes a rollback impossible.

**Infrastructure this repo depends on but does not contain.** All of this is
resolved outside the checkout. "Nothing here implements X" is not a defect for
any of them:

- **Release signing.** There is no `signingConfig` anywhere in Gradle, by design.
  `assembleProdRelease` emits an unsigned APK; `zipalign` + `apksigner` sign it
  out of band using `/projects/wallpanel-release.jks` and
  `/projects/.env.keystore-pass`, both outside the repo. ("Release signing")
- **Android SDK build-tools** at `/root/.android-sdk/build-tools/34.0.0`
  (`aapt2`, `zipalign`, `apksigner`) — baked into the container image and
  referenced directly by `scripts/promote.sh`.
- **`local.properties`** supplies `code`, `hassUrl`, `broker`, `brokerUsername`,
  `brokerPass` to the dev/qa `buildConfigField`s (`WallPanelApp/build.gradle:53-57`).
  Gitignored and normally absent, in which case the helper returns empty strings.
- **The panel's own settings.** HA URL, MQTT broker and credentials, and every
  feature toggle live in on-device SharedPreferences. The resource defaults are
  upstream's (`default_setting_app_launchurl` is `https://wallpanel.xyz`) and say
  nothing about what this panel is actually running.
- **`WRITE_SECURE_SETTINGS` is granted out of band** by `adb pm grant`, per
  install. The manifest declares it; nothing in the repo grants it, and
  `utils/DuraSpeed.kt` silently no-ops without it. ("Deploy and verify")
- **MediaTek DuraSpeed** is a vendor component compiled into this tablet's
  `system_server`. `DuraSpeed.kt` exists only to switch it off; the thing it
  defends against is in neither this repo nor AOSP. ("Deploy and verify")
- **A physical tablet reachable over adb-TCP** at `$WALLPANEL_TABLET_IP`
  (default `192.168.0.52`) is what everything in `scripts/` and
  `logcat-capture.sh` talks to; `.claude/settings.json` starts the capture on
  every session.
- **Hilt's root component is generated outside the KSP output tree**, into
  `build/generated/hilt/component_sources/`. Diffing against
  `build/generated/ksp/` shows five files apparently missing; they are not.
  ("Toolchain notes")
- **There is no CI.** `.github/` holds issue templates and a funding file only.
  Nothing builds, tests, signs or releases on push — every gate is local or
  on-device.

**Test reality — thin, and that thinness is the highest-signal input here.**

- **Actually exercised, branches included:** `CameraFpsPin.chooseRange`, and
  nothing else. `CameraFpsPinTest` covers six cases including the tie-break and
  the empty-input null return. That is the entire unit suite.
- **Happy path only:** `scripts/smoke-device.sh` installs the dev build,
  launches it, waits, throws a monkey at it, and checks pid / window focus /
  service liveness. It proves the app starts and survives random taps; it never
  drives MQTT, the HTTP endpoints, the camera, the settings screens, TTS, the
  screensaver, or any error branch. `scripts/panel-render-probe.sh` proves only
  that pixels are changing.
- **No coverage whatsoever:** all of `network/WallPanelService.kt` (46 KB — HTTP
  server, MQTT, command dispatch), `Configuration.kt` including the PIN
  migration, `ScreenUtils.kt`, `DuraSpeed.kt`, both WebView clients, and the
  whole activity/fragment tree. `BrowserActivityNativeTest` is misnamed — it
  tests `BrowserUtils.parseIntent`, needs a connected device, and is not in the
  release path.
- **Consequence:** a diff touching anything in that last list has, by
  construction, no test exercising its new branch. Both of the defects recorded
  in this file — the cached `WebSettings` renderer-rebuild bug and the
  non-functional `WIFI_MODE_FULL` wifi lock — sat in exactly that untested
  region, and the device path kept passing while they were live. Weight an
  untested changed branch accordingly rather than treating a green smoke run as
  evidence.

## Non-negotiables — read before "fixing" anything

Each of these looks like a bug, a smell, or a tidy-up target. None is. One line
each; the named section or file holds the full story.

**Where this index disagrees with the section it names, the section wins** — it
is the record, this is only the pointer. Changing a constraint means changing
both, in the same commit.

**Do not change, and do not reintroduce:**

- **The tablet routes through Kieren.** The scripted path (`smoke-device.sh` →
  `panel-render-probe.sh` → `promote.sh`) is the one sanctioned automated route
  to the device; anything else that touches it, or could wedge it, goes through
  him first — he is the only physical recovery. Never `pm clear` (it wipes the
  HA config). Never build automation that assumes adb survives a reboot: it
  does not, wireless debugging comes back OFF. ("Deploy and verify")
- **We build and sign our own APKs** — never install a prebuilt APK from any
  release page, CI artifact or third party, even `upstream`'s. ("Standing
  constraint")
- **Keystore and password stay outside the repo** —
  `/projects/wallpanel-release.jks` and `/projects/.env.keystore-pass`. Never
  move or copy either into the repo; no credential is committed anywhere.
  ("Release signing")
- **Never re-add `webSettings.allowFileAccess = true`** (removed in `5281e47`).
  It was **not** inert: `targetSdk` is 34 and AOSP documents the default as
  false when targeting R and above, so the line was actively re-enabling
  filesystem access the platform switches off. Nothing needs it — the only
  local document the app loads is `file:///android_asset/error_page.html`
  (`InternalWebClient.kt:60`), and assets stay readable regardless of the flag.
  **This constraint exists as an absence:** there is no comment in the WebView
  code marking it, so a local-file feature would set it back and nothing would
  object. Its siblings differ and are worth keeping straight —
  `allowFileAccessFromFileURLs` (removed in `0d81701`) genuinely *was* inert, as
  no JavaScript ever runs from a `file://` origin here, and
  `allowUniversalAccessFromFileURLs`, the worst of the three, has never been set
  in this codebase. Keep all three as they are.
- **The 35s idle wait in `scripts/smoke-renderer-crash.sh` is load-bearing** —
  never weaken, shorten or skip it to get a green; it is the only reason the
  screensaver bug was ever caught. The script itself is retired from the release
  path — do not run it unattended. ("Deploy and verify")
- **`screenWakeLock` being a `FULL_WAKE_LOCK` is deliberate**
  (`WallPanelService.onCreate`) — it cannot become a `PARTIAL_WAKE_LOCK`
  (`ACQUIRE_CAUSES_WAKEUP` will not combine with it) and `setTurnScreenOn()` is
  an Activity API a service cannot reach. ("Wake / wifi / keyguard locks")
- **No ABI splits, and do not reinstate them** — there are no native libraries
  in this APK, so the splits produced five byte-identical outputs. ("Release
  signing")
- **Never delete older APKs under `release-out/`** — they are the rollback set
  `promote.sh` depends on. ("Deploy and verify")
- **Never merge anything from the `plus` remote** without a separate review.
  ("Remotes")
- **Do not reinstate mDNS adb discovery** — multicast does not cross this
  container's Docker bridge, so it can only ever return zero services; it read
  as functional while being dead code. ("Deploy and verify")

**Do not assume — verify these before acting on them:**

- **Cleartext HTTP is permitted to every domain**, at
  `WallPanelApp/src/main/res/xml/network_config.xml:4`
  (`<base-config cleartextTrafficPermitted="true" />`). The manifest does not
  say so — it only points at that file (`AndroidManifest.xml:55`), so reading
  the manifest alone gives the opposite impression. Inherited from the archive
  baseline and assessed but never narrowed (`REVIEW.md:57-58`). Tightening it is
  a real change with tablet-facing risk, not a tidy-up — route it through
  Kieren.
- **The kmb release number is a hardcoded literal.**
  `WallPanelApp/build.gradle:129` ends `-kmb.16` while `versionCode` (`:72`) is
  computed, so cutting kmb.17 means editing that string by hand — and the
  release artifact name follows that literal, not `versionName`.
- **`gh` targets `upstream` (Darknetzz) by default in this checkout**, not our
  fork — always pass `--repo kmbrimble/wallpanel-android` on release and tag
  commands. `git push origin <tag>` is unaffected. ("Git workflow")
- **Any DI change needs a per-screen device walk, not just a green build** —
  uninjected fields in the `BaseBrowserActivity` / `BaseSettingsFragment`
  hierarchy compile clean and fail at runtime. ("Modernisation status")
- **The `WRITE_SECURE_SETTINGS` grant is per-install.** It survives
  `adb install -r` and a reboot, but an uninstall drops it with the package —
  re-grant and confirm `granted=true`, or the DuraSpeed wedge risk returns.
  ("Deploy and verify")
- **Anything that must be visible in release logcat uses `android.util.Log`,
  not Timber** — release plants no Timber tree. ("Deploy and verify")

## Build

```
./gradlew assembleProdDebug
```

- **Flavours**: `dev`, `qa`, `prod` (flavour dimension `"default"`). Use `prod`
  for anything installed on the actual tablet; `dev`/`qa` pull build-time
  config (HA URL, MQTT broker/credentials) from `local.properties` via
  `buildConfigField`, which is convenient for local testing but means those
  fields end up in the DEV/QA `BuildConfig` — never install a dev/qa build
  outside a throwaway test device.
- **JDK**: Gradle itself runs on JDK 17-25; compilation is pinned to JDK 17 via
  `java { toolchain { languageVersion = JavaLanguageVersion.of(17) } }` in the
  module. That block *replaced* the KGP-provided `kotlin { jvmToolchain(17) }`,
  which went away with `kotlin-android` in kmb.14 — `compileOptions` and
  `android.kotlin.compilerOptions` pin the bytecode level only, not the compiling
  JDK, so the toolchain is the guarantee and not a duplicate of them.
  **Caveat: 17-target bytecode (major version 61) is verified on a JDK 17 host
  only. The JDK 25 host path is untested, not known-good.**
- **Android SDK**: `compileSdk` 35, `targetSdk` 34, `minSdk` 26. (This line
  previously said `compileSdk` 34 and `minSdk` 19; both were wrong — corrected
  2026-09-02 against `WallPanelApp/build.gradle:60,70`.)
- **No Firebase, Crashlytics or Google Services in this build at all.** The
  plugins and the conditional apply-block are gone; `google-services.json` is
  irrelevant here. (This line previously said the plugins apply conditionally on
  that file — stale, corrected 2026-09-04 against `WallPanelApp/build.gradle`.)

## Tests — what a RED baseline can and cannot mean here

```
./gradlew testProdDebugUnitTest
```

Verified passing on a JDK 17 host, 2026-09-03.

- **Coverage is exactly one class.** `CameraFpsPinTest` exercises
  `CameraFpsPin.chooseRange` — pure JVM logic with no Android dependency. A
  RED-first workflow is therefore only possible for changes whose logic is, or
  can be pulled into, a plain class like that one. When a feature allows that,
  do it that way.
- **For everything else there is no automated harness — say so, do not invent
  one.** Behavioural verification is the device path: `scripts/smoke-device.sh`,
  then `scripts/panel-render-probe.sh` (see "Deploy and verify"). Both touch the
  physical tablet, so both route through Kieren.
- One instrumented test exists — `BrowserActivityNativeTest`, task
  `connectedProdDebugAndroidTest`. It needs a connected device, so the same rule
  applies, and it is not part of the release path.
- Lint: `./gradlew lintProdDebug`. A full per-ID baseline is recorded in
  CHANGELOG.md by commit `39c772a`, measured at HEAD `84c1878` — trace any total
  movement to specific rule IDs against it rather than reporting a bare delta.
  Release builds gate on lintVital (Fatal-severity only) by design
  (`WallPanelApp/build.gradle:61-67`), and every lint task is auto-disabled on
  JDK 25+ hosts (`WallPanelApp/build.gradle:223-226`, lint worker bug).

## Modernisation status — done, verified against `master` 2026-09-02

The Dagger.android → Hilt migration and the post-minSdk-raise cleanup tail are
both **merged and complete**. This section previously described them as planned
or outstanding; that was stale. Verified on `master`:

- **Hilt is in.** `dagger.android` is gone entirely — zero references to
  `dagger.android`, `@ContributesAndroidInjector`, `AndroidInjection` or
  `HasAndroidInjector`; `AndroidBindingModule`, `ServiceSubcomponent` and
  `ServicesModule` no longer exist. `di/` holds only `ActivityModule.java` and
  `ApplicationModule.java`.
- **The AndroidX re-sweep is done, not owed.** Every AndroidX and test artifact
  is at current stable (checked against `dl.google.com` on 2026-09-02):
  appcompat 1.8.0, material 1.14.0, preference-ktx 1.2.1, swiperefreshlayout
  1.2.0, localbroadcastmanager 1.1.0, constraintlayout 2.2.2, vectordrawable
  1.2.0, navigation 2.10.0, lifecycle 2.11.0, test ext-junit 1.3.0, espresso
  3.7.0, runner 1.7.0, orchestrator 1.6.1. **Do not plan another sweep** — there
  is nothing to bump. `constraintlayout` is no longer pinned by minSdk.
- **`android.enableJetifier` is already gone** from `gradle.properties`. The
  entry saying it was flagged-but-not-removed was wrong.
- Also already done: the three `androidx.legacy:*` libraries are dropped and
  `fragment_about.xml:43` uses a plain `<Space>`; there are zero `SDK_INT >= O`
  dead conditionals left.

Historical findings worth not re-deriving: the Hilt single-component risk was
assessed and found absent (no real per-activity scoping existed), and the
base-class trap (`BaseBrowserActivity`/`BaseSettingsFragment`) is why **any DI
change on this project needs a per-screen device walk, not just a green build** —
uninjected fields compile clean and fail at runtime. That rule still applies.

## Toolchain notes — closed avenues and deprecation deadlines

**kapt→KSP: the old blocker is moot — `dagger-android-processor` is gone.**
The 2026-09-01 `feature/kapt-to-ksp` failure was real at the time:
`dagger-android-processor` had no KSP build (`google/dagger#4044`), and splitting
it from `dagger-compiler` across kapt/KSP failed with unresolved bindings in
`AndroidBindingModule.kt`. **That avenue no longer applies** — the Hilt migration
removed `dagger-android` from this codebase entirely, which was the documented
condition for reopening it.

**KSP stage 1 is DONE (2026-09-02, `feature/ksp-stage-1`).** `hilt-compiler`
was the only kapt processor left; it now runs under KSP. **kapt is gone from this
project entirely.**

- **KSP is NOT Kotlin-locked, and `ext.kotlin_version` no longer exists.** That was
  true of the old `<kotlin>-<ksp>` line but not of KSP 2.3.x, which versions
  independently of the compiler. We are on **2.3.11**, pinned in the root
  `build.gradle`. Since the Kotlin compiler now comes from AGP (see kmb.14 below),
  a KSP bump and a Kotlin bump are separate events — and nothing fails at
  configuration time if they drift apart, so **re-check KSP on every AGP bump**.
- **The two Hilt processor args are gone** (kmb.14) — they are auto-wired again now
  that `android.newDsl=false` is removed. Verified by byte-diffing a no-args build
  against a with-args build: identical.
- kapt's `correctErrorTypes` and `javacOptions --release 17` had no KSP equivalent
  and were dropped with the block.
- **Where the generated code lives changed.** Under kapt everything landed in
  `build/generated/source/kapt/`. Under KSP the per-target `Hilt_*` classes go to
  `build/generated/ksp/<variant>/java/`, but the **root component**
  (`Hilt_WallPanel`, `DaggerWallPanel_HiltComponents_SingletonC`,
  `WallPanel_HiltComponents`, `WallPanel_ComponentTreeDeps`, and the root sentinel)
  is emitted by Hilt's aggregating task into `build/generated/hilt/component_sources/`
  and compiled by `hiltJavaCompileProdDebug`. Diffing the KSP output directory
  against the old kapt one shows 5 "missing" files — **they are not missing**, they
  moved. Verified present in the APK dex.

**KSP stage 2 is DONE (2026-09-02, kmb.14) — the AGP 10 deadline is CLOSED.**
`kotlin-android` is gone, replaced by AGP's built-in Kotlin, and **both
`android.builtInKotlin=false` and `android.newDsl=false` are removed from
`gradle.properties`.** Nothing in this build depends on anything AGP 10.0 removes,
so an AGP 10 bump is now a routine version bump. `-Pandroid.debug.obsoleteApi=true`
reports zero legacy-variant-API warnings, down from three (all three had come from
`kotlin-android` itself).

**The recorded blocker was wrong in both halves — don't re-derive it.** Stage 2 was
documented as blocked because AGP's migration doc covers neither KSP nor
`kotlin-parcelize` under built-in Kotlin, "and we use both". We never used both:
a repo-wide scan found **zero `@Parcelize` and zero `Parcelable`**, so the plugin
was applied but had never generated anything. It is deleted. That also mooted
`google/ksp#3053` (KSP `[MissingType]` on `@Parcelize` classes under built-in
Kotlin), which was the hazard most likely to sink the spike.

The real blocker was the other one, and it was version-shaped: **every `2.2.21-*`
KSP throws an unconditional `RuntimeException`** ("KSP is not compatible with
Android Gradle Plugin's built-in Kotlin"), and `2.2.21-2.0.5` was the last release
on that line — so `google/ksp#2615` was **not** resolved at the version we were
pinned to. KSP 2.3.x gates the same refusal on AGP < 9.0.0-alpha14 only. Checked
against the plugin artifacts themselves, not the issue tracker.

**The Kotlin compiler version is no longer independently chosen.** There is no
`kotlin-gradle-plugin` classpath entry and no `kotlin_version`; the compiler is
whatever AGP bundles. **A future AGP bump is therefore also a Kotlin bump.**

**`com.android.legacy-kapt` is NOT APPLICABLE — kept here only as history.** It was
the escape hatch if stage 2 stalled, an AGP-provided kapt compatible with built-in
Kotlin. Stage 2 did not stall, and this project runs KSP under built-in Kotlin with
no kapt anywhere. Do not reach for it.

## Wake / wifi / keyguard locks — measured 2026-09-02, don't re-derive

All three live in `WallPanelService.onCreate`, are acquired at startup, and — since the
service never stops and the activity is never destroyed — their release paths are dead
code. Audited on device against `dumpsys`, not against the deprecation warnings.

- **`screenWakeLock`** (was `partialWakeLock`, a misnomer — it is
  `FULL_WAKE_LOCK or ACQUIRE_CAUSES_WAKEUP`). **Never held in steady state**: every
  acquire is timed (`acquire(3000)` in `configurePowerOptions`, `acquire(wakeTime)` in
  `wakeScreenOn`). `dumpsys power` shows only WindowManager's `SCREEN_BRIGHT_WAKE_LOCK`,
  which is what `FLAG_KEEP_SCREEN_ON` produces — **that**, not this lock, is why the
  screen stays on. The lock's only job is turning a *dark* screen ON, on the motion-wake,
  face-wake and MQTT-wake paths. **Kept deliberately**; it cannot become a
  `PARTIAL_WAKE_LOCK` (AOSP: `ACQUIRE_CAUSES_WAKEUP` cannot be combined with it) and
  `setTurnScreenOn()` is an Activity API the service can't reach.
- **`wifiLock`** is `WIFI_MODE_FULL_LOW_LATENCY` since kmb.16. It was `WIFI_MODE_FULL`,
  which AOSP documents as **"non-functional and will have no impact"** — confirmed live:
  held as `type=1` while the framework counted `0 full low latency` acquired. Now
  `type=4`, `2 full low latency` acquired, `mPowerSaveDisableRequests 2`. Verify with
  `dumpsys wifi | grep -iE 'wifilock\{|Locks acquired'`.
- **`keyguardLock.disableKeyguard()`** is **redundant on this tablet and kept anyway.**
  There is no credential (`Password quality: {0=0}`, `mPasswordOwner=-1`,
  `trustManaged=0`, `isKeyguardShowing=false`), and `BaseBrowserActivity` sets
  `FLAG_SHOW_WHEN_LOCKED` / `FLAG_DISMISS_KEYGUARD` / `FLAG_TURN_SCREEN_ON` — but only on
  that one activity. Forks may run a swipe lock, and `setShowWhenLocked()` needs API 27
  against minSdk 26. `DISABLE_KEYGUARD` is granted, so the call does run.

**The walk-up wake path does not depend on the wake lock for its visible effect.** Motion
or face detection calls `configurePowerOptions()` *and* `wakeScreen()`; the visible part —
screensaver dismissed, brightness restored — comes from the broadcast:
`BROADCAST_SCREEN_WAKE` → `stopDisconnectTimer()` → `resetInactivityTimer()` →
`hideScreenSaver()` + `resetScreenBrightness(false)`. The wake lock only matters when the
display is genuinely off. Reading `stopDisconnectTimer` as a no-op (it isn't — see
`BaseBrowserActivity.kt:292`) is the easy mistake here.

## Standing constraint

**We build and sign our own APKs.** Never install a prebuilt APK/AAB from a
release page, CI artifact, or third party, even from `upstream` — build from
source we've reviewed and sign with our own key.

## Memory footprint — hypotheses already tested and rejected

The production app's working set is large (measured 227–450MB TOTAL PSS depending
on graphics state). Two explanations have been tested on the device and **both are
rejected — do not retest them**:

- **Camera capture rate** (kmb.3, Aug 2026). Reducing the capture rate at the sensor
  did not move the footprint.
- **Init providers / Firebase** (kmb.4, Aug 2026). `FirebaseInitProvider` was a real
  and worth-removing defect — Firebase init ran on every launch with no
  `google-services.json` — but removing it did not reduce memory. The APK shrank
  461KB and the provider disappeared; PSS did not improve.

**The dominant term is GL mtrack — GPU memory for WebView compositing — measured at
~226MB in a single process**, against ~43MB of code and ~31MB of Java heap. Any
future memory work starts there, not at providers, dependencies or camera settings.
`dumpsys meminfo <pkg>` reports it under `GL mtrack` and in the `Graphics` summary
row.

Note that PSS comparisons across processes are easily invalidated by differing
WebView count and renderer-crash history — both shift GL mtrack by hundreds of MB.
Compare only samples with the same WebView count and similar uptime, and say so.

## Fixed defect — a single renderer crash wedged the panel (fixed 2026-09-02)

Reproduced twice (2026-08-30, 2026-09-01, n=2) on `xyz.wallpanel.app.kmb`. One
renderer crash, with the dashboard visible, permanently wedged the panel:

- `onWebViewRenderProcessGone` did its job — the WebView was rebuilt, `webView` was
  VISIBLE and full-size, `progressView` was GONE, a fresh renderer bound, the app
  process was unchanged and kept window focus.
- But **Home Assistant's own frontend never re-initialised**. The panel sat on
  HA's loading screen (logo + "A project from the Open Home Foundation"), spinner
  animating for ~5 minutes and then frozen. No self-recovery after 7 minutes.

**Root cause, found 2026-09-02: a stale-cache bug, not a missing reload.** The
previously recorded hypothesis here ("the likely fix shape is re-loading the page,
not just rebuilding the WebView") was wrong and is disproven by the code —
`onWebViewRenderProcessGone` already called `initWebPageLoad()` →
`loadWebViewUrl()` → `webView.loadUrl()` on the new WebView every time. The real
bug: `BrowserActivityNative` cached `WebSettings` in an activity-lifetime field
(`private var webSettings: WebSettings? = null`), assigned once in
`configureWebSettings` behind an `if (webSettings == null)` guard. `WebSettings` is
per-WebView-instance, not shared — so after a rebuild, every
`javaScriptEnabled = true` / `domStorageEnabled = true` / etc. call kept mutating
the **destroyed old WebView's** settings object, never touching the new one. The
new WebView was left on Android defaults: JavaScript and DOM storage both
disabled. HA is a JS SPA — the static loading-screen shell still rendered (its
spinner is pure CSS, hence "animating"), but the frontend never booted, matching
the symptom exactly. No other field in the codebase caches anything owned by the
WebView instance (checked: `webView` itself, both client objects, and
`ScreenSaverView`'s separate WebView, which already used a local val and has no
rebuild path).

**Fix:** `configureWebSettings` now uses a local `val webSettings = webView.settings`
instead of the cached field — verified with `smoke-renderer-crash.sh` (3 consecutive
passes, 35s idle wait intact), `smoke-device.sh`, and `panel-render-probe.sh`.

**It does not appear to fire on its own.** Zero organic renderer crashes across
~2.4 days of capture, against 32 injected. The one organic renderer tombstone on
record (08-26) is on the archived `xyz.wallpanel.app` build, not ours. So this was
a real defect, capable of wedging the panel, but never observed to trigger without
deliberate crash injection.

## Closed — InternalWebClient.dialogUtils IS injected (corrected 2026-09-02)

This section previously described a live defect: `InternalWebClient.kt` declaring
`@Inject lateinit var dialogUtils: DialogUtils` while being manually constructed,
giving an `UninitializedPropertyAccessException` on any SSL error. **That was
false.** `InternalWebClient` takes `dialogUtils` as a **constructor parameter**
(`InternalWebClient.kt:21`) and `BrowserActivityNative.kt:396` passes it
explicitly. There is no `@Inject` anywhere in the file, and `git log -S dialogUtils`
shows exactly one commit touching it (`135bd78`, 2022-05-02, the file's own
introduction) — so the field-injection form this entry described never existed on
this branch. Nothing to fix.

## Lifecycle observers — which callbacks actually fire (measured 2026-09-02)

The three `@OnLifecycleEvent` sites were migrated to `DefaultLifecycleObserver`
(kmb.12). Measuring before and after on device produced a finding worth more than the
migration: **two of the three callbacks never run in normal operation, and that has
nothing to do with the annotation mechanism.**

Measured with a Timber line in each callback, same sequence before and after, on the
`kmb.dev` debug build (release plants no Timber tree):

- `TextToSpeechModule.onStart` (ON_START) — **fires**, both before and after.
- `DialogUtils.onDestroy` (ON_DESTROY) — **fires**, both before and after, proven
  unambiguously on `SettingsActivity`, which has no `onDestroy` override and no direct
  `clearDialogs()` call, so the log line can only have come from the observer.
- `TextToSpeechModule.onDestroy` (ON_DESTROY) — **never observed to fire.**

Two structural reasons, both pre-existing and both mechanism-independent:

- **`BrowserActivityNative` is effectively never destroyed.** Its manifest entry
  declares `configChanges="orientation|keyboardHidden|keyboard|screenSize|
  smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"` —
  it absorbs every configuration change itself. Rotation, density and font-scale
  changes all fail to recreate it; `--activity-clear-task` puts the target in a new
  task instead; `always_finish_activities=1` had no effect. It ends by process death,
  which does not deliver ON_DESTROY. So on the panel's main activity, `DialogUtils`'
  ON_DESTROY is dead — screensaver and alert dialogs are cleared by the **direct**
  `clearDialogs()` calls instead (broadcast handler, `inactivityCallback`,
  `showScreenSaver`), of which there are 9 across the codebase.
- **`WallPanelService` never stops gracefully.** There is no `stopSelf()` anywhere in
  it and no stop action; it is a persistent foreground service started only by
  `startForegroundService` at `BaseBrowserActivity.kt:199` and never bound. `am
  stopservice` returns "Error stopping service" and `pm disable-user` throws. So
  `TextToSpeechModule.onDestroy` — the `textToSpeech.shutdown()` path — is unreachable
  in practice. Harmless today (process death reclaims the engine), but do not assume
  that teardown runs.

**Do not re-derive this by trying harder to destroy the activity.** Every adb route was
tried on 2026-09-02 and the manifest is the reason. If a callback on either of these
two owners ever needs to run, the fix is an explicit call, not a lifecycle event.

## Liveness — the render probe, and what it does not cover

Process liveness, window focus and a bound renderer are **not** sufficient to call the
panel healthy. On 2026-08-30 all three were true while it sat permanently on a dead
Home Assistant loading screen: the app was alive and GCing, focus was held, and
renderer 24949 stayed bound throughout.

`scripts/panel-render-probe.sh` is the answer to that, and `smoke-renderer-crash.sh`
runs it after its crash cycle. It decides whether the dashboard is really on screen
from two signals — screencap size, and the byte delta between two captures 3s apart —
which works because the dashboard carries live IR camera feeds. Read the script's
header before trusting a verdict: it assumes those feeds, and it cannot tell the
screensaver apart from a stuck page by size alone.

The screensaver is distinguished **structurally**, not by pixels: 1 distinct app
window means the dashboard is exposed, 2 means the screensaver dialog is on top.
Measured in both directions on this panel. That invariant is also the tap-safety rule
— only tap to dismiss when there are 2 windows, so a dialog is always there to consume
the touch and it can never actuate a Home Assistant control.

Still open, deliberately: an **out-of-band** liveness check that does not depend on
adb or on a screenshot — the MQTT heartbeat is the obvious candidate, since it would
catch a wedge while nobody is running a smoke script. Not built.

## Git workflow

Commit and push to `origin master` automatically once a change is complete
and verified (build succeeds / tests pass as applicable) — do not stop to ask
for confirmation first. This applies to normal working commits on this repo.
Still ask first for anything destructive or history-rewriting (force-push,
reset --hard, rebase, branch deletion).

Tags and GitHub releases for a signed APK follow the release policy in
"Deploy and verify" — created automatically, without prompting, once both
smoke scripts pass. Not a confirmation point.

**`gh` targets `upstream` (Darknetzz) by default in this checkout, not our
fork.** It picks the parent from the remote set, so `gh release create` fails
with "tag exists locally but has not been pushed to Darknetzz/wallpanel-android"
— or worse, would publish to the parent. Always pass the repo explicitly:

```
gh release create v0.12.0-kmb.16 <signed.apk> --repo kmbrimble/wallpanel-android ...
```

`git push origin <tag>` is unaffected; this is a `gh`-only trap.

## Delegation

- **advisor (Fable)** is consulted for: the plan, before implementation begins,
  on any feature touching more than one file; any decision about concurrency,
  lifecycle, teardown or threading; anything touching credentials, network
  config or permissions; any judgement call where two reasonable approaches
  exist; and a review of the diff before the feature is declared done.
- advisor is **not** consulted for: naming, formatting, mechanical edits, or
  anything where there is one obvious answer. Over-consulting wastes time and
  dilutes the signal.
- **repository-reader (Haiku)** handles all exploratory and high-volume
  reading: locating code, enumerating call sites, reading diffs, scanning
  dependencies. Do not read large files directly when repository-reader can
  summarise them.
- When advisor's recommendation is not followed, say so and why in the
  handback.

## Release signing

**ABI splits are gone as of kmb.16.** `assembleProdRelease` produces exactly one
output, `WallPanelApp-prod-release-unsigned.apk` (~9.2MB). Sign that. Build tools live
at `/root/.android-sdk/build-tools/34.0.0/`.

Why they went: there have been no native libraries in this APK since kmb.11 (`unzip -l`
shows zero `lib/` entries, `mergeProdReleaseNativeLibs` is `NO-SOURCE`), so the four
splits were degenerate — five byte-identical ~9.2MB APKs where one would do. Removing
`splits { abi { ... } }` changed the byte count not at all (9248461 before and after).
**Do not reinstate them** unless a native dependency actually lands.

Release artifacts are now named `release-out/WallPanelApp-universal-<version>.apk`
(e.g. `WallPanelApp-universal-0.12.0.0-kmb.16.apk`).
`promote.sh`'s rollback glob is `WallPanelApp-*.apk`, deliberately wider than
`-universal-*`, so every release up to kmb.15 — all named `-arm64-` — stays a valid
rollback target. Verified end to end on kmb.16.

Verified signing invocation:

```
zipalign -p -f 4 <unsigned.apk> <aligned.apk>
apksigner sign --ks /projects/wallpanel-release.jks --ks-key-alias wallpanel \
  --ks-pass file:/projects/.env.keystore-pass --out <signed.apk> <aligned.apk>
apksigner verify --print-certs --verbose <signed.apk>
```

- The keystore password lives at `/projects/.env.keystore-pass`, **outside the
  repo** — never move it, or a copy of it, into the repo or commit it anywhere.
- `apksigner sign` also emits a `<signed.apk>.idsig` sidecar file — this is a
  Play-specific artifact (APK Signature Scheme v4). **Do not attach it to
  releases**; only the signed `.apk` itself.

## Deploy and verify — release policy

This app is a personal wall panel, not critical infrastructure. Auto-promotion
on green tests is deliberate — do not add confirmation prompts before
promoting.

- **`scripts/smoke-device.sh` runs on `xyz.wallpanel.app.kmb.dev`**, against a
  debug build from the same source tree as the release. It installs, exercises
  and uninstalls the dev app itself.
- **`scripts/panel-render-probe.sh` runs after `smoke-device.sh`** and confirms
  the panel is actually showing the dashboard. Process liveness and window focus
  are not sufficient — see "Liveness" above.
- **`scripts/smoke-renderer-crash.sh` is RETIRED from the release path**
  (2026-09-01). Do not run it to promote a build. It is kept as a deliberate,
  attended tool for when you are working on WebView code and standing near the
  tablet.

  **Why it was retired.** A single injected renderer crash reproducibly wedges
  the panel — the app survives, keeps focus and binds a fresh renderer, but Home
  Assistant's frontend never re-initialises and the dashboard never comes back
  (measured 2026-08-30 and 2026-09-01, n=2). Recovery needs physical access to
  the tablet. Meanwhile log analysis over ~2.4 days of capture found **zero
  organic renderer crashes** against 32 injected, so this script was the only
  thing that had ever wedged the panel: it was manufacturing the outage it was
  meant to guard against. Two consecutive evenings ended with a dead wall panel.

  If you do run it: it still refuses to start unless the candidate carries the
  production applicationId, is signed with the same key as the installed app, and
  a `release-out/` APK matches the installed versionCode. Keep its 35s idle wait
  intact — never weaken, shorten or skip it to get a green; it is the only reason
  the screensaver bug was ever caught. Default is one cycle
  (`SMOKE_RENDERER_CYCLES` to go deeper).

  **Root cause found, 2026-09-02: MediaTek DuraSpeed.** DuraSpeed is compiled
  into this device's `system_server` (`bringUpServiceLocked`) and refuses to
  spawn services for apps on its suppress list — including, on this tablet,
  the `SandboxedProcessService` WebView needs to spin up a renderer. When it
  fires, the bind request is accepted into AMS's bookkeeping and then simply
  never acted on: `ServiceRecord` sits Pending with `binder=null
  requested=false received=false hasBound=false`, and no `Start proc` line
  is ever logged for it — confirmed via logcat correlation against trial
  timestamps, and via an independent source with MTK framework access.
  Confirmed live on-device: DuraSpeed is present and enabled
  (`persist.vendor.duraspeed.app.on=1`,
  `persist.vendor.duraspeed.lowmemory.enable=1`, package
  `com.mediatek.duraspeed` installed). The kill switch —
  `settings put global setting.duraspeed.enabled 0` — worked 5/5 on the
  exact force-stop trigger that reproduced the wedge. **It does not survive
  reboot** — a reboot re-enables DuraSpeed and the wedge risk returns until
  the setting is re-applied.

  **The app now clears the flag itself on startup (built 2026-09-02, commit
  `ef7c32f`, promoted the same day as kmb.9 — see the grant record
  below).** `WallPanel.onCreate` calls
  `DuraSpeed.disableIfPermitted()` before any WebView exists, writing
  `setting.duraspeed.enabled=0` when `WRITE_SECURE_SETTINGS` is held, and doing
  nothing (never crashing) when it isn't. Measured on device, n=2 with a
  controlled revoked-permission trial that wedged: **this CURES an in-flight
  suppression, not just prevents future ones** — with the permission held the
  renderer bound and the page loaded 0.75s after the write. So DuraSpeed
  re-evaluates the flag when the renderer is requested; it does not latch a
  decision at force-stop time.

  **POST-PROMOTION STEP — grant the permission.** The app cannot clear the flag
  without it, and a runtime grant is tied to the installed package, not to the
  source. Run after promoting:

  ```
  adb shell pm grant xyz.wallpanel.app.kmb android.permission.WRITE_SECURE_SETTINGS
  ```

  Confirm it actually took — the grant is silent on success and easy to assume:

  ```
  adb shell dumpsys package xyz.wallpanel.app.kmb | grep WRITE_SECURE_SETTINGS
  ```

  Expect `granted=true`. **Redo this whenever the app is uninstalled and
  reinstalled** — an uninstall drops the grant with the package.

  Granted on kmb.9 (2026-09-02) and verified `granted=true`. Confirmed working on
  a *release* build the same day: `WallPanelDuraSpeed: WRITE_SECURE_SETTINGS
  held=true` / `write returned true` in logcat. That line is visible in release
  precisely because it uses `android.util.Log` — release plants no Timber tree,
  so a Timber call here would log nothing.

  **The grant DOES survive `adb install -r`** (measured on kmb.9, 2026-09-02:
  `granted=true` read immediately after `promote.sh` finished, before any
  re-grant) **and survives a reboot** (same day). So it is a genuine one-off per
  install, not a per-promotion step, and `promote.sh` does not need to re-grant.
  Only an uninstall drops it.

  **`promote.sh` is now safe with DuraSpeed enabled — the manual flag step is
  gone from the workflow.** Verified deliberately on kmb.9: flag set to 1, then
  `promote.sh` run over the same build. The trigger was genuinely armed — three
  `Force stopping xyz.wallpanel.app.kmb` lines logged (promote.sh's own
  `am force-stop`, plus the installer's `pkg removed`) with the flag at 1 — and
  the renderer bound anyway (`Start proc ... SandboxedProcessService0`, no
  `Pending` record), flag was zeroed by the app, post-install probe RENDERING.

  **Reboot test passed** (kmb.9, 2026-09-02): flag set to 1, tablet rebooted,
  and the flag read `0` afterwards with nobody touching it, app auto-started via
  its boot receiver, renderer bound, probe RENDERING. Note the logcat buffer had
  already rolled by the time it was read (heavy post-boot load), so the flag
  value is the evidence rather than the `held=true` log line — sound, because
  nothing else writes that value, but it is inference not a direct log.

  Before kmb.9 this file claimed the app "has been granted
  `WRITE_SECURE_SETTINGS` via adb". That was false — verified 2026-09-02, the
  permission was not listed at all on kmb.8, whose manifest never declared it.

  **Known open item, low priority — the screensaver dismisses the DuraSpeed
  message.** `DialogUtils.showScreenSaver` calls `clearDialogs()` →
  `hideAlertDialog()`, so the "Browser engine blocked" notice added in kmb.9 is
  wiped when the screensaver appears (observed at ~30s in testing). Pre-existing
  shared behaviour affecting every alert dialog, not something kmb.9 introduced.
  **Deliberately not fixed:** per Q1 the audience for this message is a
  developer who has just relaunched over adb and is watching the tablet, so they
  see it well inside 30s, and the fix would touch dialog behaviour every other
  dialog depends on. Fix only if it actually bites.

  **Ruled out along the way — keep this list, don't re-test any of it:**
  - **Dev app cannot obtain a renderer.** False. The dev app was observed
    obtaining a renderer and rendering a page on this same tablet, the same
    day the claim was written. Not a real dev-vs-prod split — both are
    equally exposed to DuraSpeed suppression.
  - **`SandboxedProcessService0` vs `SandboxedProcessService1` predicts
    success.** False. Controlled trials against production (force-stop, then
    either `am start -n` or a `monkey -c LAUNCHER` relaunch, repeated) showed
    a pass on Service0, an immediate-next-attempt fail on Service1, and a
    later fail on Service0 again after a LAUNCHER-intent relaunch. The slot
    number is assigned before DuraSpeed's suppress check and carries no
    signal about it.
  - **Launch method (`am start -n` vs LAUNCHER-intent) is the discriminator.**
    False. Both methods hit the identical failure signature under production;
    DuraSpeed's suppress list is keyed on something else entirely (still
    unconfirmed which trigger condition, beyond "recent force-stop of this
    app" as the reproducible case).
  - **Isolated-UID exhaustion.** False. At the moment of a reproduced
    failure, only 1 of ~1000 isolated UID slots was in use system-wide (the
    launcher's own), and this app's prior isolated process had already been
    cleanly torn down (obituary received ~2.3s before the new bind attempt,
    no leaked/zombie `ProcessRecord`). AMS's isolated-UID allocator was never
    even reached — DuraSpeed's suppress check runs upstream of it.
  - **Manual cache-clear is what unwedges the panel.** Not the operative
    mechanism. The manual recovery routine (force-stop, clear app cache
    storage, reopen) works because of the force-stop + delay, not the cache
    clear — DuraSpeed's suppression is what force-stop was incidentally
    working around some of the time.

- **If `smoke-device.sh` and `panel-render-probe.sh` both pass, promote
  automatically** via `scripts/promote.sh <signed.apk>`. Do not run
  a bare `adb install -r` to promote — see why below.

  **`smoke-device.sh` + `panel-render-probe.sh` only clear the build for
  promotion; they do not verify the promoted build itself.** Both run before
  install, against the dev app and the still-running previous production
  build respectively. A post-install check is mandatory because **`adb
  install -r` does not restart the foreground app on this launcher** (found
  promoting kmb.3, handled manually at the time, undocumented until now) — the
  panel can keep showing the old build's UI, alive and rendering, while the
  new APK sits installed but never loaded. A render probe run only
  before install cannot catch a new build that shows a blank page; it would
  promote green.

  `scripts/promote.sh`: installs (`adb install -r`), force-stops and relaunches
  the app (`am start -W`) so the new APK actually loads, then re-runs
  `panel-render-probe.sh` against the running new build. If that post-install
  probe fails, it rolls back automatically — `adb install -r -d` to the newest
  other APK under `release-out/`, relaunches, and re-probes — and reports
  loudly whether the rollback itself restored rendering. It refuses to
  promote anything whose applicationId isn't exactly `xyz.wallpanel.app.kmb`.

  The tablet is reachable over the LAN at `192.168.0.52:5555` (adb-over-TCP;
  `adb connect 192.168.0.52:5555` first if it isn't already listed in
  `adb devices`).

  **Address resolution is port-scan based.** `scripts/adb-device.sh` tries
  `<ip>:5555` first and, on failure, port-scans `30000-60999` (bounded parallel
  probes via bash's `/dev/tcp`, ~14-23s for the full range), connects to the first
  candidate that reports `device`, then re-pins 5555 so the fast path works again.

  **A reboot does NOT leave adb reachable on another port — it leaves adb off.**
  This file previously claimed a reboot re-assigns wireless debugging to a random
  ephemeral port that the scan then recovers. That is **0 for 2** in practice
  (2026-08-30 and 2026-09-01): after both reboots the host answered on the network
  (`Connection refused`, not a timeout, on every port probed) but the full
  `30000-60999` scan found **no open port at all**, and a LAN-wide sweep for adb
  found nothing either. Wireless debugging appears to be simply **off** after a
  reboot, not moved. Recovering it needs someone at the tablet:
  Settings > Developer options > Wireless debugging. Assume any reboot strands the
  harness until a human intervenes, and never build automation that depends on adb
  surviving one. **Do not reinstate mDNS discovery** (`adb mdns services`): it
  relies on multicast, which does not cross this container's Docker bridge, so
  it always returns zero services here — it failed closed, but could never
  succeed, which made it dead code that read as functional. `SMOKE_SERIAL`
  remains a raw bypass for both smoke scripts.
- **If either fails, do not promote.** Report and stop. A failing render probe
  means the panel is wedged and needs physical attention — say so loudly rather
  than retrying, and never `pm clear` (it wipes the HA config).
- Keep every promoted APK at `release-out/WallPanelApp-universal-<version>.apk`
  (e.g. `WallPanelApp-universal-0.12.0.0-kmb.16.apk`) and attach it to its
  GitHub release. **Never delete older ones.**
- **Rollback (manual, by the user only)**:
  ```
  adb install -r -d release-out/<older>.apk
  ```
  The `-d` flag is required — adb refuses a lower versionCode without it.

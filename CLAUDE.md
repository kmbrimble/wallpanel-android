# WallPanel (kmbrimble fork)

Android kiosk browser for a Home Assistant dashboard, running on a wall-mounted
tablet on the home LAN. The app holds HA credentials (and optionally MQTT
broker credentials), so trust in every change matters more than usual for a
hobby project.

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
- **JDK**: Gradle itself runs on JDK 17-25; Kotlin/kapt compile against JDK 17
  via `kotlin { jvmToolchain(17) }`.
- **Android SDK**: `compileSdk`/`targetSdk` 34, `minSdk` 19.
- Firebase Crashlytics / Google Services plugins only apply if
  `google-services.json` exists in the module — safe to build without it.

## Toolchain notes — closed avenues and deprecation deadlines

**kapt→KSP migration for Dagger is blocked upstream — closed, don't reopen.**
Tried on `feature/kapt-to-ksp` (2026-09-01, branch deleted after folding its one
real change into `feature/dependency-sweep`). `dagger-android-processor` has no
KSP build (`google/dagger#4044`, open upstream), and KSP's
`@ContributesAndroidInjector` validation requires `AndroidProcessor` on the same
processor path as `dagger-compiler` — splitting the two across kapt/KSP fails at
build time with unresolved bindings in `AndroidBindingModule.kt`. Verified by
build, not assumed. Revisit only if Dagger ships KSP support for
`dagger-android-processor`, or if `dagger-android` is removed from this codebase
entirely (a real DI rewrite, not a toolchain swap). Until then this project stays
on kapt, and the "Kapt currently doesn't support language version 2.0+" fallback
warning is expected, not a bug.

**AGP 9's DSL/Kotlin opt-out flags expire in AGP 10.0 (mid-2026).** If the AGP
version in `build.gradle` is ever bumped to 9.x or later while this project still
needs kapt (see above), `gradle.properties` needs both:
```
android.builtInKotlin=false
android.newDsl=false
```
`android.newDsl=false` restores the old DSL/variant API that `kotlin-android`
(classic KGP, required for kapt) depends on; `android.builtInKotlin=false` keeps
Kotlin compilation off AGP's built-in path so kapt can run. **Both opt-outs are
removed in AGP 10.0** — confirmed via AGP's own docs (`developer.android.com/build/r/new-dsl`
and `developer.android.com/build/migrate-to-built-in-kotlin`), not a blog post.
AGP 10.0 is dated "mid-2026" in the `newDsl` docs. When AGP 10.0 ships, this
project cannot use kapt-based Dagger with a current AGP unless the kapt→KSP
migration above has unblocked by then — check the Dagger KSP status again at
that point, since staying on an AGP 9.x tail indefinitely is not a real option.

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

## Open defect — a single renderer crash wedges the panel

Reproduced twice (2026-08-30, 2026-09-01, n=2) on `xyz.wallpanel.app.kmb`. One
renderer crash, with the dashboard visible, permanently wedges the panel:

- `onWebViewRenderProcessGone` does its job — the WebView is rebuilt, `webView` is
  VISIBLE and full-size, `progressView` is GONE, a fresh renderer binds, the app
  process is unchanged and keeps window focus.
- But **Home Assistant's own frontend never re-initialises**. The panel sits on
  HA's loading screen (logo + "A project from the Open Home Foundation"), spinner
  animating for ~5 minutes and then frozen. No self-recovery after 7 minutes.
- Recovery is not automatable: `am start -S` and `am force-stop` + start have
  never worked, and `adb reboot` recovers the panel but strands adb.

**It does not appear to fire on its own.** Zero organic renderer crashes across
~2.4 days of capture, against 32 injected. The one organic renderer tombstone on
record (08-26) is on the archived `xyz.wallpanel.app` build, not ours.

So: real defect, running on the wall, but provoked only by our own crash
injection. Fix it properly when you are next in the WebView code — the likely
shape is re-loading the page (not just rebuilding the WebView) once the new
renderer is attached. Do not provoke it just to study it; that has cost two
evenings and two trips to the tablet.

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

`assembleProdRelease` produces per-ABI split APKs plus a universal one. **Sign
and install the `arm64-v8a` split, not the universal APK** — our tablet is
arm64-v8a only, and the split is 19.6MB against the universal's 36.1MB for the
same install. Build tools live at `/root/.android-sdk/build-tools/34.0.0/`.

Verified signing invocation:

```
zipalign -p -f 4 <unsigned-arm64-v8a.apk> <aligned.apk>
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

  **Why production, not the dev app:** the dev app cannot obtain a WebView
  renderer on this tablet. It requests `SandboxedProcessService1`, whose
  ServiceRecord never gets a bound process, while production usually gets
  `SandboxedProcessService0`. `pm clear` on dev only left it with no configured
  URL and so no WebView at all.

  **This is not dev-only.** It was once recorded as "unexplained and deliberately
  closed — affects only the harness, never the shipping app". That is false. The
  production app was observed in exactly this state: after a renderer crash and a
  force-stop restart it requested `SandboxedProcessService1:0`, whose
  ServiceRecord sat Pending with `binder=null requested=false received=false
  hasBound=false`, with **no** `SandboxedProcessService0:*` records at all — so it
  is not slot exhaustion. The panel was left black with the app alive and holding
  focus. Open, and unexplained.

- **If `smoke-device.sh` and `panel-render-probe.sh` both pass, promote
  automatically**: install the signed arm64-v8a APK to
  the production app `xyz.wallpanel.app.kmb` —
  ```
  adb -s 192.168.0.52:5555 install -r <signed-arm64-v8a.apk>
  ```
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
- Keep every promoted APK at `release-out/WallPanelApp-arm64-<versionName>.apk`
  and attach it to its GitHub release. **Never delete older ones.**
- **Rollback (manual, by the user only)**:
  ```
  adb install -r -d release-out/<older>.apk
  ```
  The `-d` flag is required — adb refuses a lower versionCode without it.

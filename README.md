# WallPanel (kmbrimble fork)

WallPanel is an Android kiosk browser for web-based dashboards and home automation
platforms — Home Assistant, openHAB, Node-RED, or any other web page. It runs
full-screen on a wall-mounted tablet, can act as the device's home screen, and adds the
things a dashboard on a wall needs: a screensaver that wakes on motion or a face,
camera streaming and detection, text-to-speech, device sensor reporting, and remote
control over MQTT or HTTP.

This fork exists because the app it descends from was archived and the tablet running it
kept crashing. It is a maintenance fork: fixes, a modernised toolchain, and a set of
defects the ancestors left behind. See [How this fork came to be](#evolution) for the
lineage and a release-by-release history.

## Status

**Production ready on one setup — tested on exactly one device. Use at your own risk.**

It runs daily on a Lenovo TB-J616F tablet on Android 12, driving a Home Assistant
dashboard, and it is stable there. That is the whole test matrix. There is no CI device
lab, no coverage of other vendors, OS versions or screen sizes, and no guarantee that a
fix which works around one tablet's firmware quirk is right for yours. Every release is
built from source, signed with our own key, and verified on that one panel before it
ships.

## Installation

Sideload the signed APK from the [releases
page](https://github.com/kmbrimble/wallpanel-android/releases). There is no Play Store
build of this fork — the Play Store listing belongs to TheTimeWalker's archived project,
not to this one.

```
adb install -r WallPanelApp-universal-<version>.apk
```

The application id is **`xyz.wallpanel.app.kmb`**, not `xyz.wallpanel.app`. That is
deliberate: it installs *alongside* any other WallPanel build rather than replacing it,
so you can try this fork without losing a working install. Debug builds add a further
`.dev` suffix.

Open the app, tap the floating dashboard icon to reach the settings, and set your
dashboard URL. The default settings code is `1234` — change it.

### Optional: MediaTek devices

On MediaTek hardware, a vendor service called DuraSpeed can stop the browser engine from
starting. The app can turn it off by itself, but only if it holds the permission to write
secure settings, which cannot be granted from the device:

```
adb shell pm grant xyz.wallpanel.app.kmb android.permission.WRITE_SECURE_SETTINGS
```

Skip this unless you have a MediaTek device. See [MediaTek DuraSpeed](#mediatek-duraspeed)
for what the problem looks like and how to check whether you have it.

## Screenshots

<img src="img/dashboard2.png" width="640" />
<img src="img/dashboard3.png" width="640" />
<img src="img/dashboard1.png" width="640" />

## Features

- Any web-based dashboard or home automation front end.
- Can be set as the Android home screen, for a true kiosk.
- Settings protected by a code; the settings button can be hidden.
- Camera support: video streaming, motion detection, face detection, QR code reading.
- Google Text-to-Speech, driven by MQTT or HTTP.
- MQTT and HTTP commands for remote control — URL, brightness, wake, speak, and more.
- Device sensor reporting: temperature, light, pressure, battery.
- MJPEG streaming server using the device camera.
- Screensaver, dismissed by motion or face detection.
- Launching external applications via intent URLs.

## Requirements

- Android 8.0 (API 26) or later. The minimum was raised from Android 4.4 (API 19) in
  kmb.6; the compatibility branches for older releases are gone.
- A WebView capable of rendering your dashboard. Android renders pages with the system
  WebView component, which is not Chrome and does not always match it. If a page renders
  in Chrome but not here, update the Android System WebView from the Play Store — there
  is nothing the app can do about it.
- For Android 4.0–4.3 devices, the
  [legacy version](https://github.com/thanksmister/wallpanel-android-legacy) of the
  original app is the only option. This fork does not support them.

## Configuration

The app opens on a welcome page with a link to the settings. Everything is configured
there: the dashboard URL, the settings access code, camera and detection options, the
screensaver, MQTT broker details, and the HTTP server.

Setting WallPanel as the default home application makes it load as your home screen every
time. That is the point for a wall panel, but it is awkward to undo without uninstalling —
only do it if you want kiosk behaviour.

## MQTT and HTTP API

Unchanged from the upstream project. Commands can set the dashboard URL, adjust screen
brightness, wake the screen, speak a message, show a notification and more, and the app
publishes sensor and state data back. The command and topic reference lives in the
[original project's documentation](https://github.com/TheTimeWalker/wallpanel-android)
(archived, but still the reference for the API surface).

## MediaTek DuraSpeed

On some MediaTek devices (Lenovo tablets among them), a vendor service called **DuraSpeed**
can stop WallPanel's browser engine from starting. The app comes up, holds focus and looks
alive, but the dashboard never appears — the page stays blank because the WebView never gets
a renderer process. Nothing is logged by the browser engine when this happens; it simply goes
quiet.

**This mostly affects developers, not everyday users.** In testing on an affected tablet, a
force-stop from *Settings > Apps > WallPanel > Force stop* never triggered it (5 out of 5
launches were fine), while an `adb shell am force-stop` followed by a relaunch triggered it
every time. If you are not force-stopping the app over adb, you are unlikely to see it.

Check whether your device ships DuraSpeed at all:

```
adb shell getprop persist.vendor.duraspeed.support
```

`1` means it does. WallPanel also says so on its **Settings > About** screen.

### Fixing it

Turn DuraSpeed off, then restart the app:

```
adb shell settings put global setting.duraspeed.enabled 0
adb shell am force-stop xyz.wallpanel.app.kmb
adb shell am start -n xyz.wallpanel.app.kmb/xyz.wallpanel.app.ui.activities.BrowserActivityNative
```

(Debug builds add a `.dev` suffix to that application id.) With the setting at `0` the
force-stop is safe.

**The setting does not survive a reboot.** To make WallPanel turn DuraSpeed off by itself on
every start, grant it the permission to write secure settings:

```
adb shell pm grant xyz.wallpanel.app.kmb android.permission.WRITE_SECURE_SETTINGS
```

The app then clears the flag in `Application.onCreate`, before any WebView is built. This is
enough to recover an app that is *already* being suppressed, not just to prevent it — the
suppression is re-evaluated when the renderer is requested, so clearing the flag at startup
lets the renderer bind normally on that same launch. Without the permission the app logs that
it does not hold it and carries on; the permission cannot be granted without a computer, so
most installs will not have it.

If a load times out on a DuraSpeed device with no renderer attached, the app says so and
offers the command above to copy, rather than sitting on a blank screen.

## Building

```
./gradlew assembleProdDebug
```

- **Flavours:** `dev`, `qa`, `prod`. Use `prod` for anything you actually install —
  `dev` and `qa` read optional build-time defaults (dashboard URL, MQTT broker and
  credentials, settings code) from `local.properties` and bake them into `BuildConfig`.
- **JDK:** Gradle runs on JDK 17–25; compilation is pinned to JDK 17 by a toolchain
  declaration in the module.
- **Android SDK:** `compileSdk` 35, `targetSdk` 34, `minSdk` 26. Set `ANDROID_HOME`, or
  put `sdk.dir=/path/to/Android/sdk` in `local.properties`.
- **No Firebase, no Crashlytics.** They were removed in kmb.4 and there is nothing to
  configure — no `google-services.json`, no conditional plugin block. Dependency
  injection is Hilt, annotation processing is KSP, and kapt is gone entirely.

## Contributing

Bug reports, feature requests and pull requests are welcome at
[kmbrimble/wallpanel-android/issues](https://github.com/kmbrimble/wallpanel-android/issues).
Bear in mind the status note above: a change can only realistically be verified on one
tablet here, so anything device-specific needs your own testing.

## Credits

This codebase is five maintainers' work before it was ever touched here, and it is
[Apache 2.0](LICENSE) licensed throughout.

- [Raimund Wege / ray0711](https://github.com/ray0711) — wrote the original
  [homeDash](https://github.com/ray0711/homeDash) in March 2017, the Android dashboard
  browser with motion sensing and MQTT that everything below descends from.
- [quadportnick](https://github.com/quadportnick) — took homeDash on through 2017 as
  [the WallPanel Project](https://github.com/WallPanel-Project/wallpanel-android), where
  it was renamed from HomeDash to WallPanel.
- [Michael Ritchie / ThanksMister](https://github.com/thanksmister) — maintained and
  substantially developed [WallPanel](https://github.com/thanksmister/wallpanel-android)
  from 2018 to 2021, the period most of the current feature set comes from.
- [Tony Stipanic / TheTimeWalker](https://github.com/TheTimeWalker) — maintained
  [wallpanel-android](https://github.com/TheTimeWalker/wallpanel-android) from 2022,
  published the Play Store build, and archived the project in May 2025.
- [Kristian Røste / Darknetzz](https://github.com/Darknetzz) — modernised the build after
  the archive, in early 2026, which is what made this fork practical.
- Everyone who contributed patches along the way; see the
  [contributor graph](https://github.com/kmbrimble/wallpanel-android/graphs/contributors).

## Evolution

The lineage below is established from the commit history carried in this repository and
from GitHub's fork metadata, not from memory. Newest first.

**kmbrimble/wallpanel-android** — forked August 2026, from Darknetzz. After TheTimeWalker
archived the project, several recently-updated forks were reviewed; Darknetzz's was chosen
as the base because it had done the toolchain modernisation work — Gradle 9.x, Kotlin 2.x,
a current AGP, Firebase made optional, product flavours — that the others had not. That
fork's own README says it is "not yet fully working", and it was taken at face value: the
first release here fixes two defects introduced by its changes. The fork has since gone
well beyond a rebase, through a Hilt migration, a kapt-to-KSP move, a minSdk raise, a 67%
APK size reduction, and a run of WebView and power-management fixes found by measuring the
running panel rather than reading the code.

**Darknetzz/wallpanel-android** (Kristian Røste) — forked February 2026, from
TheTimeWalker. Modernised the build after the archive: Gradle 9.x, Kotlin 2.x, current
AGP, JDK 17–25, Firebase and Play Services made conditional on `google-services.json`
being present, and `dev`/`prod` flavours. Also added WebView render-process recovery and
deferred service initialisation. Self-described as not yet fully working.

**TheTimeWalker/wallpanel-android** (Tony Stipanic) — took the project over in 2022, when
ThanksMister's development wound down. Kept it current through 2023, including the SDK bump
to Android 13, and published the Play Store build under the `xyz.wallpanel.app` id.
Archived May 2025.

**thanksmister/wallpanel-android** (Michael Ritchie) — maintained from 2018 to 2021 and by
far the largest single contribution to the codebase. Most of what the app does today —
the camera and detection stack, text-to-speech, the MQTT and HTTP command surface, the
sensor reporting, the screensaver — was built or rebuilt in this period.

**WallPanel-Project/wallpanel-android** (quadportnick) — forked March 2017, days after
homeDash's first commit. This is where the project was renamed from HomeDash to WallPanel
and where MQTT login and page-load status arrived. Now deprecated, pointing at
ThanksMister's fork.

**ray0711/homeDash** (Raimund Wege) — first commit 18 March 2017. "Android Browser for
Dashboards with Motion Sensor and MQTT integration." The root of the tree.

### Releases in this fork

Versions are `0.12.0 Build 0-kmb.N`, carried on TheTimeWalker's last version number.

| Release | What changed | Why |
| --- | --- | --- |
| **kmb.16** | Wifi lock changed from `WIFI_MODE_FULL` to `WIFI_MODE_FULL_LOW_LATENCY`; the misnamed `partialWakeLock` renamed to `screenWakeLock`; ABI splits dropped in favour of a single universal APK. | AOSP documents `WIFI_MODE_FULL` as non-functional, and the tablet agreed — the lock was pure bookkeeping. There have been no native libraries in the APK since kmb.11, so the four ABI splits produced five byte-identical outputs. |
| **kmb.15** | Removed `allowFileAccessFromFileURLs` and four dead `WebSettings` setters from the browser WebView. | `allowFileAccessFromFileURLs` let JavaScript on a `file://` origin read other local files. Nothing in the app needed it — it was added in 2018 for an SD-card dashboard feature whose storage permissions are long gone. Deprecation warnings in that file went 5 → 0. |
| **kmb.14** | Replaced the Kotlin Gradle Plugin with AGP's built-in Kotlin; removed both `android.builtInKotlin=false` and `android.newDsl=false`; dropped the unused `kotlin-parcelize` plugin; KSP to 2.3.11. | Those two opt-out flags are deleted in AGP 10.0. Closing the deadline now makes a future AGP bump routine. The recorded blocker turned out to be false in both halves — the project never used `@Parcelize` at all. |
| **kmb.13** | AGP 9.3.2 → 9.4.0, Hilt/Dagger 2.59.2 → 2.60.1. | Routine version bumps, three lines. Verified with a full DI walk, because a Hilt bump regenerates the injection code and uninjected fields compile clean. |
| **kmb.12** | The three `@OnLifecycleEvent` sites migrated to `DefaultLifecycleObserver`. | The deprecated annotation resolved reflectively, which is not safe under minification — a hidden blocker on ever enabling R8. Measuring before and after also revealed that two of the three callbacks never fire in normal operation. |
| **kmb.11** | Removed five unused dependency stacks: ML Kit, Retrofit, OkHttp, RxAndroid, and the HiveMQ minSdk backports. | Nothing referenced any of them. **Release APK dropped 67%, from 27.9MB to 9.2MB** — 12.7MB of that was ML Kit's two native libraries, stored uncompressed. `play-services-vision`, which is the live detector stack, was deliberately kept. |
| **kmb.10** | `hilt-compiler` moved from kapt to KSP. kapt is gone from the project. | kapt was the reason `android.builtInKotlin=false` existed, so this closed half the AGP 10.0 deadline. |
| **kmb.9** | Detects and clears the MediaTek DuraSpeed flag at startup, with an About-screen indicator and an on-screen explanation when a load times out with no renderer. | Root cause of a wedge that had been under investigation for days: MediaTek's DuraSpeed silently refuses to spawn the sandboxed process the WebView needs for a renderer. The panel looks alive and never loads. An ancestor problem in the sense that no fork had ever accounted for the vendor service. |
| **kmb.8** | The Dagger.android → Hilt migration. **Signed but never promoted.** | `dagger.android` was deprecated and blocking the toolchain work. Signed and verified but never installed on the panel; the migration reached the tablet in kmb.9. The changelog does not record why it was held back. |
| **kmb.7** | Post-minSdk cleanup: AndroidX libraries swept to current stable, the three `androidx.legacy` libraries dropped, dead `SDK_INT >= O` branches deleted, `enableJetifier` removed. | The tail of the kmb.6 minSdk raise — code and dependencies that only existed to support Android versions the app no longer runs on. |
| **kmb.6** | minSdk raised 19 → 26; Gradle 9.7.1, AGP 9.3.2, Kotlin 2.2.21, Dagger 2.59.2. | API 19 was Android 4.4, from 2013. Holding it capped every AndroidX dependency and kept compatibility branches alive that had not been exercised in years. |
| **kmb.5** | Fixed the renderer-crash wedge: `configureWebSettings` no longer caches the `WebSettings` object across a WebView rebuild. | A single renderer crash permanently wedged the panel, reproduced twice. `WebSettings` is per-WebView-instance, but was cached in an activity-lifetime field — so after a rebuild every setting was applied to the destroyed WebView. The new one was left with JavaScript and DOM storage disabled, and Home Assistant's front end never booted. A latent bug inherited from the ancestors, not introduced here. |
| **kmb.4** | Removed Firebase, Crashlytics and LeakCanary from the build. | Darknetzz's conditional gated only the Gradle *plugins*; the Firebase SDK dependencies were unconditional, so `FirebaseInitProvider` still ran on every launch — on a device holding Home Assistant credentials, for zero benefit, with no `google-services.json` to talk to. It did not reduce memory, which was the original hypothesis, but it was worth removing on its own terms. |
| **kmb.3** | Reduced camera capture rate at the sensor; added logcat capture with retention. | An attempt on the app's large memory footprint. It did not work — the footprint is dominated by GPU memory for WebView compositing — but the capture infrastructure it brought is what later found the DuraSpeed root cause. |
| **kmb.2** | Fixed the screensaver WebView's unhandled renderer crash; deleted dead code; added the on-device smoke test and a lint gate. | The screensaver ran a second WebView with no `onRenderProcessGone` handler at all, so a crash there took down the whole app process. Pre-existing, inherited. |
| **kmb.1** | Fixed a hardware-acceleration regression in the renderer-crash rebuild path and a service handler leak; added the `.kmb` application id suffix and release plumbing. | Both defects were introduced by Darknetzz's February 2026 changes: the crash-recovery rebuild hardcoded software rendering, and the new deferred-init handler was never cancelled on service teardown. The id suffix is what lets this fork install alongside another WallPanel build. |

# WallPanel

> [!WARNING]
> This fork is **not yet fully working**. Some features may be unfinished or unstable. Use at your own risk and follow progress [in issues](issues) or the project activity.


This is a **community-maintained fork** of [TheTimeWalker/wallpanel-android](https://github.com/thetimewalker/wallpanel-android). The original repository was [archived in May 2025](https://github.com/thetimewalker/wallpanel-android); this fork continues development so the app remains buildable, up to date, and usable for web-based dashboards and home automation.

## Why this fork?

- **Actively maintained** — The original project is read-only; this fork accepts issues and contributions.
- **Modern build tooling** — Updated to Gradle 9.x, Kotlin 2.x, and current Android Gradle Plugin; supports JDK 17–25 and Android SDK 34.
- **Easier to build** — Google Services and Firebase Crashlytics are applied only when `google-services.json` is present, so you can build and run without Firebase or Google Play Services.
- **Better dev experience** — Product flavors: use `prod` for release builds that need no secrets, or `dev` with optional `local.properties` (e.g. `code`, `hassUrl`, `broker`) for default settings during development.
- **Build and code quality** — Dagger and Kotlin toolchain updates, kapt fixes, and clearer build/docs so the project compiles reliably on current JDKs and IDEs.

---

WallPanel is an Android application for Web Based Dashboards and Home Automation Platforms. You can either sideload the application to your Android device from the [release section](releases) or install the application from [Google Play](https://play.google.com/store/apps/details?id=xyz.wallpanel.app).

<a href='https://play.google.com/store/apps/details?id=xyz.wallpanel.app&pcampaignid=pcampaignidMKT-Other-global-all-co-prtnr-py-PartBadge-Mar2515-1'><img alt='Get it on Google Play' src='https://play.google.com/intl/en_us/badges/static/images/badges/en_badge_web_generic.png' width='240'/></a>

## Screenshots

<img src="img/dashboard2.png" width="640" />
<img src="img/dashboard3.png" width="640" />
<img src="img/dashboard1.png" width="640" />

## Support

For issues and feature requests, use this repo’s [issues](issues). For examples and usage, see this repository and the [original project](https://github.com/thetimewalker/wallpanel-android) (archived).

### Common Issues

Rendering issues with the webpage you are trying to view. Android applications use a component to render webpages, it's called the WebView component. WebView is not the same as Google Chrome app, it does not render the pages the same. The biggest issue is that your version of WebView is not capable of rendering the webpage you are trying to view. The only way possible to fix this issue is to update the WebView component (from Google Play Store), use a different webpage, or update your device OS.

## Features

- Web Based Dashboards and Home Automation Platforms support.
- Set application as Android Home screen (optional)
- Use code to access the settings and make the settings button invisible.
- Camera support for streaming video, motion detection, face detection, and QR Code reading.
- Google Text-to-Speech support to speak notification messages using MQTT or HTTP.
- MQTT or HTTP commands to remotely control device and application (url, brightness, wake, etc.).
- Sensor data reporting for the device (temperature, light, pressure, battery).
- Streaming MJPEG server support using the device camera.
- Screensaver feature that can be dismissed with motion or face detection.
- Support for Android 4.4 (API level 19) and greater devices.
- Support for launching external applications using intent URL

## Hardware & Software

- Android Device running Android OS 4.4 or greater. Note: The WebView shipped with Android 4.4 (KitKat) is based on the same code as Chrome for Android version 30. This WebView does not have full feature parity with Chrome for Android and is given the version number 30.0.0.0.

**_ If you have need support for older Android 4.0 devices (those below Android 4.4), you want to use the [legacy](https://github.com/thanksmister/wallpanel-android-legacy) version of the application. Alternatively you can download an APK from the release section prior to release v0.8.8-beta.6 _**

## Quick Start

You can either side load the application to your device from the [release section](releases) or install the application from [Google Play](https://play.google.com/store/apps/details?id=xyz.wallpanel.app). The application will open to the welcome page with a link to update the settings. Open the settings by clicking the dashboard floating icon. In the settings, set your web page or home automation platform url. Also set the code for accessing the settings, the default is 1234.

## Development

The project can be built from the command line with `./gradlew assembleProdDebug` (or `gradlew.bat assembleProdDebug` on Windows).

**JDK:** The project uses **Gradle 9.1.0**, which supports **JDK 17 through JDK 25** (including the latest OpenJDK 25). You can use your system’s latest JDK.

**Android SDK:** Set `ANDROID_HOME` to your Android SDK root, or create `local.properties` in the project root with:
`sdk.dir=C\:\\path\\to\\Android\\sdk` (Windows) or `sdk.dir=/path/to/Android/sdk` (macOS/Linux).

Use the `prod` flavor for a build that does not require `local.properties` secrets. For the `dev` flavor, optional entries in `local.properties` (e.g. `code`, `hassUrl`, `broker`) are used as BuildConfig defaults; the app runs without them (defaults are used).

## Building the Application

To build the application locally, checkout the code from Github and load the project into Android Studio with Android API 31 or higher.

**In this fork:** Google Services and Firebase are applied only when `google-services.json` is present. Without that file, the project builds without Firebase/Crashlytics—no need to remove dependencies manually. If you do want to use Firebase, add `google-services.json` and the following are applied automatically. Otherwise, you can remove these if you prefer a clean build without Google Services:

```
apply plugin: 'com.google.firebase.crashlytics'

implementation 'com.google.firebase:firebase-core:20.1.1'
implementation 'com.google.firebase:firebase-crashlytics-ktx'
implementation 'com.google.firebase:firebase-analytics-ktx'
```

Remove this if you are building the application for devices that do not support Google Services.

```
apply plugin: 'com.google.gms.google-services'

implementation 'com.google.android.gms:play-services-vision:20.1.3'
```

The project should compile normally.

## Limitations

Android devices use WebView to render webpages, This WebView does not have full feature parity with Chrome for Android and therefore pages that render in Chrome may not render nicely in Wall Panel. For example, WebView that shipped with Android 4.4 (KitKat) devices is based on the same code as Chrome for Android version 30.

This WebView does not have full feature parity with Chrome for Android and is given the version number 30.0.0.0. If you find that you cannot render a webpage, it is most likely that the version of WebView on your device does not support the CSS/HTML of that page. You have little recourse but to update the webpage, as there is nothing to be done to the WebView to make it compatible with your code.

Setting WallPanel as the default Home application will always load this application as your home. Removing this feature is difficutl without uninstalling the application. So please do this is you wish to use the application as a "kiosk" type application.

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
adb shell am force-stop xyz.wallpanel.app
adb shell am start -n xyz.wallpanel.app/xyz.wallpanel.app.ui.activities.BrowserActivityNative
```

(Use your build's application id — the fork used here is `xyz.wallpanel.app.kmb`, and debug
builds add `.dev`.) With the setting at `0` the force-stop is safe.

**The setting does not survive a reboot.** To make WallPanel turn DuraSpeed off by itself on
every start, grant it the permission to write secure settings:

```
adb shell pm grant xyz.wallpanel.app android.permission.WRITE_SECURE_SETTINGS
```

The app then clears the flag in `Application.onCreate`, before any WebView is built. This is
enough to recover an app that is *already* being suppressed, not just to prevent it — the
suppression is re-evaluated when the renderer is requested, so clearing the flag at startup
lets the renderer bind normally on that same launch. Without the permission the app logs that
it does not hold it and carries on; the permission cannot be granted without a computer, so
most installs will not have it.

If a load times out on a DuraSpeed device with no renderer attached, the app now says so and
offers the command above to copy, rather than sitting on a blank screen.

## Contribution

All are welcome to propose a feature request, report or bug, or contribute to the project by updating examples or with a PR for new features. Thanks to all the [contributors](graphs/contributors) who have contributed to the project!

## Special Thanks

- [TheTimeWalker](https://github.com/TheTimeWalker) for maintaining [wallpanel-android](https://github.com/TheTimeWalker/wallpanel-android) from 2022 until its archive in May 2025.
- [ThanksMister](https://github.com/thanksmister) for maintaining and continued development of [WallPanel](https://github.com/thanksmister/wallpanel-android/) for multiple years.
- [quadportnick](https://github.com/quadportnick) for starting [the original WallPanel (formerly HomeDash)](https://github.com/WallPanel-Project/wallpanel-android).

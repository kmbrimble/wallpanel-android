# DuraSpeed wedge — Stage 1 empirical findings (2026-09-02)

Device: Lenovo tablet, `192.168.0.52:5555`. App under test: `xyz.wallpanel.app.kmb` (kmb.8).
Trigger flag: `settings put global setting.duraspeed.enabled 1`.
Verdict columns: renderer `Start proc` logged; `ServiceRecord` bound state; render probe.

## Q1 — does a USER force-stop trigger the wedge?

**No. 5/5 pass via Settings; 2/2 wedge via adb with an identical user relaunch.**

| # | Force-stop caller | Relaunch | stop→launch gap | Renderer Start proc | hasBound | Probe | Result |
|---|---|---|---|---|---|---|---|
| Control | adb (shell uid 2000), pid 28896 | `am start -n` | 3.3s | none | false | STATIC-SMALL | **WEDGE** |
| 1 | Settings (system uid 1000), pid 32672 | launcher tap | 5.6s | 29908 | true | RENDERING | pass |
| 2 | Settings, pid 32672 | launcher tap | 1.9s | 30331 | true | RENDERING | pass |
| 3 | Settings, pid 32672 | launcher tap | 1.9s | 30710 | true | RENDERING | pass |
| 4 | Settings, pid 32672 | launcher tap | 0.46s | 31095 | true | RENDERING | pass |
| 5 | Settings, pid 32672 | launcher tap | 13.6s | 31486 | true | RENDERING | pass |
| 6 | **adb (shell 2000)** | **launcher tap** | ~7s | none | false | STATIC-SMALL | **WEDGE** |
| 7 | **adb (shell 2000)** | **launcher tap** | ~13s | none | false | STATIC-SMALL | **WEDGE** |

Trials 6-7 hold the relaunch constant against 1-5 and vary only the force-stop caller;
the outcome flips. **The force-stop caller is the discriminator.**

Disproven along the way:
- **Timing / stop→relaunch gap.** Passing gaps span 0.46s to 13.6s, straddling the
  control's wedging 3.3s on both sides. Not the axis.
- **Launch method.** Trials 6-7 wedge with a launcher tap; trials 1-5 pass with the
  same tap. Independently re-confirms CLAUDE.md's existing finding.
- **Cache state.** In trial 7 the user cleared app cache *between* the adb force-stop
  and the relaunch, and it still wedged. Upgrades CLAUDE.md's inference ("cache-clear
  is not the operative mechanism") to a direct measurement: the suppression state lives
  in `system_server`, not app storage.

**Caveat — do not overclaim.** This shows *Settings-initiated* force-stop is safe.
Low-memory kills, OTA updates and vendor task-killers are untested and may enter
DuraSpeed's suppress list by another route. Real-user exposure is lower than feared,
not zero.

## Q2 — does battery-optimisation exemption help?

**No. n=1, accepted deliberately.**

Granted `dumpsys deviceidle whitelist +xyz.wallpanel.app.kmb`; verified two ways before
the trial and **re-verified still active during the wedge** (`user,xyz.wallpanel.app.kmb,10191`).
Result: `hasBound=0`, `Pending ServiceRecord{...SandboxedProcessService1:0}`,
`binder=null requested=false received=false`, no renderer `Start proc`. Identical to the
un-whitelisted control — a total failure, not a partial one, which is why n=1 was accepted.

Doze allowlisting and DuraSpeed suppression are independent mechanisms: DuraSpeed is MTK
vendor code in `bringUpServiceLocked`, not part of AOSP `deviceidle`. Whitelist removed
afterwards and verified gone.

**No per-app DuraSpeed control exists on this device.** `com.mediatek.duraspeed/.DuraSpeedMainActivity`
is registered under `com.android.settings.action.EXTRA_SETTINGS` but is **not exported**
(`SecurityException ... not exported from uid 10154`) so adb cannot launch it; a user
search of Settings for "DuraSpeed" returned nothing. The Settings > Apps > Battery
Optimised/Unrestricted/Restricted control is standard AOSP battery mode, and "Unrestricted"
is the UI front-end for the same `deviceidle` allowlist already disproven above.
The Lenovo forum reports of a per-app lift-restriction control do not apply to this ROM.

## Q3 — what does a suppressed launch look like from inside the app?

Measured on a `devDebug` build (`xyz.wallpanel.app.dev`), which plants a Timber tree and
therefore logs; the **prod release build plants no tree at all** (`WallPanel.kt:34`,
guarded by `BuildConfig.DEBUG`) and emits nothing to logcat.

| Signal | Healthy launch | Suppressed launch |
|---|---|---|
| WebView constructed | yes | **yes** |
| `WebViewFactory` loads provider (151.0.7922.199) | yes | **yes** |
| `cr_LibraryLoader: Successfully loaded native library` | yes | **yes** |
| `loadWebViewUrl` → `webView.loadUrl()` | yes | **yes** |
| `cr_ChildProcLH: ScopedServiceBindingBatch.tryActivate` | — | `false`, then chromium **goes permanently silent** |
| `onReceivedError` | no | **never** |
| `pageLoadComplete` (BaseBrowserActivity.kt:273) | **+0.6s** | **never** |
| `progressHideTimeoutRunnable` (BrowserActivityNative.kt:73) | cancelled | **fires at +20.0s** |

Everything that could serve as a positive signal succeeds: WebView creation,
`getCurrentWebViewPackage`, native library load, `loadUrl`. Chromium never times out,
never errors, never gives up — it simply stops logging. Nothing propagates to
`onReceivedError`.

**The earliest reliable signal is therefore negative: `pageLoadComplete` failing to fire
within a timeout.** The codebase already has the exact hook — `progressHideTimeoutRunnable`
fires at 20s in precisely the wedged state (verified on prod in three separate wedges via view dump:
`WebView` VISIBLE full-size while `progressView` is GONE) and currently does nothing but
hide the spinner. So the wedged panel shows *nothing*, not even a spinner. Stage 2(c)
should replace that runnable's body, not add a new timer.

## Consequences for Stage 2

- Q2's good branch is **dead**: no `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` dialog, because
  the exemption doesn't work and no per-app DuraSpeed toggle exists. (c) must explain the
  adb path and say plainly that it needs a computer.
- Q1 lowers urgency but does not remove it: ordinary Settings force-stops are safe, so the
  wedge is not something users hit casually.
- (a)'s "log whether the write succeeded" is **invisible on the production build** — release
  plants no Timber tree. Use `android.util.Log` directly, or surface the result in-app.

## Addendum — is there a clean (non-force-stop) exit path? (2026-09-02)

A recents swipe is **not** a force-stop: it goes through `removeTask()`, which does not
call `forceStopPackage()` and does not set the package `stopped` flag. Tested three
candidate paths with `setting.duraspeed.enabled=1`. **All three are null results — none of
them killed the app, so none exercised the renderer-bind path, and none wedged.**

| Path | Command | Process killed? | `stopped` flag | Wedge? |
|---|---|---|---|---|
| Background + `am kill` | `input keyevent HOME; am kill <pkg>` | **no** — pid 2353 unchanged | false | n/a, no bind |
| Recents swipe (synthesised) | `keyevent APP_SWITCH; input swipe` | **no** — pid 2353 unchanged | false | n/a, no bind |
| SIGKILL | `kill -9 <pid>` | **no** — `Operation not permitted` | false | n/a |

- `am kill` only kills processes "safe to kill" (cached etc.). WallPanel runs a foreground
  service (`WallPanelService`), so it never qualifies.
- The recents swipe **did** remove the task (`dumpsys activity recents` count 1 → 0) but the
  process survived it — again the foreground service. Relaunching afterwards reused pid 2353
  with the renderer still bound and produced **no new `Start proc` at all**, so no new
  sandboxed-process bind was ever requested. Probe RENDERING throughout.
- `kill -9` fails from shell uid 2000; this device is not rooted (`adbd cannot run as root
  in production builds`, no `su`).

**Conclusions.**
1. **No clean adb exit path exists on this device.** Without root, `force-stop` is the only
   way to end this app's process from adb.
2. **A recents swipe cannot wedge the panel** — but not because it is gentler than a
   force-stop; because it doesn't kill the app at all. Don't record this as "swipe is safe,
   force-stop is dangerous"; the mechanism is the foreground service, not DuraSpeed.
3. **It is therefore useless as a user recovery route** — it restarts nothing. The hoped-for
   no-computer recovery for Stage 2(c) does not exist by this route.
4. Whether DuraSpeed keys on `forceStopPackage` specifically or on process death generally
   **remains untested**, because every non-force-stop path that could have isolated it is
   unavailable here. Root would be needed to settle it, and it isn't worth rooting the panel.

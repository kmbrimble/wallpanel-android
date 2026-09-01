# Modernisation session — overnight, three branches

NOTHING TOUCHES THE PANEL — no install, no adb, no smoke scripts, no device
access of any kind. User is asleep, will verify each branch themselves
tomorrow, in order, after the page-reload fix lands first (separately, not
part of this task).

Work each branch from current `master`. Do not merge any of them. Do not
build the release variant, do not sign anything, do not tag, do not create
releases.

## Branch order (one real dependency)

1. `feature/kapt-to-ksp`
2. `feature/dependency-sweep` (after KSP — newer Dagger may assume KSP)
3. `feature/minsdk-raise` (independent, order-free)

Each branches from `master`, not from the previous one. Textual conflicts in
build.gradle between them are expected and fine — resolved at merge time by
the user.

## Advisor checkpoints — every branch, full context each time

- BEFORE: plan for that branch, what's expected to break
- DURING: first non-obvious decision, whatever it is
- AFTER: review of the completed diff
- STUCK: any time a fix doesn't work first try, or trying variations of the
  same approach. Two failed attempts at the same problem = stop and ask.
  If advisor and I disagree, say so in the handback and which was followed.

## Definition of done, per branch

- `./gradlew assembleProdDebug` succeeds
- `./gradlew testProdDebugUnitTest` passes (CameraFpsPin tests)
- `./gradlew lintProdDebug` reports no NEW Fatal issues; note Error/Warning
  delta against baseline (0 Fatal, 18 Error, 304 Warning) but don't chase
  warnings
- committed and pushed, NOT merged

If a branch can't reach that state: leave it as far as it got, commit it,
state clearly what's broken and where. Honest half-finished beats forced
green.

## Branch 1 — feature/kapt-to-ksp

Migrate Dagger annotation processing from kapt to KSP. Build currently warns
"Kapt currently doesn't support language version 2.0+. Falling back to 1.9" —
Kotlin 2.x but kapt running in compat mode, half-finished migration inherited
from Darknetzz. Main risk: Dagger component generation. Report build time
before/after — KSP should be meaningfully faster.

## Branch 2 — feature/dependency-sweep

BOUNDED. Not "update everything".

In scope: Gradle wrapper 9.1.0 → 9.7.1, AGP to current compatible, Kotlin to
current stable, AndroidX to current stable. compileSdk may rise if a
dependency requires it.

Out of scope: targetSdk (leave exactly where it is — tablet is Android 12/API
31, behaviour changes gate on both device API and targetSdk, so raising it
changes nothing observable here while adding untestable risk). Also out of
scope: GMS Vision, ML Kit, camera stack — do not touch CameraFpsPin or its
test.

If a bump cascades, stop and ask advisor whether it's worth following; be
willing to drop that bump and note it. Report what was updated AND what was
deliberately left behind.

## Branch 3 — feature/minsdk-raise

minSdk 19 → 26. Delete legacy compat branches that become unreachable — value
is in the deletions, not the version bump. Use repository-reader to enumerate
`Build.VERSION.SDK_INT` checks and `VERSION_CODES` comparisons below 26,
remove dead paths. Conservative: if a check is below 26 but surrounding logic
is unclear, leave it and list it rather than guess — wrong deletion here is a
runtime crash not caught until the panel is live. Do NOT touch checks at 26+.

## Handback format

Per branch: advisor's answer at each of the four checkpoints and whether
followed; what built/didn't; lint delta; (branch 1) build time change;
(branch 2) updated vs dropped; (branch 3) SDK_INT checks removed vs left with
reasons.

Across all three: recommended merge order given what was learned, expected
conflicts. If any branch turned out to be a bad idea, say so plainly.

## HANDBACK (session complete, 2026-09-01)

All three branches pushed to origin, NOT merged. Nothing touched the panel — no install, no adb, no smoke scripts, no device access.

### Branch 1 — feature/kapt-to-ksp

**Result: does not do what its name says.** Full kapt→KSP migration is blocked upstream: `dagger-android-processor` has no KSP build (google/dagger#4044, open), and KSP's `@ContributesAndroidInjector` validation requires `AndroidProcessor` on the same processor path as `dagger-compiler`. Verified by build, not assumed — the split (dagger-compiler on KSP, dagger-android-processor on kapt) fails with unresolved bindings in `AndroidBindingModule.kt`. Reverted dagger-compiler to kapt.

The only real content: deleted the unused Glide kapt compiler line (no `@GlideModule`/`AppGlideModule` in this codebase, so it generated nothing). Warning count 304→301.

- Build time: unchanged (~38-62s range across runs, high variance from daemon warmup, not toolchain). Kapt's "doesn't support language version 2.0+" warning remains.
- Advisor BEFORE: measure baseline first, map out the edits, verify KSP/Kotlin version pairing before guessing — followed.
- Advisor DURING (Glide/dagger-android decision): searched for `@GlideModule` usage (none found, safe to delete), confirmed dagger-android-processor has no KSP support via web search before attempting anything — followed.
- Advisor STUCK (split failed on first attempt): diagnosed as structural (KSP validates the binding graph, no config fixes it), recommended trying the split exactly once and reverting cleanly on failure rather than iterating — followed, one attempt, reverted.
- Advisor AFTER: caught that the test run needed explicit verification (6 tests confirmed, not vacuous) and that "same error count" needed a content check, not just a number match (confirmed the 18 lint errors are the same errors, Glide-unrelated) — followed both.
- **Recommendation: bin this branch, or fold the one-line Glide deletion into feature/dependency-sweep.** It's a documented blocker plus a one-line change dressed as a migration branch.

### Branch 2 — feature/dependency-sweep

Forced chain, each link verified not guessed: user asked for Gradle wrapper 9.1.0→9.7.1 by version number → Gradle 9.6 removed an internal API all of AGP 8.x depends on (`InternalProblems`) → AGP 9.x is the only compatible choice, not a preference → AGP 9's built-in Kotlin can't host kapt (dagger-android-processor needs kapt) → two opt-out flags in gradle.properties (`android.builtInKotlin=false`, `android.newDsl=false`, both removed in AGP 10.0 mid-2026) → kapt itself broke under Kotlin 2.2 metadata (dagger's kotlinx-metadata reader capped at 2.1.0, confirmed by reverting Kotlin to 2.1.21 and finding AGP's own KGP runtime dependency overrides it anyway) → Dagger bumped 2.52→2.59.2 to fix that, not for its own sake.

**Updated:** Gradle 9.1.0→9.7.1, AGP 8.5.2→9.3.2, Kotlin 2.0.21→2.2.21, Dagger 2.52→2.59.2, vectordrawable 1.1.0→1.2.0, androidTest libs (junit/espresso/runner/orchestrator) to current stable.

**Updated but capped by minSdk 19** (this app's current stable is 2023-era because of it, not toolchain): appcompat→1.6.1 (current 1.8.0 needs minSdk 23), material→1.12.0 (current 1.14.0 needs minSdk 23), navigation→2.7.7 (current 2.10.0 pulls navigation-runtime-android requiring minSdk 24 — this is what forced a compileSdk 35 raise that was reverted once pinned back), lifecycle→2.8.7 (current 2.11.0 needs minSdk 23). Each cap verified by pulling the dependency's own AAR manifest, not discovered by build-failure iteration.

**Left unbumped:** constraintlayout (stayed at 2.1.4 — no version between 2.1.4 and 2.2.x declares minSdk ≤19, nothing to pin to).

**Deliberately out of scope, untouched:** targetSdk (per instructions), legacy-support-v13/v4/legacy-preference-v14 (terminal at 1.0.0, no newer version exists), play-services-vision, ML Kit, camera stack, OkHttp 3.x, RxJava2 (both carry real behavior-change risk on a credential-carrying network path; nothing asked for them). `android.enableJetifier=true` in gradle.properties triggered an AGP 9 deprecation warning and is almost certainly obsolete — flagged, not removed, since the sweep didn't ask for it.

- Advisor BEFORE: pick AGP 8.13.2 (latest stable 8.x) over 9.x to avoid a major-version DSL break on a legacy Groovy build script — this was the recommendation, and it was wrong. **Corrected mid-flight**: Gradle 9.6 removed the API AGP 8.x needs, so 8.13.2 was never viable once the wrapper went to 9.7.1. Reversed to AGP 9.3.2 once the build proved it. Said here explicitly since the user asked to flag disagreements/corrections.
- Advisor DURING (AGP major-version fork): confirmed via AGP 9.0 docs that minSdk floor isn't raised and `android.builtInKotlin=false` exists as an opt-out — followed, found the second required flag (`android.newDsl=false`) via one more targeted search after the first opt-out alone still failed.
- Advisor STUCK (Kotlin 2.2 kapt metadata error persisted after downgrading to 2.1.21): diagnosed that AGP's own KGP runtime dependency (2.2.10) was silently overriding the project's requested Kotlin version — confirmed via `buildEnvironment`, exactly right — and that the real fix was Dagger, not Kotlin. Followed; Dagger 2.59.2 fixed it in one build.
- Advisor AFTER: required a real clean-from-zero build (not incremental) and a transitive-dependency check before trusting the "capped by minSdk 19" claims — followed; confirmed `androidx.core` resolves to exactly 1.13.0 (the boundary), not luck.
- **Headline: minSdk 19, not any toolchain issue, is what's capping AndroidX versions at 2023-era releases.** This is the strongest argument for merging feature/minsdk-raise first.

### Branch 3 — feature/minsdk-raise

minSdk 19→26. Every branch deleted was already non-executing on the API 31 tablet (below-26 checks never fired there); every branch kept was already the live path. Runtime behavior on the panel is unchanged by this diff — verifiable without device access, which is the whole point of doing this branch tonight.

Removed ~26 runtime `SDK_INT` checks across 12 files (AppExceptionHandler, WallPanelService, BaseBrowserActivity, BrowserActivityNative, LiveCameraActivity, CameraSettingsFragment, SettingsFragment, ScreenSaverView, NotificationUtils, ScreenUtils, LauncherShortcuts). Cross-checked repository-reader's manual enumeration against `lintProdDebug`'s `ObsoleteSdkInt` list (run at minSdk 26) before editing — the two tools caught different subsets (raw-int comparisons vs. lint's static analysis) and agreed on every site once reconciled.

Also removed: multidex entirely (flag, dependency, `MultiDex.install()`, the now-trivial `attachBaseContext()` override — native multidex has applied since API 21), `tools:targetApi="n"` manifest hint, `drawable-anydpi-v24/` merged into `drawable-anydpi/`.

**Left, with reasons:** 8 sites at the exact O(26) boundary — per instructions, the user's to remove, not this branch's. 4 `@RequiresApi`/`@TargetApi` annotations below 26 — compile-time only, harmless, not chased. `mipmap-anydpi-v26` — same boundary rule. legacy-support-v13/v4/legacy-preference-v14 — still referenced (`androidx.legacy.widget.Space` in `fragment_about.xml:43`); "provably unreferenced" was the bar, this doesn't clear it. `vectorDrawables.useSupportLibrary` — unnecessary at minSdk 21+ but changes vector inflation paths, a behavior change not dead code.

- Advisor BEFORE: the enumeration/classification/deletion/verify shape, the inversion-trap warning (which branch is "live" flips with the comparison operator — do these edits by hand, never delegate), and using lint's `ObsoleteSdkInt` at minSdk 26 as an independent cross-check against repository-reader's enumeration — followed exactly; this is why the two-list reconciliation happened before any edit.
- Advisor AFTER: characterize the warning delta (304→321, +17) instead of leaving it unexplained — confirmed it's `ObsoleteSdkInt` firing on boundary/annotation sites that were invisible to lint at minSdk 19 (5→14), not a new issue. Put the "already-dead-on-this-device" runtime-safety argument in the commit message as the strongest reason the user can merge without a device check.
- Lint delta: 0 Fatal (unchanged), errors 18→8 (real fix — NewApi-class errors legalized by the raise, not a diff artifact), warnings 304→321 (+17, entirely `ObsoleteSdkInt` visibility, not new issues).

### Cross-branch recommendation

**Merge order: feature/minsdk-raise → feature/dependency-sweep → feature/kapt-to-ksp** (or bin branch 1 / fold its one line into the sweep, in which case it's a two-branch merge).

This inverts the order given at the start of the session. The reason: branch 2's AndroidX versions are hardcoded pins capped by minSdk 19, not automatic version ranges — merging branch 3 does **not** auto-unlock appcompat 1.8.0/material 1.14.0/navigation 2.10.0/lifecycle 2.11.0. After merging branch 3, a **post-merge re-sweep of the AndroidX bumps** is needed to actually reach current stable. Branch 1 has no ordering dependency on either (it never left kapt) and can merge whenever, or be binned.

**Expected conflicts at merge time:**
- `WallPanelApp/build.gradle`: `dependencies` block (branch 2's version bumps vs. branch 3's multidex/appcompat-line removal), `defaultConfig` (branch 3's minSdk line), `plugins`/kapt comment (branch 1 vs. branch 2's dagger version).
- Root `build.gradle`: `versions.dagger`/`versions.lifecycle` (branch 1 touches dagger version indirectly via comments, branch 2 touches both directly).
- `gradle.properties`: branch 2 only (`android.builtInKotlin`, `android.newDsl`) — branch 3 doesn't touch this file, so no conflict there.

All textual, all expected, resolved at merge time as anticipated at the start of the session.

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

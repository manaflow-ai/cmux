# Onboarding (launch, intro, sign-in) validation

Module: `CNAuthUI` (`SignInView`, `SignInIntroState`, `SignInChoreography`,
`TerminalLifeIllustration`, `SignInComponents`), launch assets in
`App/Shared/LaunchAssets.xcassets` (`UILaunchScreen` = `LaunchBackground` +
`LaunchMark`), and the hook in `CNAppShell/AppRoot.swift`
(`SignInView.exitTransition` / `exitAnimation`).
Reference: `ios-next/reference/claude-onboarding.md`.

Capture: `remote-ios.sh` slot `onboarding`, iPhone 17 Pro Max simulator
(iOS 26.5, 440 x 956 pt @3x, same screen as the reference device),
`CMUX_NEXT_DEV_SCREEN=signin CMUX_NEXT_SIGNIN_DEMO=1` (mock backend; the DEBUG
demo replaces Stack with a 0.9 s fixture latency so the code step can be
recorded without an inbox). Driven with `axe` (tap the email field, type,
tap Send code, type the code). `simctl recordVideo` writes variable frame
rate (only changed frames), so every number below uses real presentation
timestamps (`ffprobe frame=pts_time`), and springs are fitted on those
(`fit.py` model: SwiftUI `.spring(response:dampingFraction:)`, zero initial
velocity, onset free). Trackers: `/tmp/nxonb/tools/track_impl.py` (mark =
pixels with b − r > 80, headline/button luminance), not committed.

The recorder drops frames under load (gaps of 30–50 ms, and 200–500 ms
during process launch), so sub-frame timing is limited by the recorder, not
the app.

## Choreography

| element | reference | cmux-next (measured) | pass |
|---|---|---|---|
| launch → first app frame | identical pixels, no cross-fade | identical: max pixel diff 0 in the mark region between the launch-screen frame and the first app frame (flow2 frames 60–78) | pass |
| launch frame content | lockup centred (212, 478), 182.6 x 39.7 | mark alone centred (220, 478), 28 x 38–40 (the launch image only holds the mark; the wordmark types in) | by design |
| hold before hand-off | 0.46 s static | typing intro: cursor at +0.12 s, "cmux" typed 0.20–0.41 s, hand-off at +0.62 s from first app frame. From the launch image becoming visible: 1.04 s on the simulator, because Debug process launch drops 250–500 ms of frames | differs (adds typing; launch time is the sim's) |
| lockup flight y | 477.9 → 81.5 | 478.0 → 82.0 | pass (0.5 pt) |
| lockup flight spring | response 0.192 s, damping 1.00, 99 % at 0.203 s | run 2: 0.189 s / 1.00 / 0.199 s; run 4: 0.178 s / 1.00 / 0.188 s | pass (≤1 frame) |
| lockup scale | 0.587 | 0.587 (mark 40 → 22.9–23.5 pt) | pass |
| headline / buttons fade | 0.238 / 0.222 s, damping 0.88 / 0.92, settle 0.185 / 0.191 s | 0.176–0.201 / 0.191–0.199 s, damping 0.94–1.0, settle 0.181–0.210 s | pass (≤1 frame) |
| simultaneity | all elements start on the same frame | lockup, headline and buttons onsets within 4 ms of each other | pass |
| element movement during reveal | none (fade only) | none (fade only) | pass |
| cursor during flight | n/a | removed on the hand-off frame (lockup width 27 pt on the first moving frame) | pass |
| illustration start | T0 + 26 ms | T0 (same frame) | pass |
| illustration cadence | 12 fps (changes every 5th 60 Hz frame) | 12 fps (`TimelineView.periodic` 1/12 s, three boil variants) | pass |
| press feedback | scale 0.990, fill dims, label → spinner same frame, release ≈ 0.33 s | `InkCapsuleButtonStyle`: 0.99, fill opacity 0.94, `LoadingLabel` swaps on the same frame, release spring 0.33 s | pass (by construction; tap not recorded at 60 Hz) |

framediff (`reference/tools/framediff.py`, both clips resampled to 60 fps,
crop = button rows): first four post-onset frames ref 0.20 / 0.37 / 0.53 /
0.66 vs cmux 0.14 / 0.34 / 0.55 / 0.72 progress. Its duration figure
(ref 16 frames, cmux 6 frames) is distorted by the recorder's duplicated
frames in the resampled cmux clip and by the different button content;
the spring fits above use real timestamps and are the figure to trust.

## Geometry (settled sign-in, dark, Pro Max)

| element | reference (pt) | cmux-next (pt) | pass |
|---|---|---|---|
| header lockup | y 70.0–94.0, centred x 220 | y 70.3–93.7, x 184.0–255.0 (centre 219.5) | pass |
| illustration | ink y 281–461, ≈180 box | 180 x 180 box; ink y 314–434 (a 168 x 128 terminal window) | analogous |
| headline glyphs | y 509.0–537.3 | y 509.0–536.3 | pass |
| row 1 | — (Claude has two buttons + field) | Apple 635.3–683.3 | n/a |
| rows (pitch 56, 48 tall, x 16–424) | 691.3, 746.3, 803.3–851.3 | 691.3, 747.3, 803.3–851.3 | pass |
| footer glyphs | y 874.3–906.0 | y 874.0–907.0 | pass |
| side inset | 16 | 16 | pass |
| background | `#151515` | CNDesign `background` (`#1E1E1E` dark / `#FEFFFF` light), launch colour identical | by design |

## Steps (no reference: Claude's email and code steps are not in the recording)

| transition | behaviour | measured |
|---|---|---|
| options → email | tapping the field focuses it; the field glides up to under the title (same view, layout spring 0.42 s / 0.88) while hero, buttons and footer lift 17 pt, blur 8 and fade; title and subtitle rise 28 pt with 35 ms stagger | flow1/flow3, see `02-flow-overview.png` |
| email → code | "Send code" shows a spinner in place; then the email block exits up and the code block enters with the same stagger | spinner on the tap frame; step change on completion |
| code typing | each character drops in (scale 1.35 → 1, 10 pt fall, spring 0.28 / 0.62), selection haptic per character | |
| verify | auto-submits at 6 characters; a highlight wave runs over the cells | |
| accepted | cells fill with ink left to right (35 ms stagger), success haptic | fill 21.50 → 21.85 s (0.35 s) |
| exit to app | sign-in root swells to 1.06, blurs 16 and fades over the shell (spring 0.5 s, critically damped) | 22.21 → 22.70 s |
| wrong code | row shakes (−14, +12, −8, +5, −2, 0 pt over 0.38 s), error haptic, cells clear, message under the cells | measured offsets −14, +11, −8, +4 (`05-code-error-shake.png`) |
| back | glass chevron; reverses the step with the same springs | |

## Accessibility and appearance

| check | result |
|---|---|
| Reduce Motion | no typing and no flight: the centred mark fades out (0.1 s) and the settled screen fades in (0.1 s); illustration shows one still frame; step changes cross-fade; no shake. Recorded (`rm.mp4`): mark never leaves (206, 459) until the fade, header lockup appears in place, illustration static |
| Dynamic Type | buttons (`@ScaledMetric` 48 pt min height), headline (`@ScaledMetric` relative to largeTitle), code cells and footer scale; the illustration is dropped below 640 pt of height. Not captured at accessibility sizes |
| Light / dark | `04-screens-light.png`, `04-screens-dark.png`: options, email, code, verify-email. Ink capsules invert (white on dark, black on light) |
| Strings | every new string uses `String(localized:defaultValue:comment:)`; the Stack error messages in `SignInErrorPresentation` are unchanged English |
| VoiceOver | lockup is one header element "cmux"; illustration hidden; code field labelled "Sign-in code" |

## Not matching / open

- The hold before the hand-off is longer than the reference on the simulator
  (process launch of a Debug build); on device it is the 0.62 s typing intro.
- Claude's illustration runs a 10 s narrative; ours is an 8 s loop after a 1.1 s
  intro (window, prompt, cursor, Game of Life colony, gather, typed lines,
  erase). Different art by design.
- framediff's auto duration on the fade is unreliable with this recorder (see
  above).
- OAuth and real Stack email codes were not exercised end to end here (demo
  mode); the mechanism is unchanged from the previous `SignInController`.

## Artifacts

- `onboarding/01-handoff-ref-vs-cmux.png`: reference vs cmux at matched
  times after T0 (−50 ms … +300 ms).
- `onboarding/02-flow-overview.png`: launch → typing → hand-off → colony →
  email → code → accepted → exit → app.
- `onboarding/03-illustration.png`: the illustration at 1 s steps.
- `onboarding/04-screens-light.png`, `04-screens-dark.png`.
- `onboarding/05-code-error-shake.png`.

## V1 verifier fixes (2026-10-13)

Re-measured on `mini-cmux8s-mac-mini`, iPhone 17 Pro Max, iOS 26.5, slot
`onboarding` (the verifier's host family; its footer line height is 18 pt,
2 pt less than the first capture Mac, which is what moved the rows before).

| ID | fix | measured after |
|---|---|---|
| 1.1 | The first frame is drawn in the launch screen's (system) appearance and cross-fades to the app's Light/Dark setting immediately; `SignInView` resolves its colours in the setting from the first frame (`appearance:` from `AppRoot`) instead of waiting for the window override. | System light, app dark: launch screen white until the app's first frame (status bar change at 4.27 s), then 4.27 → 4.47 s fade to `#1E1E1E`; no hold of white inside the app. The launch screen itself cannot follow the app setting (UILaunchScreen uses the system appearance). |
| 1.9 | `AppRoot` paints the app background under the phase cross-fade, so the window's black never shows through. | Test login (real backend, dark): background luma 23–28 through sign-in → shell (was 2–5). Mock exit: 26–28. |
| 1.5 | "Send code" stays loading from the tap until the code step replaces it. | Button luma 125–130 (loading, disabled) from 13.37 s until the step's exit fade at 14.40 s; no return to white. |
| 1.3 | The footer has a fixed 70.7 pt slot under the rows, and its type is 13.6 pt with 2.4 pt line spacing, so rows no longer depend on the footer's line height. | headline 509.0–536.3, rows 635.3 / 691.3 / 747.3 / 803.3–851.3, footer glyphs 874.3–906.3 (ref 874.3–906.0), lockup 70.3–93.7; light identical. |
| 1.12 | Reduce Motion cross-fades the whole column between steps; each layer keeps the step it was built for. | Options → email: Apple row fades 212 → 28 over 9.30–9.53 s while the email field row fades in at the top; no element moves. |
| 1.13 | The lockup is a single header element (`accessibilityRepresentation`), the mark is decorative; the email field is labelled "Email address". | AX: `Heading 'cmux'` with no children; `TextField 'Email address'`. |
| 1.E | Accessibility text sizes drop the illustration, wrap the headline and scroll the column below the header. | `onboarding/06-dynamic-type-axxxl.png`: AX-XXXL top and scrolled to the end; nothing clipped, the footer is reachable. |

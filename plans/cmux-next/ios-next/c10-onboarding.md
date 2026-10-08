# C10 `onboarding`: first run for cmux-next iOS

Status: implemented on `feat-cmux-next-ios-c10-onboarding` (base `feat-cmux-next-ios`), 2026-10-06.
Binding: PLAN.md (this directory), a1-shell.md (seams, section 1.5 parity), ios-rewrite.md, REWRITE.md
visual rules, motion.md. Pairing runs on the `DeviceRegistry` mock until B6 lands.

## 1. Goals

Short, confident, learn-by-doing. A new user reaches a paired Mac in under two minutes, touches the
product (approves an agent, answers a question) before being asked for anything, and sees every
system prompt only after a priming screen that says why. Nothing in onboarding is required except
sign-in (the shell gates on an account today, a1-shell.md 1.20 item 14).

Parity with the shipping app (a1-shell.md 1.5): agents tour, notifications priming, push opt-in,
pairing (same-account discovery first, QR fallback), connect, resume at the remaining step, replay from
Settings, bypass for automation. Dropped: Tailscale and auto-connect migration sheets (no iroh), the
keep-awake card (Keep Mac Awake has no lane yet, C16; the celebrate step leaves room for it).

HIG references: Onboarding (https://developer.apple.com/design/human-interface-guidelines/onboarding:
teach by doing, keep it brief, let people skip), Privacy / Requesting permission
(https://developer.apple.com/design/human-interface-guidelines/privacy: ask in context, explain the
benefit before the system alert), Playing haptics, Motion (Reduce Motion alternatives), Accessibility.

## 2. Storyboard

Two phases. The progress bar counts only the steps that apply on this device right now (a step whose
condition is already met is never shown and never counted).

| # | Step | Phase | Shown when | Screen | Primary / secondary |
| --- | --- | --- | --- | --- | --- |
| 1 | `welcome` | intro | first run, intro not skipped; always in replay | Live mini terminal: an agent runs, asks to run tests, the phone approves, tests pass. Loops. | Get Started / I Have an Account |
| 2 | `approve` | intro | same | A real-looking permission card ("Claude Code wants to run `swift test`"). Tap Allow or Deny; the terminal answers. | Continue (enabled after a choice) |
| 3 | `reply` | intro | same | An agent question with two chips. Tap one; a reply bubble flies in, the agent continues. | Continue (enabled after a choice) |
| 4 | `signIn` | intro | signed out | The kept sign-in (embedded chrome) under "Sign in to connect your Mac". Advances on its own when auth reports signed in. | (provider buttons) |
| 5 | `notifications` | setup | signed in, permission not determined | Lock-screen preview of "Claude Code needs approval". | Turn On Notifications / Not Now |
| 6 | `installMac` | setup | no trusted Mac on the account | "Install cmux on your Mac": cmux.com/download, same account. Share sheet sends the link (AirDrop to the Mac). | It's Installed / Share Link |
| 7 | `localNetwork` | setup | no trusted Mac, local network never asked | "Find your Mac on this network" before the system prompt. | Allow / Not Now |
| 8 | `pair` | setup | no trusted Mac when entered | Same-account discovery (radar), found Macs, Connect, success morph. "Scan QR Code" opens camera priming, then the scanner. | Connect / Scan QR Code / Set Up Later |
| 9 | `sshHost` | setup | first run | Optional: host, user, port, saved through `HostsStore`. | Add Host / Skip |
| 10 | `celebrate` | setup | always | Glyph burst, "You're connected to <Mac>" (or "You're all set" when pairing was skipped). | Open cmux |

Rules:

- Skip in the header on intro steps jumps to sign-in (or past it when signed in). Setup steps each
  have their own Not Now / Skip / Set Up Later, recorded as `skipped`.
- Back is allowed inside a phase only (never from setup into sign-in or the intro). Celebrate has no back.
- Signing out mid-setup returns to `signIn`; signing in on `signIn` advances.
- Camera priming is inline in `pair`: Scan QR Code shows the primer when the camera was never asked,
  the scanner directly when granted, and a Settings deep link when denied.
- After 8 s of searching with nothing found, the pair step shows the help line and raises Scan QR Code
  to primary. The delay goes through an injected `Clock`.

## 3. State, persistence, resume

Pure model in `CmuxiOSOnboardingCore` (Foundation + FeatureKit):

- `OnboardingFlow` holds `OnboardingProgress` (current step, outcome per step, finished) and
  `OnboardingContext` (signed in, notification / local network / camera status, has trusted Mac, mode).
  `send(_:)` takes `advance`, `back`, `skipIntro`, `skipStep`, `contextChanged` and returns an
  `OnboardingTransition` (from, to, direction, finished).
- `init` normalizes a stored progress against today's context (resume): a step that no longer applies
  is passed over forward, a signed-out user in setup returns to sign-in.
- `OnboardingProgressStore` persists progress as JSON in an injected `UserDefaults` under
  `dev.cmux.ios.next.onboarding.v1`. Progress is client view state of this install (never synced).
- `OnboardingLaunchPolicy` decides at launch: `skip` for automation (dogfood readiness nonce, DEBUG
  auto sign-in credentials, Home or terminal previews, `CMUX_IOS_ONBOARDING=0`), `fresh` for
  `CMUX_IOS_ONBOARDING=1` (in memory, never written), `stored` otherwise. Skip and fresh never write
  the real install's progress. `CMUX_IOS_ONBOARDING_STEP=<step>` starts at a step (DEBUG screenshots).
- Replay (Settings > Replay Welcome Tour) runs the flow in `replay` mode in memory: intro, any
  undetermined permission, pairing only when no Mac is trusted, then celebrate. It never touches the
  stored progress and closes from the header.
- `PairingPhase` is a pure projection of the `DeviceRegistry` snapshot plus the local pairing intent:
  `searching`, `found([candidate])`, `pairing(id)`, `paired(name)`, `failed(message)`, `offline`.
  When an in-flight pairing loses its registry connection, the projection prefers `offline` over
  `pairing`; this keeps the retry action visible instead of leaving a spinner over a dead path. The
  same pairing intent is retained and can be confirmed by a later trusted-device snapshot.

Push permission moves out of sign-in: `PushRegistration.start(for:requestPermission:)` asks the system
only when the app passes `true`, which it does when onboarding will not prime. Otherwise the
notifications step asks, then calls `authorizationChanged()` so registration continues.

## 4. Motion spec

Tokens live in `OnboardingMotion` (one place, like motion.md's rule 1). Every animation is
interruptible and has a Reduce Motion form.

| Moment | Motion | Reduce Motion |
| --- | --- | --- |
| Step change | content slides 28 pt in the travel direction and fades in, spring response 0.32 / damping 0.9 (visible end ~200 ms); outgoing fades in 0.12 s | 0.15 s crossfade |
| Progress bar fill | spring 0.32 / 0.9 | instant |
| Vignette typing | per-line mask reveal in discrete steps of 1 character every 28 ms (Core Animation keyframes on the layer clock, no timers); output lines fade 0.18 s; permission card rises 16 pt with spring 0.3 / 0.82; Allow press flash; loop period 9.5 s incl. 2 s rest | static final frame |
| Cursor | opacity blink 1.0 s step | steady |
| Approve / reply choice | card collapses to a one-line receipt, spring 0.28 / 0.9; reply bubble scales from 0.9 at the chip, spring 0.3 / 0.82 | crossfade |
| Press | scale 0.97 instant, release spring 0.2 / 0.9 | no scale |
| Pair searching | two concentric rings scale 0.6 to 1.4 and fade, 1.8 s, offset by half (CA, repeat) | static ring |
| Paired | spinner to checkmark stroke 0.3 s ease-out | appear |
| Celebrate | `CAEmitterLayer` of gray terminal glyphs, 0.5 s birth then stop; title spring 0.32 / 0.82 | static checkmark |

Haptics: light impact on advance, selection on a chip, success on approve, paired and celebrate,
warning on a pairing failure. All through `OnboardingHaptics` (prepared generators, main actor).

Visual rules: no blue. Ink and grays from `HomePalette` / `ShellPalette`; the primary button is ink on
paper (inverted in dark mode); the vignette uses the label colors on a secondary system fill, with
status glyphs in the muted system green only.

## 5. Copy (en; ja in the catalog)

- welcome: "Your agents, in your pocket." / "cmux runs your terminals and coding agents on your Mac.
  Watch them, answer them, and keep them moving from anywhere."
- approve: "Approve from anywhere." / "When an agent needs permission, decide in one tap. Try it."
- reply: "Answer in a tap." / "Agents ask questions. Reply without opening your laptop."
- signIn: "Sign in to connect your Mac." / "Use the same account as cmux on your Mac."
- notifications: "Know when an agent needs you." / "Get a notification when an agent asks for
  approval or finishes. You choose which ones in Settings."
- installMac: "Install cmux on your Mac." / "Download it from cmux.com and sign in with this account.
  Your phone finds it automatically."
- localNetwork: "Find your Mac nearby." / "cmux looks for your Mac on this network for the fastest
  connection. Nothing leaves your network."
- pair: "Connect your Mac." / searching "Looking for Macs on your account…", help "Don't see it?
  Open cmux on your Mac, or scan the QR code from Settings > Pair iPhone."
- camera primer: "Scan the code on your Mac." / "cmux uses the camera only to read the pairing code."
- sshHost: "Have a server too?" / "Add an SSH host now, or later from Hosts."
- celebrate: "You're connected." / "<Mac> is ready. Your agents can reach you now." Skipped pairing:
  "You're all set." / "Connect a Mac anytime from Hosts."

## 6. What each step measures

`OnboardingMetricsSink` receives `stepShown(step, index, total)`, `stepFinished(step, outcome,
duration)`, `choice(step, value)` and `finished(totalDuration, paired)`. Today the sink is an OSLog
logger (`dev.cmux.ios`, category `onboarding`, public step names, no user data); C16 analytics plugs
into the same protocol.

| Step | Measures |
| --- | --- |
| welcome | time to first tap; Get Started vs I Have an Account |
| approve, reply | completion rate, choice, time to choose (learn-by-doing engagement) |
| signIn | reach rate, duration (provider is the auth module's own metric) |
| notifications | primer accept rate, then system grant rate |
| installMac | share-sheet use, time on step |
| localNetwork | primer accept rate |
| pair | path (discovery vs QR), time from entering to paired, failure reasons, help shown |
| sshHost | add rate |
| celebrate | completion, total onboarding duration, paired or not |

## 7. Modules and seams

- `CmuxiOSOnboardingCore` (Foundation, FeatureKit): flow, progress store, launch policy, pairing
  phase, metrics protocol. Platform-neutral, Swift Testing in `CmuxiOSOnboardingCoreTests`.
- `CmuxiOSOnboarding` (UIKit, SwiftUI): `OnboardingViewController` (container, header, transitions),
  step views, `TerminalVignetteView`, `CelebrationBurstView`, `OnboardingModel` (drives the flow,
  persists, measures), `PermissionCenter` (+ `SystemPermissionCenter`), `PairingModel`. Receives
  `OnboardingDependencies` (registry, hosts, permissions, clock, metrics, sign-in view factory, store).
- App: `OnboardingComposition` builds the dependencies; `RootViewController` keeps one onboarding
  controller across signed-out and signed-in, forwards auth changes, and installs the shell on finish.
  Settings gets a Replay Welcome Tour row through a closure (Shell never imports onboarding).
- `SignInScreen.makeEmbedded` exposes the kept sign-in without its standalone chrome.

Already-signed-in installs with no stored progress (an update from the earlier app) are treated as
onboarded and never interrupted, like the shipping app's paired-user exclusion. A user who chose Not
Now on the notifications primer is not prompted by push registration at the next launch.

Mocked until other lanes land: pairing (B6; `MockDeviceRegistry` trusts the discovered MacBook Pro),
the QR scanner (B6 owns the camera scanner; the onboarding scanner sheet is a viewfinder placeholder
with a sample code in DEBUG), SSH host save (C9 real `HostsStore`), Mac install link target.

## 8. Verification

- `CmuxiOSOnboardingCoreTests`: transitions, applicability, skip and back rules, resume normalization,
  sign-out return, replay, persistence round trip, launch policy, pairing phase, the hint delay on an
  injected clock. Run with `swift test` on macOS through a scratch package that links the same sources.
- `CmuxiOSApp` compiles for `arm64-apple-ios17.0-simulator` with SwiftPM.
- Tagged build `nxc10` through `ios/scripts/reload-cloud.sh`: BLOCKED on 2026-10-06. The same-tag Mac
  leg failed on the dev backend VM (`cmux-dev-backend-1` SSH timeout); with
  `CMUX_DEV_BACKEND_MODE=local` there was no fleet manifest (`~/.config/macfleet/hosts.json`), and the
  local fallback refused at 17 GiB free (floor 40 GiB). No install, no screenshot; the screens are
  unverified on a device. Rerun the same command when a fleet slot or disk is available, with
  `CMUX_IOS_ONBOARDING=1` (and `CMUX_IOS_ONBOARDING_STEP=<step>` for a single screen).

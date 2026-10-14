# Shell, sign-in and settings: validation

Owner slot `shell`. Modules: `CNAppShell`, `CNAuthUI`, `CNSettingsUI`,
`CNDesign/CNShellChrome.swift`, the Stack exchange call in `CNBackend`, relay-only
handling in `CNTransportWebRTC`, `App/`, `scripts/remote-ios.sh`.

Captures: iPhone 17 Pro simulator (402 x 874 pt, @3x) on the remote build Mac,
`simctl io recordVideo`, resampled to 60 fps. Recordings are variable frame
rate; repeated frames are recorder drops, not app hitches. Contact sheets are in
`validation/shell/`.

## Launch hooks (DEBUG)

| Env | Effect |
| --- | --- |
| `CMUX_NEXT_DEV_SCREEN=conversations\|agents\|terminal\|browser\|settings` | That module root alone, mock host + mock backend |
| `CMUX_NEXT_DEV_SCREEN=drawer\|tabs` | Full shell (forced), mock host, signed in |
| `CMUX_NEXT_DEV_SCREEN=signin\|onboarding` | Sign-in screen / "Connect your Mac" with the mock backend |
| `CMUX_NEXT_MOCK=1` | Whole app on mock host + backend, shell from Info.plist |
| `CMUX_NEXT_SIGNIN_MODE=methods\|code\|emailVerification`, `CMUX_NEXT_SIGNIN_EMAIL` | Start the sign-in card in a mode |
| `CMUX_NEXT_APPEARANCE=light\|dark\|system` | Settings > Appearance |
| `CMUX_NEXT_FORCE_RELAY=1\|0` | Settings > Force relay (TURN) |
| `CMUX_NEXT_START_DESTINATION=home\|agents\|terminals\|browser\|settings` | Initial shell destination |
| `CMUX_NEXT_TEST_LOGIN_EMAIL` + `CMUX_NEXT_TEST_LOGIN_SECRET` | `/v1/auth/test` login (live backend) |

## Drawer (push-aside) motion

No ChatGPT reference recording exists, so the target is the spec from the task.
Card x was measured per frame by template tracking (a card element while
closed, the sidebar's Home row while open, plus the 338 pt open offset);
release segments were fitted to a SwiftUI spring
(`tools`: `/tmp` scripts, numbers below). Recording: `drawer3.mp4`
(drag open, tap sliver, drag open, drag closed from the sliver).

| Element | Target | Measured | Result |
| --- | --- | --- | --- |
| Card follows finger | 1:1 | 6.0 pt/frame card for 6 pt axe steps during both drags (frames 101-122, 397-415, 542-560) | pass |
| Touch slop before tracking starts | (not specified) | 18-19 pt: card lags the finger by the pan recognizer's hysteresis (finger 200 pt, card 181 pt) | note |
| Sliver when open | 60-70 pt | 64 pt (card x settles at 338.0 on a 402 pt screen) | pass |
| Card scale | none | none (template correlation 0.99-1.0 at constant size) | pass |
| Dim on card at open | 0.3 alpha | `DrawerSpec.maxDim = 0.3` black on the card, scaled by progress | pass (by construction; visible in sheets) |
| Release spring, drag open (181 -> 338) | response 0.35-0.40, damping ~0.9 | response 0.380, damping 0.90 (rmse 0.23 pt); within 1 pt after 19 frames | pass |
| Release spring, second drag open (147 -> 338) | same | response 0.375, damping 0.91 (rmse 0.22 pt); 20 frames | pass |
| Release spring, drag closed (96 -> 0) | same | response 0.375, damping 0.90 (rmse 0.21 pt); 17 frames | pass |
| Tap sliver to close (338 -> 0) | same, from rest | response 0.405, damping 0.89 (rmse 0.74 pt, first frame dropped by the recorder); 21 frames, overshoot 0.7 pt | pass |
| Theoretical settle for 0.38 / 0.9 from rest | | 21 frames to within 1 pt of 338 pt | matches tap close |
| Velocity carry-over | velocity-aware | release velocity passed as `UISpringTimingParameters.initialVelocity`; fits show v0 2.75-7.75 distance/s on drag releases | pass |
| Interruptible | grab mid-flight | pan `.began` reads the presentation layer and stops the animator | implemented, not recorded |
| Reduce Motion | respected | 0.2 s ease-out instead of the spring | implemented, not recorded |
| Swipe from anywhere | right swipe on non-horizontal-scroller content | opens from mid-screen on the conversation list (frames 101-146); horizontal scrollers that can scroll back, sliders/switches and pushed navigation stacks keep the swipe | pass (scroller exclusion not recorded) |

Sheets: `shell/drawer-drag-open.png` (frames 100-160), `shell/drawer-tap-close.png`
(frames 241-267), `shell/shells.png` (drawer closed/open and tabs, light/dark).

## Sign-in

The view, copy, layout, glass styles, Game of Life header and assets
(`CmuxSignInMark`, `GoogleLogo`, `GitHubLogo`) are ported from
`ios/CmuxiOS/Sources/CmuxiOSAuth/SignIn/*`. Prominent buttons are system blue
because cmux iOS's `AccentColor` is the unset system default.

| Element | Reference (cmux iOS) | Measured | Result |
| --- | --- | --- | --- |
| Mode switch animation | `withAnimation(.snappy(duration: 0.18))`, crossfade between cards | same code path; code -> methods: new header opacity 2.6 -> 21.5 (darkness units) over frames 119-126 (~0.13 s visible ramp, settle by 0.18 s), positions jump without slide | pass (cmux iOS itself not recorded side by side) |
| Three modes | methods / emailVerification / code | all three captured light and dark (`shell/signin.png`) | pass |
| Restore status | "Restoring session" with 10 s timeout and Retry | ported, shown while `AuthSession.state == .restoring` | not captured (restore is near-instant) |
| Mechanism | Stack Auth magic link (nonce + code), OAuth apple/google/github | `SignInController` over `StackClientApp` (memory token store), then `POST /v1/auth/stack {accessToken, projectId}` | built; not exercised end to end (would send real email / OAuth) |
| Projects | production `9790718f...` in every configuration (the backend disables the dev project) | `StackAuthEnvironment.current()` is `.production` | pass. The cmux iOS DEBUG `42` shortcut was removed: `l@l.com` returns `EMAIL_PASSWORD_MISMATCH` on the production project |

Sheet: `shell/signin-mode-switch.png` (frames 117-129).

## Screens (mock host)

`shell/signin.png` (3 modes x light/dark), `shell/onboarding-settings.png`
(Connect your Mac light/dark with the host CLI commands and pairing code field,
Settings), `shell/shells.png` (drawer closed/open and native tabs with the
bottom accessory and minimized tab bar, light/dark).

## Real host (live backend `cmux-next-mobile.debussy.workers.dev`, test account, host `cmux15`)

| Check | Result |
| --- | --- |
| `/v1/auth/test` login, hosts list, signaling presence, auto-select cmux15 | pass |
| Direct path: simulator on the same LAN as cmux15 | pass: Settings shows "Direct (LAN)" (`real-host.png` 1st) |
| Natural path from the remote build Mac (different VLAN, same public IP, no hairpin) | relayed: "Relayed via TURN", local relay / remote srflx, RTT 386 ms; stable for minutes |
| Terminal over the real link | pass: new zsh on cmux15, typed `echo ... && uname -n`, output `cmux15.local` (then `exit`) |
| Agents list over the real link | pass: list loads (no sessions on that host: empty state) |
| Force relay (TURN) toggle | FAIL: link opens relay->relay with `policy:"relay"` (host log `link open [relay only] relay/UDP -> relay`), hello succeeds, then the phone's ICE goes `disconnected` and the link closes after 18-50 s ("Lost the connection to your Mac."), then reconnects in a loop. Seen from both simulators. Non-forced relay (local relay, remote srflx) stays up. Needs a transport/host look at relay<->relay consent through Cloudflare TURN. |

## Status bar hook and HEAD smoke run

The app now launches through a UIKit scene delegate (`CmuxNextSceneDelegate`)
whose root `ShellHostingController` overrides `preferredStatusBarStyle`. Roots
call `.cnStatusBarStyle(_:)` (CNShellChrome); both shells collect it with
`.onCNStatusBarStyleChange` (hidden roots are suppressed; the drawer reports
default while the sidebar is open). CNBrowserUI publishes
`CNStatusBarStyle(over: frame.topColor)` for the visible page.

| Check | Expected | Result |
| --- | --- | --- |
| Dark appearance, real host, example.com (light page) | black clock | black clock (`smoke-and-statusbar.png`, last tile) |
| Mock cmux.dev page (purple header) | white clock | white clock |
| Start page | follows appearance | follows appearance |
| Clean build of HEAD `d0284962d2f` (git archive), Drawer and Tabs | succeed | both succeed |
| `CMUX_NEXT_DEV_SCREEN` conversations, agents, terminal, browser, settings, signin, onboarding, drawer, tabs | each renders | all render (`smoke-and-statusbar.png`) |

Note: installs made before the UIKit lifecycle restore a SwiftUI scene session
and show a black window; `remote-ios.sh` now uninstalls once per slot.

## Known gaps

- Forced relay is unstable (above). Phone side implements PROTOCOL §5:
  `policy:"relay"` offer, `iceTransportPolicy = .relay`, non-relay remote
  candidates dropped, link refused unless the selected local candidate is relay.
- Drawer touch slop (18-19 pt) is not compensated; the card follows finger
  velocity 1:1 from recognition.
- Sign in with Apple via Stack's native flow uses the identity token for bundle
  `dev.cmux.next.*`; the Stack projects must accept that client id. Not tested.
- OAuth/magic-link not run end to end in automation (real email / provider UI).
- Unsigned simulator builds have no keychain entitlement; the session then lives
  in memory for the launch (`SessionTokenStore`).
- In the tab shell, the Conversations root's own floating search/compose bar
  sits behind the minimized tab bar (module-side layout).
- `simctl ui appearance dark` did not take on the headless simulator; dark
  captures use `CMUX_NEXT_APPEARANCE=dark`.

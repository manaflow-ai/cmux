# Acceptance: cmux-next iOS V1

Written by the acceptance author for the verify-implementation skill (Step 1),
before verification. The verifier judges the build against this file; the
implementer does not grade their own work.

**What is under test**

| Tag | Commit | Contents |
|---|---|---|
| `cmux-next-ios-v1` | `719832dad64d` (branch `feat-cmux-next-ios-app`) | the app (`ios-next/App`, `Packages/CmuxNextMobile`), the host (`ios-next/host`) and the backend (`ios-next/backend`) |
| `cmux-tabs-kit-v1` | `297a67c57ef1` (branch `feat-cmux-next-tabs-kit`) | `Packages/iOS/CmuxTabsKit` and its demo app |

Build exactly these SHAs. Use `remote-ios.sh build --ref`, or a `git archive`
of the tag. Never build a working tree. Record the SHA in every evidence
folder.

**Areas**

| § | Area | Status at V1 |
|---|---|---|
| 1 | Launch, onboarding, sign-in | in V1 |
| 2 | Shells (Drawer, Tabs), pairing, Settings | in V1 |
| 3 | Conversations and Chief | in V1 |
| 4 | Agents | in V1 |
| 5 | Terminals | in V1 |
| 6 | Tabs grid and browser (Safari UX), including **6A swipe-to-close** | in V1 |
| 7 | Connectivity, backend, host, bridge, security | in V1 |
| 8 | CmuxTabsKit | in V1 (kit tag) |
| 9 | Full-color terminal cards | **post-V1. Expected to fail on V1.** It is recorded so the gap is visible. It does not block V1 |

## 0. Rules that apply to every area

### 0.1 Environment

- **Simulator only.** Never use a physical phone (user rule).
  - Use iPhone 17 Pro (402 × 874 pt) and iPhone 17 Pro Max (440 × 956 pt) on the iOS 26 runtime. Also use the iOS 27 runtime where the build Mac has it.
  - Run them headless through `ios-next/scripts/remote-ios.sh` with `--slot <area>`. While `aziz-other-macbook` is offline, use `CMUX_NEXT_IOS_HOST=mini-cmux15`.
- **Shells:** `--scheme Drawer` and `--scheme Tabs`.
- **Hosts:**
  - **Mock:** `CMUX_NEXT_MOCK=1`, or `CMUX_NEXT_DEV_SCREEN=<module>` for a single module. Add `CMUX_NEXT_MOCK_TERMINAL_MIRROR=104x40` where mirrored terminals matter.
  - **Real:** the cmux15 host bridged to the official cmux-next. Sign in with the test login (`CMUX_NEXT_TEST_LOGIN_EMAIL` / `CMUX_NEXT_TEST_LOGIN_SECRET`).
  - **Backend:** `cmux-next-mobile.debussy.workers.dev`.
- **Appearance:** use `CMUX_NEXT_APPEARANCE=light|dark`. `simctl ui appearance` does not take effect on the headless simulator.
- **Reduce Motion:** set it with the simulator accessibility setting through `remote-ios.sh sim`.
- **Shared host.** Other agents use cmux15 and the test account. Before the run, record their activity: the host.log client count and the load average. Use a dedicated terminal and conversation names with a unique prefix (`v1-<run>`).

### 0.2 Evidence conventions

- **Screenshots** come from `remote-ios.sh shot`, at the stated state, in light and dark unless the item says otherwise.
- **Videos** come from `remote-ios.sh video`. They are variable frame rate, so all timing uses real `pts_time` from `ffprobe`. Never assume 60 fps.
- **Frame splits and contact sheets** carry their timestamps. Use `browser-tools/winsheet.py` / `rangesheet.py`, or `verify-ui-video`.
- **Springs** are fitted with `springfit.py` / `springv.py` (SwiftUI model: stiffness (2π/R)², damping 4πζ/R). Report R, ζ, rms, and the frame count.
- **Gestures** are driven by AXe (`remote-ios.sh axe -- ...`), with each gesture's start, end, duration and derived velocity logged.
- **Multi-touch:** AXe has none. Pinch uses the DEBUG scripted pinch hooks, and the report must say so. A scripted pinch proves the handler, not the recognizer.
- **Output location:**
  - Artifacts go to `~/nxios-ref/verify-v1/<area>/`.
  - Sheets are committed as at most 400 KB PNGs to `ios-next/reference/validation/v1/<area>/`.
  - The verifier's report lists every artifact against its criterion ID.
- **Recorder noise.** The simulator recorder drops or bunches frames under load. Record the host load average. A timing criterion fails only when the deviation exceeds both the tolerance and the noise band measured by repeating the same gesture three times. With fewer than three runs, report it as "inconclusive", never as a pass.

### 0.3 Tolerances used throughout

| Kind | Tolerance |
|---|---|
| Static geometry against a reference | ±0.5 pt for positions and sizes (±1 pt where the reference itself was glyph-ink measured) |
| Spring constants against a measured reference | R ± 0.04 s, ζ ± 0.05, and settle time within 2 frames. Use the corrected constants in `browser-springs-verify.md` where it disagrees with older rounds |
| Spring constants against a spec (no recording) | the in-app trace (`CMUX_CONV_TRACE=1` and similar) fits the spec within R ± 0.01 s and ζ ± 0.02 |
| Finger tracking | 1:1 ± 3%, lag ≤ 1 frame (16.7 ms) |
| "No jump" | consecutive frames differ only by translation. No frame-to-frame step over 5 px (1.7 pt), and the residual after translation is ≤ 7/255 mean gray |
| Colors against a reference | ΔE2000 ≤ 3 for fills, ≤ 6 for glyph ink |

### 0.4 Profiling standard (for performance-sensitive areas)

- Use xctrace or Instruments on the simulator with a Release build of the tagged SHA (instruments-profiler skill).
- Each trace reports the `.trace` path, a screenshot of the track, and the metric values against their bounds.
- Each trace is compared with the same scenario on the parent commit where one exists. A regression of more than 20% fails, even inside the bound.
- The simulator cannot measure GPU or thermal behavior or true device frame pacing. Report those as "unmeasured (simulator)", never as passes.

### 0.5 Pass rule

- V1 passes when every criterion in §1–§8 passes on its minimum full-pass matrix, every listed edge case behaves as stated, and every evidence row exists and was reviewed frame by frame.
- Missing evidence counts as a failure.
- A criterion marked **known gap** must be reproduced and documented, not fixed. Its failure is recorded and does not block V1, unless it is also listed as a blocker.
- §9 is reported separately as "post-V1".

---


## User decisions (2026-10-13/14)

- **Row swipe vs drawer (2.4 vs 3.5):** deferred by Aziz ("ignore for now"). Neither outcome fails V1; record the observed behavior only.
- **Launch appearance (1.1):** accepted as designed. The system launch screen follows the iOS appearance; only the app's own frames must match the app setting and hand off without a flash.
- **Performance gates:** dropped for V1 (hitch traces can't be recorded on the simulator and device runs are ruled out). T-* traces are informational, not pass/fail, until a later version.

## 1. Launch, onboarding, sign-in

References:

- `reference/claude-onboarding.md`, which holds the Claude reference recording.
- `validation/onboarding.md`.
- `validation/shell.md` (sign-in).
- Module `CNAuthUI`, and `AppModel` for the revoked notice.

### Behaviors

- **1.1 Launch hand-off.** The first app frame is pixel-identical to the launch screen in the mark region (max diff 0). There is no white or black flash between them in either appearance.
- **1.2 Intro choreography (reference: Claude).** This covers the lockup flight, the headline and buttons fade, and simultaneity.
  - Lockup flight: y 478 → 82 ± 0.5 pt, scale 0.587 ± 0.005, spring R 0.19 ± 0.02 s, ζ 1.0 ± 0.05.
  - Headline and buttons: fade with settle 0.18–0.21 s, and no element moves during the reveal.
  - Simultaneity: the onsets of the lockup, headline and buttons fall within 1 frame of each other.
  - The illustration runs at 12 fps (it changes every 83 ± 5 ms).
- **1.3 Settled geometry (Pro Max, dark).** The lockup, headline, button rows (pitch 56, height 48, x 16–424), footer and 16 pt side inset match the `onboarding.md` geometry table within ±0.5 pt. The background is CNDesign `background` (#1E1E1E dark, #FEFFFF light).
- **1.4 Email step.** Tapping the field glides it under the title (layout spring 0.42 / 0.88). The hero, buttons and footer lift 17 pt, blur and fade. Back reverses the step with the same springs.
- **1.5 Code step.**
  - Send code shows a spinner on the tap frame, then the code cells.
  - Each typed character drops in (scale 1.35 → 1, spring 0.28 / 0.62).
  - The code auto-submits at 6 characters.
  - On success, the fill runs left to right with a 35 ms stagger (about 0.35 s).
  - The exit to the shell runs a 1.06 swell, blur 16 and fade (spring 0.5 s).
- **1.6 Wrong code.** The row shakes −14, +12, −8, +5, −2, 0 pt over 0.38 s (±2 pt per peak), the cells clear, and an error message appears under the cells. No navigation happens.
- **1.7 Stack Auth mechanism.** The magic link, email code and OAuth buttons call Stack's production project. Their success leads to `POST /v1/auth/stack`, which returns tokens. Do not send real email or OAuth in automation. Instead, verify with the backend tests (§7.10) and a log line showing the request shape. In-app, `CMUX_NEXT_SIGNIN_DEMO=1` provides the visual flow.
- **1.8 Test login.** With the test-login env, a cold launch reaches the shell with cmux15 online within 10 s on an idle host. Record the cold launch → host `hello` time; the reference is about 3.7 s.
- **1.9 Sign out, then sign in.**
  - Settings › Sign out returns to the sign-in screen within 1 s and closes every link: host.log shows `bye` or the link closing within 5 s.
  - It clears tokens and the cached host list.
  - Signing in again, through the test login, reaches the same host with no stale data from the previous session (no old conversations flash in).
- **1.10 Revoked session.** Revoke the family: refresh-token reuse, or a server-side revocation of the test account's family through the backend test endpoint or a script. The app returns to sign-in showing "Signed out on this device." (`auth.revoked.notice`) within 5 s of the `revoked` frame or the 4005 close. It never loops on reconnect.
- **1.11 Restore.** A relaunch with a valid stored session skips sign-in. On a slow restore it shows "Restoring session" with a 10 s timeout and Retry.
- **1.12 Reduce Motion.** There is no typing and no flight: the mark fades out in about 0.1 s and the settled screen fades in. The illustration is still. Step changes crossfade. There is no shake.
- **1.13 Accessibility and strings.**
  - The lockup is one header "cmux". The illustration is hidden from VoiceOver. The code field is labeled "Sign-in code".
  - New strings are localized. User-facing copy names no internal vendor (Stack, Cloudflare, PlanetScale). Grep the strings catalog and screenshots.

### Edge cases

- Kill the app mid-code-entry and relaunch: it returns to a sane first step, without a stuck spinner.
- An expired code produces the error path, not a crash.
- Airplane mode (simulator network link conditioner, or the backend unreachable) on Send code shows an error within 15 s, and the button is usable again.
- Dynamic Type at the largest accessibility size: nothing is clipped, and the illustration is dropped below 640 pt of height.
- Pasting a 6-digit code into the first cell fills all six cells.

### Evidence

| ID | Evidence |
|---|---|
| 1.1–1.3 | A Pro Max video of a cold launch, light and dark. A ref-vs-ours contact sheet at matched times from −50 to +300 ms. Spring fit tables. A geometry table from the AX tree and ink boxes |
| 1.4–1.6 | Videos with frame splits of the email step, code typing, success exit and wrong-code shake. A per-frame shake offset table |
| 1.7 | Backend vitest output for Stack and email sign-in, plus the app log line showing the request |
| 1.8–1.11 | Videos and host.log excerpts with timestamps. Screenshot of the revoked notice |
| 1.12–1.13 | A Reduce Motion video, a VoiceOver AX dump (`axe describe-ui`), and the strings grep |

**Minimum full pass:**

- Pro Max: Drawer, mock, light and dark (1.1–1.6, 1.12, 1.13).
- Pro: Tabs, cmux15 (1.8–1.11).
- Pro: Drawer, cmux15 (1.9).

---

## 2. Shells, pairing, Settings

References: `validation/shell.md`, and the modules `CNAppShell`, `CNSettingsUI`
and `CNDesign/CNShellChrome`.

### Drawer shell

- **2.1 Push-aside.** A right swipe from anywhere moves the card 1:1 once the pan is recognized; the pan threshold is 18–19 pt and is recorded as is.
  - The card has no scale.
  - It rests with a 64 ± 2 pt sliver.
  - The card dims to black at 0.3, scaled by progress.
- **2.2 Release spring.** R 0.375–0.405 s, ζ 0.89–0.91, carrying the release velocity. Closing by tapping the sliver uses the same spring from rest and settles in 21 ± 2 frames.
- **2.3 Interruptible.** Grabbing the card mid-flight stops it at its presentation position, with a jump of 1 pt or less.
- **2.4 Gesture exclusions.** Horizontal scrollers that can scroll back, sliders, switches, a pushed navigation stack, and the terminal's scroll pan keep the swipe. The drawer does not open on them.
- **2.5 Sidebar content.** The sidebar shows Home, Agents, Terminals, Browser (or Tabs) and Settings sections with live rows. Tapping a row opens the right destination; this checks e2e bug 7, wrong tab. The hamburger in a browser page and in the overview opens the drawer; this checks e2e bug 6.
- **2.6 Reduce Motion.** The open and close become a 0.2 s ease-out.

### Tabs shell

- **2.7 Tab bar.** It has Home, Agents, Tabs and Settings. The bottom accessory shows the host and path, for example "cmux15 · Direct". The tab bar minimizes on scroll as the system does.
- **2.8 Accessory.** Tapping it opens Agents with the tab bar visible. Going back to Home restores the thread state. This is a regression check for e2e bug 1. The bar must never stay hidden after any sequence of the accessory, a push and a tab switch.
- **2.9 Tab bar hiding.** The bar hides only while a conversation thread is on screen, and is restored on pop or tab switch (§3.10).

### Pairing and onboarding ("Connect your Mac")

- **2.10 No paired Mac.** An account with no paired host shows "Connect your Mac", with the host CLI commands and the pairing code field.
- **2.11 Pairing.** Enter a fresh `userCode` from `hosts/pair/start` (a throwaway host process or a backend script).
  - `pair/approve` succeeds, and the host appears in Settings › Macs within 10 s.
  - A wrong code produces an inline error.
  - 10 wrong attempts within 10 min produce a rate-limited message (429), not a crash.
  - The host side must confirm `approverEmail` before using the token (§7.5).
- **2.12 Host offline.** With the only host offline, the shell shows the offline state, not a spinner forever. Recovery is automatic once the host returns.

### Settings

- **2.13 Account.** It shows the email and has Sign out (§1.9).
- **2.14 Macs.** It lists each host with its online state and OS ("Online · macOS 27.0.0"), and lets you select one. Removing a host (`DELETE /hosts/:id`) updates the list through `presence removed:true`.
- **2.15 Connection path.** The label matches the selected candidate pair on both ends.
  - It reads "Direct (LAN)" or "Direct" for host/srflx pairs, and "Relayed via TURN" for relay.
  - Cross-check against host.log for the same `sessionId`. The two must agree; this checks e2e bug 9. A mismatch is a failure.
  - RTT is shown and updates.
- **2.16 Force relay.** Toggling it reconnects with `policy:"relay"`. Both ends select relay/relay, and the label reads "Relayed via TURN". It meets §7.3's stability bound.
- **2.17 Appearance.** System, Light and Dark apply immediately everywhere: the shell, the modules, terminal themes and the status bar style.
- **2.18 Terminal font size.** It ranges 9–24 with a default of 13, in the same key as the terminal (`cmuxNext.terminalFontSize`). Changing it in Settings resizes open owned terminals. Changing it in the terminal menu updates Settings; this checks e2e bug 18.
- **2.19 Browser bring-forward.** The toggle "Bring tabs forward on Mac automatically" defaults to off. When on, opening a Mac browser tab on the phone brings it forward on the Mac, verified in the host log or with a CDP `activate`. When off, no activate call is made.
- **2.20 Status bar.** It shows a black clock over light pages and a white clock over dark pages, and follows the appearance on the Start page.

### Edge cases

- Rapid drawer open and close (10 times in 3 s) leaves no stuck dim and no offset card.
- Switching tabs during a push animation.
- Changing appearance while the drawer is open.
- Toggling Force relay twice quickly ends in a single link in the final policy, with no reconnect loop.
- The app is killed during pairing.

### Evidence

| ID | Evidence |
|---|---|
| 2.1–2.6 | A drawer video (drag open, tap sliver, drag closed). A card-x per-frame track with spring fits. A sheet like `shell/drawer-*.png` |
| 2.7–2.9 | A Tabs video of the accessory → Agents → Home → thread → back sequence, with screenshots showing the bar state at each step |
| 2.10–2.12 | Screenshots plus backend responses (status codes) |
| 2.13–2.20 | A Settings screenshot per section (light and dark). For 2.15/2.16, a host.log excerpt next to the Settings label for the same session. For 2.19, a CDP or host log |

**Profiling.** T-2 drawer drag: Animation Hitches during 5 drag/release
cycles. Hitch ratio ≤ 5 ms/s, and no hitch over 33 ms.

**Minimum full pass:**

- Drawer: Pro, mock, light and dark (2.1–2.6, 2.17, 2.20).
- Tabs: Pro and Pro Max, cmux15 (2.7–2.9, 2.13–2.19).
- Pairing: 2.10–2.12 against the real backend with a throwaway host.

---

## 3. Conversations and Chief (Messages parity)

References: `reference/imessage.md`, `validation/conversations.md`, and the
module `CNConversationsUI`.

### Behaviors

- **3.1 List geometry.** The large title, row height 86.7, avatar 45 at (26, row+20), title x 83, two-line preview width 303, date right edge 365.7 and chevron match within ±0.5 pt. The separator is a 1/3 pt hairline (a cmux style deviation; accepted).
- **3.2 Large-title collapse.** The title follows 1:1. The inline title fades in at offset 54 ± 2 pt. The cap top goes from 128 to about 74 pt.
- **3.3 Push and pop.**
  - Push uses spring 0.28 / 1.0 (in-app trace ± 0.01), and pop uses 0.27 / 1.0.
  - The list parallaxes at −0.30 W and dims to 0.10.
  - The header holds, then crossfades. It has no blur (a **known gap**).
- **3.4 Interactive edge back.** It tracks 1:1 and completes by release fraction and velocity. Cancelling springs back. This must be re-verified on video; it is open in `conversations.md`.
- **3.5 Swipe actions.**
  - Circles are 50 pt, with the open position at −130 (trailing) and +130 (leading, 2 actions).
  - The snap is critically damped (0.43 / 1.0).
  - Trailing has Delete (danger) and its siblings. Leading has Pin and Unread.
  - Each action performs its effect on the host. Verify with `conv.list` on reload.
- **3.6 Context menu.** It is the system preview and menu, with Pin/Unpin, Mark read/unread and Delete. The preview height is the system's (a **known gap**, about 395 pt versus 528).
- **3.7 Pin.** Pin and unpin fly the avatar between the row and the pinned grid (spring 0.45 / 0.85). The state persists across relaunch and over cmux15.
- **3.8 Send flight.**
  - The bubble fills over the field, squashes, lifts, and lands with its tail (spring 0.45 / 0.84, about 19 frames, overshoot ≤ 1%).
  - The landing slot is hidden until landing; this is a regression check for the slot-alpha bug.
  - The transcript shift uses 0.30 / 1.0.
  - The delivered receipt moves on 0.33 / 0.94 and stays on the previous message until delivery.
- **3.9 Typing indicator.** Three 9 pt dots with a 1.2 s period and a 0.3 s phase. It shows while Chief or an `agent:<sessionId>` conversation is running, and on cmux15 it shows for a Chief-started codex agent; this is a regression check for e2e bug 12.
- **3.10 Tab bar hiding (Tabs shell).** The bar is hidden only while a thread is on screen (§2.9).
- **3.11 Timestamp reveal.** A left drag in a thread reveals timestamps at 0.30× the finger, saturating at 50–55 pt. Release returns on 0.43 / 1.0.
- **3.12 Tapback.** Holding scales the bubble to 1.08 linearly. The menu appears at 1.0 ± 0.1 s. The panels spring 0.25 / 0.80. Choosing a reaction dismisses the menu; reactions are local only (a **known gap**). The menu has Copy and Share.
- **3.13 Composer.**
  - Bubble geometry is checked: one line is 40 tall, line pitch 20, max width 280, min 48, tail profile within 0.7 pt.
  - The field grows; the send capsule is 38 × 28 in ink.
  - The "+" button is 40 pt.
  - The composer stays above the tab bar and the accessory in both shells.
  - The keyboard rides smoothly (no jump, §0.3).
- **3.14 Markdown.** Bubbles render inline bold, italic, code (monospace, no backticks), strikethrough and underlined links. Previews and Copy use plain text. This is a regression check for e2e bug 11 in previews, the drawer and the Agents list.
- **3.15 Chief over cmux15.**
  - A message gets the typing indicator and then a real codex reply. Record the latency; the reference is about 10 s.
  - "Start a codex agent…" creates a session that appears in Home and Agents.
- **3.16 Header.** In a dark thread, the subtitle never overlaps the name pill (e2e bug 21).

### Edge cases

- Sending while offline: the bubble shows the failed state with a retry, and nothing is lost.
- Sending 5 messages in under 2 s: their order is preserved, and no slot is left hidden.
- A very long message (2000 characters) and an emoji-only message: the bubble geometry is right.
- Swiping one row open while another is open closes the first.
- Deleting the pinned Chief conversation (if allowed) or refusing to: the behavior matches the app's rule.
- A reconnect mid-thread reloads without duplicate messages.

### Evidence

| ID | Evidence |
|---|---|
| 3.1, 3.13, 3.16 | Ref/impl/blend/diff overlays for the list and thread, light and dark (as in `conversations/*-overlay.png`) |
| 3.2–3.12 | In-app trace logs (`CMUX_CONV_TRACE=1`) with `tracefit.py` fits. Ref-vs-impl animation strips per animation. Videos for edge back, swipe, send and tapback, re-recorded at host load below 20 where possible |
| 3.14 | Screenshots of a thread, the list preview and the drawer preview containing markdown |
| 3.15 | A cmux15 video, typing to reply, with timestamps |

**Profiling.** T-3 thread scroll and send: Animation Hitches plus Time
Profiler while scrolling a 500-message thread and sending 5 messages.

- Hitch ratio ≤ 5 ms/s.
- Main-thread time per frame p95 ≤ 8 ms.
- No layout pass over 16 ms on send.

**Minimum full pass:**

- Pro, Drawer, mock, light and dark (3.1–3.14).
- Tabs, cmux15, dark (3.9, 3.10, 3.15, 3.16).
- Pro Max smoke test of 3.1 and 3.8.

---

## 4. Agents

References: `validation/agents.md`, the module `CNAgentUI`, and
`host/BRIDGE-SECURITY.md` (approvals).

### Behaviors

- **4.1 Session list.** Each row shows the harness initial on its hue, a two-line preview in plain text (no raw markdown), `harness · cwd`, a relative time and its status (running spinner, "Approval" capsule, error, unread dot).
  - Relative times refresh at least once a minute without a reload (e2e bug 14).
  - Unread dots use the same color in the drawer and in Agents (e2e bug 15).
- **4.2 New session.** The sheet offers a harness, model and folder. Creating a session pushes the empty state ("What should <harness> work on?"). The session appears in the list and on the Mac (acpmux `_acpmux/sessions`).
- **4.3 Streaming.**
  - Text eases in at 90 characters per second or faster, and the backlog drains in about 0.25 s.
  - Unclosed markdown is hidden at the edge.
  - The transcript shows zero vertical jump during a stream (§0.3).
  - Growth past the reserve glides at 3–7 px per frame.
- **4.4 Tool rows.** Each row has a per-kind glyph and title, and "Ran `cmd`" in mono.
  - Expanding shows the **real output** (stdout), not `[terminal output]`; this is e2e bug 8. Check it on cmux15 with codex.
  - Shell output is at most 220 tall and scrolls both ways.
  - Failed output is marked.
- **4.5 Thoughts, plans, diffs.**
  - A thought disclosure shimmers while thinking and expands in about 22–24 frames.
  - The plan checklist shows the "N of M done" states.
  - Inline diffs show +/− lines on success and danger tints, with 3 lines of context. The add-line highlight spans the full row (e2e bug 16).
  - The "Edited N files" card totals match the diff on the Mac (`git diff --stat`).
- **4.6 Permission card.**
  - On the mock or a non-bridged harness, Allow once, Always and Reject each resolve the request, and the card leaves smoothly (no jump).
  - On a **bridged** cmux15 session (host advertises `agent.mirror.v1`), Allow is disabled up front, and the card reads "Approve this on your Mac". Reject still works from the phone.
  - Approving on the Mac resolves the card on the phone within 2 s.
  - Trigger a real request by running a session in Read-only mode, or by using a harness that asks.
- **4.7 Composer.**
  - The field grows from 1 to 5 lines with no jump.
  - Return sends; Shift-Return inserts a newline.
  - Sending during a turn queues the message, and it sends at turn end.
  - Stop cancels the turn (`agent.cancel`), and "Turn cancelled" appears.
  - The field keeps focus after sending.
  - The `+` button attaches a photo.
- **4.8 Slash commands.** Typing `/` opens the menu built from the harness's `commands`. Selecting one inserts it.
- **4.9 Model and mode.** The chip menu lists the models and modes the harness reports. A selection calls `agent.setModel` / `setMode` and survives a reload, confirmed by the host's state.
- **4.10 Real host.** On cmux15:
  - The bridged acpmux sessions list.
  - History opens at the bottom.
  - A codex turn ("create ~/v1-<run>.txt containing hi") streams, its tool row shows output, and the file exists on the Mac with that content.
- **4.11 Reconnect.** After Settings › Reconnect mid-stream, the transcript reloads on the new generation with no duplicate and no lost items.

### Edge cases

- A session that errors shows the error notice, and the list shows the error glyph.
- The harness is not installed (Claude on cmux15): new-session shows it unavailable, or shows an error. It must not hang.
- A transcript over 160 rows (LazyVStack path) still opens at the bottom and streams without jumps. Validate it; `agents.md` lists it as open.
- An approval card arrives while the keyboard is up.
- The session is closed on the Mac while it is open on the phone.

### Evidence

| ID | Evidence |
|---|---|
| 4.1–4.9 | Screens and item sheets (light and dark), like `agents/screens-*.png` and `items-*.png`. Continuity analysis (per-frame shift and changed fraction) for send, stream, tool insert, card appear and resolve, composer growth and keyboard |
| 4.4, 4.6, 4.10 | cmux15 screenshots of an expanded tool row with real stdout, the bridged approval card, and an `ls`/`cat` of the file on the Mac |
| 4.11 | A video plus a trace of the generation change |

**Profiling.** T-4 streaming: Time Profiler plus Animation Hitches during a 60 s
streamed reply with 10 tool rows.

- Hitch ratio ≤ 5 ms/s.
- Main-thread p95 ≤ 8 ms per frame.
- Memory growth ≤ 20 MB over the turn.

**Minimum full pass:**

- Pro, Drawer, mock, light and dark (4.1–4.9).
- Pro, Tabs, cmux15 (4.4, 4.6, 4.10, 4.11).
- Pro Max smoke test (4.3, 4.7).

---

## 5. Terminals

References: `validation/terminal.md`, `validation/browser.md` Round 12 (zoom
blink), the `CNTerminalUI` module, and `host/BRIDGE-SECURITY.md` §Sizing.

### Behaviors

- **5.1 Ghostty render.**
  - Text and ANSI colors draw (`ls --color`, `git status`, prompt colors).
  - The light theme uses "Apple System Colors Light" (bg #FEFFFF) and the dark theme "Apple System Colors" (bg #1E1E1E). Sampled bg colors must be within ΔE2000 ≤ 2.
  - The theme switches live with the appearance, and the font is kept.
- **5.2 Mac-mirrored terminals.** These are cmux15 bridged terminals and the mock 104×40.
  - The phone never resizes the Mac grid. `stty size` on the Mac is unchanged after the phone attaches, rotates, changes font size, or shows or hides the keyboard.
  - The phone renders at the Mac's grid, fitted to width. All 104 columns are visible.
  - A pan reaches every row and column.
- **5.3 Owned terminals.** These are created on the phone.
  - The grid fits the view.
  - A font change sends one `term.resize` debounced 150 ms (13 → 15 pt gives 50×42 → 43×36 on Pro).
  - There is no stray zsh `%` marker on the first prompt (e2e bug 17), checked on cmux15.
- **5.4 Key bar.**
  - The keys are Esc, Tab, sticky Ctrl and Alt (arm, then off after one key; a double tap within 0.4 s locks), arrows with repeat, `~ / | -`, Paste and Hide.
  - Ctrl+C prints `^C` on the host.
  - The bar is pinned to the keyboard layout guide, and no text shows through between the keys.
- **5.5 Keyboard row shrink (owned terminals).**
  - With the software keyboard up (`CMUX_NEXT_SOFTWARE_KEYBOARD=1`), the grid is the space between the nav bar and the key bar.
  - The content slides with the keyboard, then one `term.resize` follows after it settles.
  - `top`'s header is visible and its first row is not under the nav bar (e2e bug 13).
  - Hiding the keyboard grows the grid back.
  - Frame continuity holds in both directions (§0.3, residual ≤ 7/255).
  - Mirrored terminals never resize; they pan instead.
- **5.6 Composer and uploads.**
  - The composer toggles from the key bar. The field grows from 1 to 4 lines.
  - Send pastes (bracketed if enabled) and adds Return. A long press offers "Send Without Return". An empty Send sends a bare Return.
  - `+` → Photos uploads through `fs.upload.begin`, chunks and `end`. The quoted path is inserted, and the file exists on the Mac with mode 0600.
  - A file over 50 MB is refused with a message before reading.
- **5.7 Scrolling.**
  - A slow one-finger drag scrolls the scrollback row by row; this must work starting at zero velocity.
  - Momentum uses deceleration 0.998, and is off under Reduce Motion.
  - In an alt-screen app with SGR mouse, wheel reports (`ESC[<64;…M` / `65`) reach the host at the finger's cell.
  - In an alt-screen app without mouse reporting, arrows are sent instead.
  - Typing returns to the bottom.
- **5.8 Selection.** A long press selects a word, and dragging extends it. The menu has Copy, Paste and Select All. After Copy, `pbpaste` matches.
- **5.9 Reconnect.** After Settings › Reconnect or a link drop, the screen re-attaches on the new generation within 2 s on mock (≤ 1 s measured) and within 5 s on cmux15. The scrollback is identical, with no duplicated lines, and new input echoes.
- **5.10 Ended on the Mac.**
  - Closing the terminal on the Mac, or restarting the host, shows "This Terminal Ended on the Mac" with New Terminal and Back to Terminals.
  - No raw "terminal t_… not found" text appears, and the grid is not blank.
  - There is no hot attach loop: at most 1 attach per connection generation in the trace.
- **5.11 Zoom continuity (no blink).**
  - Opening a terminal from its card and returning to the grid shows no blank frame. Check every frame of the transition: terminal text pixels are present.
  - There is no layout swap: the prompt row stays within 2 pt of its card position, scaled.
  - One controller per handle, verified by a trace log count.
  - This is a regression check for Round 12.
- **5.12 Memory bounds.**
  - The terminal pool never releases a terminal that is on screen or being zoomed.
  - Off-screen controllers are released within the pool cap.
  - Opening and closing 10 terminals returns memory to within 10 MB of the baseline (§5 profiling).
- **5.13 Codex crash path.** Run codex in a terminal and kill it (`kill -9` on the Mac), or make it exit abnormally. The terminal shows the shell prompt again, or the ended state if the PTY died. The app does not crash, and the TUI's alt screen is left cleanly (no stuck mouse mode: a scroll afterwards scrolls the scrollback).
- **5.14 New terminal.** `+` (or New Terminal) creates a terminal, opens it, and draws the prompt at the final grid. It appears in the Mac's list (bridged `new-tab`).
- **5.15 Swipe to close in the list.** It closes the terminal on the host, and the list re-read confirms it.

### Edge cases

- 5000 lines of output in 1 s (`seq 1 5000`): no hang, the main thread is never blocked over 100 ms, and the final screen is correct.
- Pasting 100 KB: it is chunked under the 1 MiB `send` cap and arrives intact. Verify with a checksum on the Mac.
- Pinch font size: report that the handler is only reachable through the menu path; AXe has no pinch.
- Font size at the 9 and 24 limits.
- Switching appearance while the keyboard is up.
- The host restarts while the composer has a draft: the draft is kept.

### Evidence

| ID | Evidence |
|---|---|
| 5.1–5.3 | Screenshots in light and dark of `ls --color`, `top` and codex. `stty size` on the Mac before and after each phone action. The debug AX value `grid=… font=… theme=…` |
| 5.4–5.8 | Key bar sheets. Keyboard show/hide videos with consecutive-frame row-matching analysis. Scroll video. Host-side byte logs for the wheel and arrow reports. Upload file listing with mode |
| 5.9–5.11, 5.13 | Videos with frame splits. `CMUX_NEXT_TERMINAL_TRACE=1` logs (attach and generation lines, controller count). `blinkcheck.py` output over the zoom in and out |
| 5.12 | Profiling T-5b |

**Profiling.**

- **T-5a output flood.** Time Profiler plus Hitches during `yes | head -c 50M` and `top -d 0.1` for 20 s.
  - Main-thread p95 ≤ 8 ms per frame.
  - No hang over 250 ms.
  - Input echo latency on mock ≤ 50 ms (measured from the AXe key time to the screen change).
- **T-5b memory.** Allocations plus VM Tracker. Open 10 terminals one by one, go back to the list, and close all 10.
  - Peak and final memory are reported.
  - The final memory is within 10 MB of the baseline.
  - There are 0 leaked Ghostty surfaces or controllers.
- **T-5c zoom.** Hitches during 10 card ↔ terminal zooms. No hitch over 33 ms, and no blank frame.

**Minimum full pass:**

- Pro, Drawer, mock (5.1, 5.4–5.9, 5.11, 5.12).
- Pro and Pro Max, Tabs, cmux15 with mirrored terminals (5.2, 5.3, 5.10, 5.13, 5.14).
- Mock 104×40 (5.2).
- Light and dark for 5.1.

---

## 6. Tabs grid and browser (Safari UX)

References:

- `reference/safari.md`.
- `validation/browser.md`, Rounds 1–14.
- `validation/browser-springs-verify.md`, whose constants win where they disagree with older rounds.
- Device captures in `~/nxios-ref/safari/user/` and `safari/vid/`.

### Static geometry and chrome

- **6.1 Toolbar.**
  - The back circle is 34, 792, 48 × 48.
  - The address capsule is 90, 792, 222 × 48, with the URL center at (201, 816) and 17 pt medium text.
  - The tabs circle is 320, 792, 48 × 48.
  - The collapsed label is at center y 844 and scale 0.74.
  - The pill is the text width + 38 pt wide and 32 pt tall, with a 14 pt bottom inset.
  - These hold on Pro within ±0.5 pt; check the equivalent positions on Pro Max.
- **6.2 Grid cards.**
  - The cards are (W − 48)/2 wide with aspect 1.408, at x 16 / 209 on Pro (16 / 228 on Pro Max).
  - The corner is 15.2 pt at 196 wide, scaled with the card.
  - The close button is 22 pt at a 4 pt inset, with dark fill #3E3E3F and a #A7A7A9 semibold cross. Light mode is unchanged.
  - The active card has its close button.

### Motion

The spring constants come from `browser-springs-verify.md`. The tolerance is
R ± 0.04 and ζ ± 0.05, unless the row says otherwise.

| ID | Transition | Target |
|---|---|---|
| 6.3 | Toolbar collapse on scroll | 0.385 / 0.875 (shared toolbar spring). Side circles fade out linearly over 0.10 s |
| 6.4 | Expand by tapping the pill, and expand by scrolling up | 0.39 / 0.88. Side circles fade in as `easeOut(0.23).delay(0.09)`. A pill tap expands without navigating |
| 6.5 | Page → grid zoom (`toOverview`) | 0.37 / 0.875. Settles in 440–470 ms. Overshoot ≤ 0.5% |
| 6.6 | Grid → page (`toPage`) | 0.39 / 1.0 with a starting velocity of about 8.5 progress/s. The first 3 frames reach ≥ 1850 pt/s, so they are not too slow |
| 6.7 | Reversal mid-zoom | A jump toward the new target, then the destination's own spring from near rest. No 0.2-kept-velocity continuation (≤ 4 pt rms against the Safari reversals) |
| 6.8 | Pinch in on the page and pinch out on a card | The rect follows the centroid 1:1 with a rubber band. Release keeps the finger velocity (divided by 0.94 where needed). It completes past halfway or above 1.2 progress/s. Scripted pinch only |
| 6.9 | Close ✕ reflow | 0.43 / 0.89, x and y on one spring. The count updates at once. The card fades and scales to about 0.9 within about 100 ms |
| 6.10 | Close buttons and titles timing | The zooming card's ✕ follows progress 0.76 → 0.96. The other cards' ✕ wait for 0.96, then `1 − e^(−(t−16)/45 ms)`. Titles start at **0.90** (a deliberate deviation) with `1 − e^(−t/58 ms)`, rising 2 pt. Leaving the grid hides them within 2 frames |
| 6.11 | Scroll into view | Before zooming in, the grid scrolls so the card is fully visible. The zoom lands on the card's real frame (within 1 pt at the end), on Pro Max as well |
| 6.12 | New tab (+) | The page grows from the grid slot the new card takes (index = count). If that slot is off-screen, the grid scrolls first. On failure, a toast appears, and no other tab opens |
| 6.13 | Toolbar swipe between tabs | The page follows 1:1, and the neighbor sits at scale 0.93 and blurred. It snaps at about 0.4 / 0.9 (unverifiable against Safari; check by trace). Swiping past the last tab makes a new tab |
| 6.14 | Back/forward morph | The back circle widens into the back and forward capsule when forward history exists, with no jump |
| 6.15 | Address edit focus | The field rides the keyboard (`keyboard` 0.34 / 1.0) and rests at frames +13 to +16. The page crossfades to suggestions over 30–130 ms. The Go transition is 0.32 / 1.0 (low confidence) |
| 6.16 | Page menu | The droplet grows out of the menu glyph and rests at frames +14 to +16. It is inconclusive against Safari; check that it is continuous and that the right edge overshoots about 6 pt |

### Behaviors

- **6.17 Terminals in the grid.** Terminal cards sit in creation order with new tabs at the end. A terminal card opens into TerminalContent (§5.11). (+) is a menu with New Tab and New Terminal. The toolbar shows the terminal title in the capsule, with TerminalAccessory.
- **6.18 History menus.** A long press on back or forward opens the system menu. Each row shows the title and the address without scheme or "www.", with the most recent next to the button. Tapping a row calls `browser.goToHistory`, and the page matches on the Mac.
- **6.19 Page menu contents.** Reload, Show Keyboard, Share, Copy URL, Request Desktop Website, Open on Mac and Close Tab. There is **no Back/Forward in the menu**.
- **6.20 Address edit.** Focusing selects the full URL. Completions include open tabs ("Switch to Tab") and a Search row. Go navigates, and the label shows "🔍 query" for a search.
- **6.21 Mac browser access.** For a Mac browser tab with "Allow cmux on iPhone to view browser tabs" off, the banner explains access, and no frames stream. With it on, frames stream. "Show on Mac" brings the tab forward. Bring-forward follows §2.19. Pairing uses only the app's published mapping.
- **6.22 Streaming input.**
  - Typed characters arrive in the page in order, with no drops and no duplicates. Type `the quick brown fox 0123456789` into a page input and read it back through CDP.
  - Taps land on the tapped element after scroll and collapse (e2e bug 3): tap 5 links at known positions, and all 5 navigate correctly per CDP.
  - Attaching never reloads the page: the CDP `Page.frameNavigated` count stays at 0 on attach.
- **6.23 Close syncs to the Mac.** Closing a tab (✕ or swipe) removes the CDP target within 3 s. The tab does not come back after a reconnect (e2e bug 2). A refused close springs the tab back and shows a toast.
- **6.24 Displaced stream.** A second link attaching the same tab (`CMUX_NEXT_BROWSER_DISPLACE=1`) shows the dimmed last frame with "Viewing on another device" and "View here". "View here" re-attaches.
- **6.25 Grid freeze regression.** Run 20 cycles of (+) then the tabs button, some interrupted early, plus 30 rapid toggles. The grid stays responsive: a tap after the last cycle zooms within 1 frame of the tap.

### 6A. Swipe to close (in V1)

The A-criteria, edge cases and evidence below are the swipe-to-close part of
§6. Matrix, evidence and trace rules from §0 apply.

#### 6A.0 Safari reference numbers

The Round 14 numbers come from `validation/browser.md`. The reflow spring comes
from `browser-springs-verify.md`.

| Quantity | Safari | Tolerance for ours |
|---|---|---|
| Leftward tracking | 1:1 | card moves 1.00 ± 0.03 × the finger; lag ≤ 1 frame (16.7 ms) |
| Rightward | rubber band, ≈ 35 pt per 100 pt of finger, never closes | 30–40 pt at 100 pt; never closes |
| Slow-release threshold | offset ≈ 72% of the card width (fails at −123, closes at −132 on a 177 pt card) | 0.72 × width ± 3 pt; it must spring back at −123 and close at −132 |
| Fling threshold | a 60 pt flick closes at ≥ 250 pt/s and not at 200 pt/s | closes at ≥ 250 pt/s and not at ≤ 200 pt/s (code uses −225) |
| Spring back | response 0.56, damping 0.92; 32% / 59% back at 107 / 172 ms | within 1 frame of Safari at the 30/60/90% points; fitted R ± 0.04, ζ ± 0.05 |
| Fly-off | the card leaves left and fades in ≈ 2–3 frames | off screen and alpha 0 within 2–4 frames (33–67 ms) |
| Reflow | 0.43 / 0.89 (`tabclose1.mp4`; x and y share one spring) | fitted R ± 0.03, ζ ± 0.04; rms ≤ 1.5 pt against Safari's curve; settles within 1 frame of Safari |
| Fade / scale while dragging | none | none (alpha 1.0, scale 1.0 until release) |

#### 6A.1 Behaviors

- **A1. Direction lock.** A drag that is more horizontal than vertical (|dx| > |dy| at about 10 pt of travel) moves only the card. The grid's contentOffset.y changes by ≤ 1 pt over the whole gesture. A drag that is mostly vertical scrolls the grid exactly as before: the scroll distance is unchanged within ±2 pt of a baseline build, and no card moves horizontally by more than 0 pt.
- **A2. Tracking.** While the finger moves left, the card follows within the tracking tolerance above. Only the card moves: its neighbors, its title, and its ✕ move with it or stay in place, and no other card moves.
- **A3. Rightward rubber band.** A rightward drag gives the stated resistance. Any release springs back, and nothing closes.
- **A4. Commit by distance.** A slow release (< 100 pt/s) at an offset of at least 0.72 × the card width closes the tab. A slow release below that springs back. Check both columns, a 1-tab grid, and both device sizes; the threshold scales with the card width.
- **A5. Commit by velocity.** A short flick of 60 pt at ≥ 250 pt/s closes the tab. The same flick at ≤ 200 pt/s springs back.
- **A6. Spring back.** The card returns with the 0.56/0.92 spring, within the tolerance above. It rests at x = 0 ± 0.5 pt, with no residual offset or leftover layout.
- **A7. Close sequence.** The card flies off left and fades. Then the remaining cards reflow on the 0.43/0.89 spring. The tab count in the toolbar or title updates once, at the same moment as Safari's (within 1 frame of the reflow start). The model's tab list loses exactly that tab. A browser close calls the same path as the ✕ (`browser.close`). A terminal close calls `term.close`, the terminal ends on the Mac, and its thumbnail is forgotten (`forget(id)`).
- **A8. Refused close.** When a close fails (host error, or a mock that injects a failure), the card springs back to x = 0 with the spring-back curve. The same toast as the ✕ failure path appears within 1 s. The tab count does not change, and no reflow runs.
- **A9. Existing gestures.** A tap on a card still zooms it open. A tap on ✕ still closes it. Pinch and zoom still work. A long press keeps today's behavior: no new menu appears if Safari has none. A tap during a spring-back is accepted after the card settles; it is not swallowed.
- **A10. Reduce Motion.** With Reduce Motion on, the snap-back and the fly-off become 0.18 s crossfades. The reflow uses the Reduce Motion path. Tracking under the finger stays 1:1.
- **A11. Live terminal card.** The active terminal's live card, drawn by the terminal layer, moves with the same offset as its chrome. There is no 1-frame split between the image and the chrome, and no blink at commit.
- **A12. CmuxTabsKit parity.** The kit's `Logic/CardSwipe.swift` and `UI/CardSwipeGesture.swift` keep the same constants and commit rule as `CNBrowserUI`. Diff the two after normalizing names: the only differences allowed are the module boundary and the host callbacks. The kit demo shows A1–A8 and A10.
- **A13. Accessibility.** VoiceOver users can still close a tab, through the ✕ button or a "Close Tab" accessibility action on the card. The swipe adds no unlabeled elements.

#### 6A.2 Edge cases (any failure fails V1)

1. Swiping the card that is zooming, open or closed, does nothing. The zoom finishes normally, and the card does not end up offset after it.
2. Swiping during a reflow either does nothing or moves the card from its current animated position without a jump of more than 2 pt. No two closes collapse into a wrong count, and no layout is left overlapping.
3. Swiping the last remaining tab matches Safari's last-tab behavior; record Safari's behavior and match it. If the app forbids an empty grid, it springs back with no crash and no blank grid.
4. A swipe while a pinch is in progress is ignored. The pinch wins, and no card is left offset.
5. A swipe to the right never closes, at any distance or velocity (A3).
6. Closing the active tab by swipe moves the active selection to the same neighbor the ✕ path picks. The live terminal card does not leave a ghost image behind.
7. A very fast fling (≥ 3000 pt/s over ≤ 30 pt) closes cleanly, with no overshoot back on screen and no double close.
8. Reversing direction mid-drag, left past the threshold then back right under it, springs back when released slowly. Velocity at release decides: a rightward fling springs back.
9. A terminal that ends on the Mac while its card is being swiped finishes the close without an error toast, or springs back with the ended image. It does not crash and does not leave a card with no tab.
10. Switching light or dark mid-grid, or mid-swipe, does not reset the drag offset. Redrawing the cards in the new scheme is §9 B4 (post-V1).
11. Two fingers each swiping a different card: at most one swipe at a time, or both correct. Nothing is corrupted.
12. A swipe that starts on the ✕ button behaves as a swipe, not a ✕ tap, after 10 pt of movement.
13. Rotation is not applicable: the app is portrait only. Note it in the evidence.

#### 6A.3 Evidence

| Behavior | Evidence |
|---|---|
| A1 | Video of a horizontal and a vertical drag. A contact sheet with contentOffset or the first card's y per frame (≤ 1 pt drift on horizontal drags). |
| A2–A3 | `cardtrack.py` / `rightedge.py` traces: finger x versus card edge per frame for drags of 60, 100, and 135 pt left and 100 pt right. Ratio and lag in a table. |
| A4–A5 | A trial table matching Safari's: releases at −84, −105, −123, −132, and −140 pt (slow), and 60 pt flicks at 200 and 250 pt/s. Outcome per trial for ours versus Safari, on both device sizes. Unit output from `CardSwipeTests` with these trials. |
| A6 | `springfit.py` fit of the spring-back with R, ζ, rms. An overlay plot or table against Safari's 107/172 ms points. |
| A7 | Video and frame split of the close. Fly-off frame count, reflow spring fit (R, ζ, rms against 0.43/0.89), and tab count before and after. Side-by-side contact sheet with `safari/vid/tabclose1.mp4` (or a new Safari swipe-close capture) aligned at release. Screenshots of the grid before and after. |
| A8 | Video of a refused close: spring back plus the toast screenshot. Mock or log line showing the injected failure. |
| A9 | Screenshots after tap→zoom, ✕ close, and pinch on a grid that was just swiped. |
| A10 | Video with Reduce Motion on, frame split showing the crossfade (about 0.18 s, no translation after release). |
| A11 | Frame split of a swipe on the active terminal card, zoomed crop. No frame where the image and chrome differ by more than 1 pt. |
| A12 | Normalized `diff` of CardSwipe/CardSwipeGesture between the app and the kit. Kit `swift test` output. Kit demo video of a slow close, a spring back, and a fling. |
| A13 | AX tree dump (`axe describe-ui`) of a card showing the close action or the ✕. |
| Edge cases 1–12 | One short video each, or a frame split for the timing-sensitive ones (2, 7, 8), with a one-line verdict. |

#### 6A.4 Profiling

Risk: the whole grid is invalidated per frame during the drag, every card is re-laid out on each offset change, and the live Metal terminal card is re-snapshotted during the fly-off.

| Trace | Scenario | Template | Metrics and pass bound |
|---|---|---|---|
| T1 swipe | 8 browser and 4 terminal tabs. Five slow closes, five flings, and five spring-backs, 2 s apart, scripted by AXe | Animation Hitches + Time Profiler (+ SwiftUI if available) | Hitch time ratio ≤ 5 ms/s; no single hitch > 33 ms during drag, fly-off, or reflow. Main-thread time per frame p95 ≤ 8 ms. No re-render of cards other than the swiped one during the drag (SwiftUI body counts). |
| T3 leak | Open and close the grid 10 times with 10 terminals; swipe-close 5 terminal cards | Leaks + Allocations generations | 0 leaked `HeadlessTerminal` or Ghostty surfaces. Generation growth per open/close cycle ≤ 1 MB. |


**6A minimum full pass:**

- All of 6A on Pro × Tabs × mock.
- A4, A5 and A7 on Pro Max.
- A7 (a terminal close) and A8 on cmux15.
- A Drawer smoke test of A1 and A7.
- A12 in the kit demo (§8).

### 6 edge cases (beyond 6A)

- Tapping the tabs button 5 times in 1 s ends settled on one side, with no stuck overlay and an interactive grid.
- A new tab while `browser.create` is slow (≥ 3 s on cmux15) keeps the grid responsive. A refused create shows a toast and opens no other tab.
- Closing the last tab matches Safari: record the reference and match it.
- A page whose title changes during the zoom does not shift the title row.
- Twelve tabs or more, so the grid scrolls: the zoom from an off-screen card scrolls first (6.11) on both device sizes.
- With dark mode over a white page, the clock is black (§2.20).
- Mac browser access is turned off on the Mac while a tab is open: the tabs drop and the banner shows, with no crash.

### 6 evidence

| ID | Evidence |
|---|---|
| 6.1–6.2 | AX-tree geometry tables and glyph-ink boxes, ref vs impl, on Pro and Pro Max, light and dark. A close-button crop compared with `close-x-safari.png` at 8 px/pt |
| 6.3–6.16 | For each transition: one video, a per-frame track (label y, card rect via `chromefit*.py`, `zoomfit.py`, `cardtrack.py`), a spring fit table, and a side-by-side contact sheet against the Safari capture aligned at onset (`tab-zoom-device.mp4`, `tab-reverse-device.mp4`, `safari-scroll-into-view-device.mp4`, `tabclose1.mp4`, `tabswipe.mp4`). Pro Max for the device comparisons |
| 6.17–6.25 | Screenshots of the grid with terminals, the history menus, the page menu, address completions, and the access banner on and off. A CDP log (`curl …/json`, `Page.frameNavigated` count, input readback) for 6.22 and 6.23. A video of the displaced banner. Unit output from `TabZoomStateTests`, `CardChromeTests`, `CardSwipeTests` and `PaneCanvasLayoutTests` (if still present) |

### 6 profiling

| Trace | Scenario | Bound |
|---|---|---|
| T-6a zoom | 10 page↔grid zooms, 3 reversals and 2 scripted pinches with 8 browser and 4 terminal tabs | Hitch ratio ≤ 5 ms/s. No hitch over 33 ms. Main-thread p95 ≤ 8 ms |
| T-6b toolbar | Scroll a long page for 20 s, collapsing and expanding 10 times | Hitch ratio ≤ 5 ms/s |
| T-6c stream | 60 s streaming a Mac browser tab over cmux15, direct and Force relay | Frame-ack loop CPU ≤ 20% of one core. Memory flat within 10 MB. Updates/s reported (≥ 5 direct, ≥ 3 relay are the observed floors) |

**§6 minimum full pass:**

- Pro and Pro Max × Tabs × mock, light and dark: 6.1–6.20, 6.24 and 6.25.
- Pro × Tabs × cmux15: 6.17, 6.18, 6.21–6.23.
- Drawer × mock smoke test: 6.5, 6.9 and 6.13.
- Reduce Motion: 6.5 and 6.9.

---

## 7. Connectivity, backend, host, bridge, security

References: `ios-next/PROTOCOL.md`, `ios-next/backend/README.md`,
`ios-next/host/BRIDGE-SECURITY.md`, `validation/e2e.md` and
`validation/shell.md` (relay).

### Behaviors

- **7.1 Direct path.** With Force relay off, a simulator on cmux15's LAN selects a host or srflx pair. The app and host.log agree on the selected pair (§2.15).
  - ICE connecting → connected takes ≤ 3 s, with a median ≤ 1.5 s over 10 links.
  - Measure on the build Mac at a recorded load. If the build Mac cannot reach cmux15 directly, say so and test direct only where possible.
- **7.2 Relay path.** When there is no direct path, it falls back to TURN automatically. The label reads "Relayed via TURN".
- **7.3 Force relay stability.**
  - With Force relay on, relay/relay pairs are selected on both ends, and the offer carries `policy:"relay"`.
  - The link stays up for **at least 5 minutes** with no `disconnected` state and no reconnect, while a terminal echoes a heartbeat (`while true; do date; sleep 5; done`). Every heartbeat line must arrive, with no gaps over 10 s.
  - `shell.md` recorded a failure after 18–50 s. That is a V1 blocker if it reproduces.
- **7.4 Signaling and reconnect.**
  - Settings › Reconnect gets a new `hello` in ≤ 2 s.
  - A host restart gets a re-`hello` within 10 s of the host starting.
  - A signaling socket drop (kill the WebSocket from the backend or a proxy) reconnects with backoff, and there is no reconnect storm: at most 1 attempt per backoff step in the log.
  - The access token expiring (4002) triggers a refresh and a reconnect with no user-visible error.
  - Over 30 minutes idle on cmux15, the link stays up, or recovers within 10 s after any drop, with every drop logged.
- **7.5 Pairing consent.**
  - `pair/poll` returns `approverEmail` exactly once, and a reused device code gets 410.
  - The host refuses to use the token until its user confirms the approver email. Show the host prompt or log and the refusal path.
  - A device code expires after 10 minutes (410).
- **7.6 Revocation (family).**
  - Refresh-token reuse outside the 30 s grace revokes the family.
  - Every host socket gets `{"type":"revoked","family"}`, and the host drops the links of that family within 5 s.
  - The phone's socket closes with 4005, and the app shows §1.10.
  - A host that reconnects within 30 minutes gets `revokedFamilies` in `welcome` and drops the matching links.
  - A host refuses a `peerId` change when the frame's family does not match.
  - Frames a phone sends with a forged `family` are overwritten by the server.
- **7.7 ICE cache and limits.**
  - `/ice` is fetched at most once per `iceRefreshFraction` × ttl (3600 s), shared across connects. Count the requests in the backend log across 10 reconnects; expect 1.
  - When the fetch fails, a still-valid cached config is used.
  - Rate limits: the 301st request in an hour per family gets 429. A user with no paired host gets 403. Verify both with the backend tests.
- **7.8 Bridge to the official cmux-next (cmux15).** Each item is checked on the phone and on the Mac.
  - Terminals list, mirror, type and close. `new-tab` opens the default shell. The phone never resizes (§5.2).
  - Agents list, attach, prompt, cancel, set model and mode, and rename (§4.10).
  - The layout (`layout.v1`) reflects the Mac's workspaces and panes.
  - `layout.focusTab` brings the tab forward on the Mac (the Mac screen, via a screenshot on cmux15 or the host's `list-workspaces` selection).
  - Mac browser tabs follow §6.21.
- **7.9 Security allowlist (BRIDGE-SECURITY.md).**
  - Everything not on `DAEMON_ALLOW` / `ACPMUX_ALLOW` is denied, including the listed denials: `run`, `create-terminal`, `apply-layout`, `split`, `shutdown-daemon`, `pairing-response`, `new-tab` with `cwd`/`shell_args`/`env`, sized attaches, `counts:true`, extra fields, prototype keys, `session/new` with MCP servers, `resource` blocks, and non-empty client capabilities.
  - Verify with `host/test/bridge.test.ts`, `macBrowser.test.ts` and `layout.test.ts`.
  - **Live probe:** from a scripted phone client (`laneCodec`-based probe or `rpc.test` helper) against cmux15, send 3 denied requests: `new-tab` with `cwd`, `term.resize` to a different grid, and `browser.create` while Mac browser access is off. Each is refused with the documented error, and the Mac is unchanged.
  - An approval Allow from the phone on a bridged session is refused (§4.6).
- **7.10 Backend tests.** In `ios-next/backend`, `npm test` and `npm run typecheck` pass at the tag. The tests cover Stack, email, test, Apple and OAuth sign-in, refresh rotation and reuse, pairing, `/ice` with and without TURN, signaling through the Durable Object, and presence. `GET /v1/health` reports `db`, `turn` and `auth` OK.
- **7.11 Host tests.** In `ios-next/host`, the full vitest suite (bridge, agents, browser, chief, files, laneCodec, layout, macBrowser, rpc, signaling, terminal, webrtc) and `tsc` pass at the tag.
- **7.12 App unit tests.** `remote-ios.sh test` (CmuxNextMobile on macOS) passes at the tag. List the suites and counts.
- **7.13 Copy hygiene.** No user-facing string in the app names an internal vendor (TURN is acceptable as a protocol term; "Cloudflare", "Stack", "PlanetScale" and "Freestyle" are not). Grep the strings catalog and do an OCR pass over every screenshot taken in this run.

### Edge cases

- Two phones on one account attach the same terminal: both mirror, input from both arrives in order, and neither resizes.
- The host is deleted (`DELETE /hosts/:id`) while connected: the host gets 4003 and drops its peers, and the phone shows the host removed.
- The account is deleted (test account only, if a disposable one exists): every socket gets 4004. Otherwise mark it "not run".
- The clock is skewed 10 minutes on the simulator: token refresh still works.
- The network flaps (link conditioner at 100% loss for 10 s, then restored): it recovers within 15 s with no duplicate streams.

### Evidence

| ID | Evidence |
|---|---|
| 7.1–7.4 | host.log and app trace excerpts with timestamps (`peer state`, `link open`, selected pair). A 5-minute heartbeat log with gap analysis. Settings screenshots. A table of the latency numbers in `e2e.md` form |
| 7.5–7.7 | Backend vitest names and results for each item. curl transcripts with status codes (secrets redacted). A backend log count of `/ice` |
| 7.8 | Paired phone/Mac screenshots for each bridged capability |
| 7.9 | Test output plus the live probe transcript and the Mac state before and after |
| 7.10–7.13 | Command output (counts, durations) and the grep or OCR result |

### Profiling

**T-7 relay soak.** Over 5 minutes with Force relay and a terminal heartbeat,
plus 1 minute of browser streaming:

- App CPU and memory are sampled every 10 s.
- Memory growth ≤ 10 MB.
- No main-thread hang over 250 ms.
- The 5-minute direct-path soak is reported too.

**§7 minimum full pass:**

- 7.1–7.4 and 7.6–7.8 on Pro × Tabs × cmux15 (Drawer for 7.4).
- 7.9–7.13 as test and command runs.
- 7.5 against the live backend with a throwaway host.

---

## 8. CmuxTabsKit (`cmux-tabs-kit-v1`)

References: `Packages/iOS/CmuxTabsKit/README.md` and its demo, in worktree
`worktrees/nx-tabs-kit`.

### Behaviors

- **8.1 Builds.**
  - `swift build` of the package for iOS Simulator succeeds with Swift 6.2 tools.
  - The demo (`Demo/project.yml`, generated with XcodeGen) builds and launches on iPhone 17 Pro and Pro Max.
  - The kit imports no cmux transport or model module. Check the `Package.swift` dependencies and grep the imports.
- **8.2 API per README.**
  - The README's minimal example compiles as written in a scratch target: `TabsDataSource`, `TabsKitTab`, `features`, `close(_:)`, `createTab`, `notice`, `isContentReady`, `providesHistoryMenus` and `statusBarStyle`.
  - Every public symbol the README mentions exists, with the stated behavior.
- **8.3 Mirrors §6.** In the demo, these behave as in the app, within the same tolerances:
  - the toolbar (6.1, 6.3, 6.4) and address editing (6.15, 6.20);
  - the page menu (6.16) and the back/forward morph and history menus (6.14, 6.18);
  - the grid and reflow (6.2, 6.9) and close buttons and titles (6.10);
  - zoom, reversal and pinch (6.5–6.8), with `isContentReady` covering blank content;
  - scroll into view (6.11), and New Tab with the notice toast (6.12);
  - toolbar swipe (6.13), swipe-to-close (6A, A12), status bar and Reduce Motion.
- **8.4 Constants parity.** The springs, triggers (`titleTrigger` 0.90, close trigger 0.96) and swipe thresholds (0.72 × width, 225 pt/s) are identical in the kit and in `CNBrowserUI`. Run a normalized diff of `Logic/` against the app sources. Any difference must be explained by the module boundary.
- **8.5 Tests.** `swift test` (`CmuxTabsKitTests`) passes. List the counts.
- **8.6 Demo screenshots.** The README's `Demo/Screenshots/page.png` and `grid.png` match a fresh capture of the tagged demo: the layout matches, and the pixel diff in the chrome regions is ≤ 2%.

### Edge cases

- A data source with 0 tabs.
- A data source that returns nil from `createTab`: the notice shows, and no tab opens.
- `close(_:)` throws or refuses: the card springs back and a toast appears.
- 50 tabs: the grid stays smooth (T-8).

### Evidence

- Build and test logs.
- A demo video per §6 transition group, with frame splits and spring fits against the app's values.
- The parity diff output.
- The README example compile log.
- A screenshot comparison.

### Profiling

**T-8.** Animation Hitches in the demo with 50 tabs: scroll the grid, zoom 5
times, swipe-close 5 tabs.

- Hitch ratio ≤ 5 ms/s.
- No hitch over 33 ms.

**§8 minimum full pass:**

- Pro: all items, light and dark.
- Pro Max: 8.3 smoke test (zoom, swipe-close, reflow).

---

## 9. Full-color terminal cards — post-V1, expected to fail on V1

The work for this section is uncommitted and in progress, so it is **not** in
`cmux-next-ios-v1`. Run B1–B9 against the V1 build anyway and record each
result as an honest FAIL or PASS with evidence. That records the gap; it does
not block V1.

Expected on V1, from source at `719832dad64d`:

- When Ghostty yields no frame in time, the text fallback (`TerminalCardRenderer.image`) draws a fixed white or black foreground, so cards come out monochrome.
- With `maxLive = 6`, cards beyond the cap can stay on the theme background until rotated, so they appear blank.

Aziz's device recording `~/nxios-ref/dogfood/terminal-card-no-color.mp4` and
`close-x-ours.png` show both. Re-run §9 in full when the color work lands.

### 9.1 Behaviors

- **B1. Color fidelity, per cell.** For each test screen, open the terminal, wait for idle, and take a screenshot. Return to the grid, wait for the next card refresh (≤ 0.5 s plus one frame), and take another. In each, sample at least 40 matched cells: their background center and a glyph-stroke pixel of their foreground. Map card cells to terminal cells through the grid geometry. The card's colors must match the live terminal's within **ΔE2000 ≤ 3** for backgrounds, and within ΔE2000 ≤ 6 for foreground glyph pixels (downscaling blurs them). Measure the foreground by the dominant non-background color in the cell. Test screens:
  - `ls --color=always` in a directory with dirs, executables, and symlinks;
  - a 16-color, 256-color, and 24-bit truecolor test pattern (for example `msgcat --color=test` or a truecolor gradient script), in fg and bg;
  - SGR bold, dim, italic, underline, and inverse (7) cells, and a bright-on-bold cell;
  - `top` (or `htop`) running;
  - the codex TUI (`codex` interactive) idle at its prompt with a colored diff or status bar.
- **B2. Cursor.** The cursor's cell, shape (block/bar/underline), and color match the live terminal. ΔE2000 ≤ 6 for the cursor color. If the live terminal blinks, the card shows either phase, never a missing cursor for 3 or more refreshes in a row.
- **B3. Theme.** The card uses the active Ghostty theme's palette, background, and foreground, not a fixed white or black. Switching the theme (or using a non-default theme on the host) changes both the card and the terminal identically. B1's ΔE limits apply.
- **B4. Light and dark.** B1–B3 pass in both light and dark. When the appearance changes while the grid is open, every visible card redraws in the new scheme within 1 s. No card stays in the old scheme for more than 1 s.
- **B5. Mirrored 104×40.** On mirrored Mac terminals (`CMUX_NEXT_MOCK_TERMINAL_MIRROR=104x40` and real cmux15 mirrors), the card shows all 104 columns and the top rows in the same layout as the opened mirror, with the same colors per B1. No column is cropped and the text is not wrapped differently.
- **B6. No blank cards.** With **≥ 10 terminals**, and also 16, every card that is on screen shows content in color within 1.0 s of first being visible. Content means at least 2% of its pixels differ from the theme background by ΔE > 10, unless the terminal really is empty. This holds after scrolling the grid top → bottom → top twice, and after returning from a zoomed terminal. A card whose renderer was evicted keeps its last colored image. It is never replaced by the background, and never by the monochrome text fallback (`TerminalCardRenderer.image`, fixed `UIColor.white/black` foreground). If the text fallback is still reachable, it must draw the cells' real colors.
- **B7. Ended terminal.** When a terminal ends on the Mac, its card shows the ended image with the theme's colors within 2 s. Its renderer is released.
- **B8. Refresh bound.** Each card is re-rendered at most 2 Hz: across 10 s of continuous output (`top -d 0.1` or `yes | lolcat`), consecutive frames delivered per terminal are ≥ 480 ms apart. While the output keeps running, the card still updates at least once every 1.5 s, so it does not freeze.
- **B9. Renderer cap.** No more than `maxLive` (default 6) headless renderers exist at once, counted by `TerminalMemory.trace` or a debug counter. Renderers for off-screen cards are stopped. Leaving the grid stops all of them within 1 s.

### 9.2 Edge cases

- A light/dark switch mid-grid redraws every visible card within 1 s (B4).
- A terminal ended on the Mac shows the ended card (B7).
- Scrolling with 16 terminals leaves no blank card (B6).
- The color work does not raise memory past T2 and does not change the 2 Hz bound.

### 9.3 Evidence

| Behavior | Evidence |
|---|---|
| B1–B3 | Paired PNGs, live terminal and card, for each test screen in light and dark. A sampling script output (CSV: cell, terminal RGB, card RGB, ΔE2000), with max and p95 ΔE per screen. A side-by-side sheet with the card upscaled to the terminal's size. Aziz's `dogfood/terminal-card-no-color.mp4` and `close-x-ours.png` as the "before". |
| B4 | Video of a light↔dark toggle with the grid open; timestamps until every card has redrawn. |
| B5 | Mock 104×40 and cmux15 mirror pairs with a column count check (last column visible). |
| B6 | Grid screenshots at the top, middle, and bottom with ≥ 10 and with 16 terminals, after two full scroll passes and after returning from a zoom. Automated blank check per card (pixel-difference fraction), and a log of first-image latency per card. |
| B7 | Screenshot of the ended card plus the trace showing its renderer stopped. |
| B8–B9 | `TerminalMemory.trace` log over 10 s of heavy output: per-terminal frame timestamps (min interval ≥ 480 ms, max gap ≤ 1.5 s) and the live renderer count over time (≤ maxLive). |

### 9.4 Performance risks

- **Thumbnail churn with ≥ 10 terminals.** `maxLive = 6` means renderers rotate on scroll. Every rotation creates a Ghostty surface and a Metal drawable, and attaches a stream, which costs main-thread time and memory. A rotation loop could also fall into thrashing.
- **Image memory.** Full-page-size `CGImage`s per card at screen scale: about 402×566 pt @3x ≈ 8 MB each uncompressed. Keeping a colored image for every card can grow without bound if images are not downscaled to the card size (177×249 @3x ≈ 1.6 MB).
- **Main-thread snapshotting.** `GhosttySnapshot.image` and `UIImage` creation on the main actor, at 2 Hz × 6 renderers.
- **Appearance switch.** All renderers restyle at once, which can spike CPU and memory.

### 9.5 Trace

| Trace | Scenario | Template | Metrics and pass bound |
|---|---|---|---|
| T2 colored grid | 10 cmux15 (or mock) terminals, all running colored output (`top -d 0.2`, a `lolcat` loop, codex). Open the grid, scroll top↔bottom 3 times, idle 30 s, toggle dark/light once | Allocations + VM Tracker + Time Profiler | Persistent memory growth over the 30 s idle ≤ 5 MB. Peak memory delta versus the grid with 0 terminals ≤ 150 MB; report the absolute value too. Image bytes per card ≤ 2× the card-sized bitmap. Main-thread CPU at idle (cards refreshing) ≤ 15% of one core. Live headless renderers ≤ maxLive at every sample. Appearance switch hitch ≤ 100 ms total. |

**§9 minimum full pass (when the work lands):**

- Pro × Tabs, on mock 104×40 and on cmux15, light and dark.
- B6 with at least 10 and with 16 cmux15 terminals.
- A Drawer smoke test of B1 and B6.
- On V1: one run on Pro × Tabs × cmux15, dark, recording the expected failures.

---

## Summary of traces

| Trace | Area | Gate |
|---|---|---|
| T-2 drawer | §2 | Hitch ratio ≤ 5 ms/s, no hitch over 33 ms |
| T-3 conversations | §3 | Hitch ratio ≤ 5 ms/s, main-thread p95 ≤ 8 ms |
| T-4 agent stream | §4 | Hitch ratio ≤ 5 ms/s, memory growth ≤ 20 MB per turn |
| T-5a/b/c terminals | §5 | Flood p95 ≤ 8 ms; memory back within 10 MB; zoom has no blank frame |
| T-6a/b/c browser, T1 and T3 swipe | §6 | Hitch ratio ≤ 5 ms/s; stream memory flat; 0 leaks |
| T-7 relay soak | §7 | 5 min with no drop; memory growth ≤ 10 MB |
| T-8 kit | §8 | Hitch ratio ≤ 5 ms/s with 50 tabs |
| T2 colored grid | §9 (post-V1) | Memory and renderer bounds |

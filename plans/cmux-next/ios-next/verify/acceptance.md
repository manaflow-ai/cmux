# cmux-next iOS: acceptance criteria (simulator now, device later)

Status: draft for the verify-implementation pipeline, 2026-10-07. Branch `feat-cmux-next-ios`
(PR manaflow-ai/cmux#18426, head `6654054d76e8`). Sources: [PLAN.md](../PLAN.md),
[d3-dogfood.md](../d3-dogfood.md) (parity matrix, device checklist, runbook), the lane notes in
`plans/cmux-next/ios-next/`, `ios/CmuxiOS/Sources` (DEBUG launch switches) and
`ios/cmuxUITests/Next*UITests.swift`. Budgets: `plans/cmux-next/ios-rewrite.md` section 9.

The author of these criteria does not implement, drive or verify. The verifier records every
artifact under `artifacts/ios-next-verify/<criterion-id>/` and judges each criterion PASS, FAIL or
BLOCKED (with the reason). A criterion with any fail condition hit is FAIL; a criterion whose
required evidence is missing is not PASS.

## 0. Common setup

### 0.1 Build and devices

- One DEBUG simulator build of the exact head SHA (the `Debug` configuration of scheme `cmux-ios`, or
  the fleet/CI artifact for that SHA; see `skills/infra/build-fleet` and the `ios-dogfood` skill).
  Record the SHA, the bundle id (`$BUNDLE`, e.g. `dev.cmux.ios.<tag>`) and the Xcode/runtime versions
  in `artifacts/ios-next-verify/env.txt`. Never `xcodebuild test` on the local Mac (HQ rule); the
  `Next*UITests` run on CI (`test-ios.yml -f ui_tests=true`) or a leased Mac (d3-dogfood.md 6.4).
- Simulators, each created fresh for this run (`xcrun simctl create`), erased before the first
  launch, deleted at teardown:
  - `PRIMARY`: iPhone 17 (or 17 Pro), iOS 26.x or 27.x runtime.
  - `SMALL`: the smallest iPhone the installed runtimes offer (iPhone SE 3rd generation if a runtime
    has it, else iPhone 16e / the smallest 6.1" class). Record which.
  - `LARGE`: iPhone 17 Pro Max (or the largest available).
- Placement: the Simulator window(s) go on the **LG HDR 4K** display (identify it by name and bounds,
  not index). Never on the LG UltraFine. If the LG HDR 4K is unavailable, stop and ask.
- No paired Mac, no account, no network dependence: every criterion below runs on mock or demo
  sources. A criterion that needs a real owner is in section 3 (device).

### 0.2 Launch recipes

Launch through simctl with the environment prefixed `SIMCTL_CHILD_` and a forced relaunch, English
unless stated:

```bash
SIMCTL_CHILD_CMUX_IOS_HOME_PREVIEW=1 SIMCTL_CHILD_CMUX_IOS_SOURCES=mock \
SIMCTL_CHILD_CMUX_IOS_ONBOARDING=0 SIMCTL_CHILD_CMUX_IOS_SHELL_TAB=<tab> \
SIMCTL_CHILD_CMUX_IOS_FLAG_FEED_TAB=1 SIMCTL_CHILD_CMUX_IOS_FLAG_WORKSPACES_TAB=1 \
SIMCTL_CHILD_CMUX_IOS_FLAG_COMPOSE_TAB=1 SIMCTL_CHILD_CMUX_IOS_FLAG_HOSTS_TAB=1 \
SIMCTL_CHILD_CMUX_IOS_FLAG_SEARCH_TAB=1 SIMCTL_CHILD_CMUX_IOS_FLAG_CLOUD_TAB=1 \
xcrun simctl launch --terminate-running-process $UDID $BUNDLE -AppleLanguages '(en)' -AppleLocale en_US
```

Named recipes used below:

| Recipe | Environment (all `SIMCTL_CHILD_`-prefixed) |
| --- | --- |
| `SHELL(tab)` | the block above; `tab` in `home feed workspaces compose hosts search cloud settings` (the `NextUITest.launchShell` set) |
| `ONBOARD(step?)` | `CMUX_IOS_ONBOARDING=1`, `CMUX_IOS_SOURCES=mock`, optional `CMUX_IOS_ONBOARDING_STEP=<step>`; signed out (fresh keychain) |
| `STORED` | no `CMUX_IOS_*` keys at all except `CMUX_IOS_SOURCES=mock` (stored onboarding progress and auth decide) |
| `GUEST` | `CMUX_IOS_GUEST=1`, `CMUX_IOS_SOURCES=mock`, `CMUX_IOS_ONBOARDING=0` |
| `DEMO(tab)` | `SHELL(tab)` plus `CMUX_IOS_DEMO=1` |
| `BENCH(w)` | `CMUX_IOS_HOME_PREVIEW=1`, `CMUX_IOS_TERMINAL_BENCH=<w>`, `w` in `flood htop vim` |
| `TERMPREVIEW` | `CMUX_IOS_HOME_PREVIEW=1`, `CMUX_IOS_TERMINAL_PREVIEW=1` (DevTerminal on `MockTerminalSessionSource`) |

Notes from the sources: `CMUX_IOS_HOME_PREVIEW=1` shows the shell signed in as a "Preview" account
without auth; a forced shell tab or Home preview implies onboarding skip unless
`CMUX_IOS_ONBOARDING=1`; setup onboarding steps need sign-in, so a signed-out
`CMUX_IOS_ONBOARDING_STEP=<setup step>` lands on sign-in (by design). Flags default on in DEBUG for
the feature tabs; `keepAwake`, `cloudOnboarding`, `cloudWorkspaces`, `billing` default off
(`CMUX_IOS_FLAG_KEEP_AWAKE`, `_CLOUD_ONBOARDING`, `_CLOUD_WORKSPACES`, `_BILLING`).

### 0.3 Evidence rules

- Screenshot: `xcrun simctl io $UDID screenshot <file>.png` of the steady state (after the
  transition settles), plus the accessibility element (identifier/label) that proves the state when
  the criterion names one. Screenshots must be real captures of the simulator; never synthetic.
- Video: `xcrun simctl io $UDID recordVideo --codec h264 <file>.mp4` started before the action and
  stopped after it settles, for anything that moves (transitions, animations, keyboard, scroll,
  rotation, pinch, optimistic updates). The verifier frame-splits videos (`verify-ui-video` skill)
  and cites frame timestamps for each claim.
- Accessibility tree: an XCUITest `app.debugDescription` dump, or a cmux-cua `get_window_state` of
  the Simulator window, saved as text.
- Logs: `xcrun simctl spawn $UDID log stream --level debug --predicate 'subsystem BEGINSWITH "dev.cmux"'`
  captured for the whole run to `log.txt`; crash logs from
  `~/Library/Logs/DiagnosticReports/` matching the app name are attached when present.
- Global fail conditions (apply to every criterion): the app crashes, hangs (a main-thread hang
  over 1 s visible as a frozen UI or a Hangs event), shows a raw localization key
  (`feed.action.allow`-style text) or an empty placeholder screen where content is expected, shows a
  debug "TODO"/"Not implemented" string on a shipped surface, or leaves the Simulator on the wrong
  display.

## 1. Simulator criteria (run now)

### SIM-01 Cold launch, no crash

- Behavior: the app installs and cold-launches to a usable first screen in each main mode.
- Steps (PRIMARY, freshly erased): install; launch `STORED` (expect onboarding Welcome, signed out);
  terminate; launch `SHELL(home)`; terminate; launch `GUEST`. Repeat the `SHELL(home)` cold launch
  3 times, terminating between runs.
- Evidence: screenshot of each first screen; video of one cold launch from tap/launch to first
  frame; `log.txt`; `xcrun simctl spawn $UDID launchctl list | grep $BUNDLE` or `simctl` launch pid
  per run.
- Fail: any crash report, a black/white screen for more than 2 s after launch, the auth "restoring"
  screen never clearing, onboarding shown on `SHELL(home)`, or the shell shown signed out on
  `STORED`.

### SIM-02 Onboarding tour: every intro step

- Behavior: Welcome -> Approve -> Reply -> Sign In, with a progress bar, Back, and gated Continue.
- Steps: `ONBOARD()`. On Welcome confirm `onboarding.progress` and `onboarding.welcome.start`;
  tap Start. On Approve confirm `onboarding.continue` is disabled; tap `onboarding.approve.allow`;
  Continue enables; tap it. On Reply confirm Continue disabled; tap the `onboarding.reply.keep` chip;
  Continue enables; tap it. Confirm `onboarding.signIn.title`. Then relaunch `ONBOARD(approve)` and
  tap `onboarding.approve.deny`: Continue enables. Relaunch `ONBOARD()`, Start, then
  `onboarding.back`: Welcome returns.
- Evidence: one continuous video of the full walk (Welcome to Sign In) and the Back case; a
  screenshot of each step at rest (welcome, approve before/after answer, reply before/after chip,
  sign-in).
- Fail: Continue enabled before an answer; any step skipped or repeated; Back not returning to
  Welcome; animation that stutters to a stop (visible frozen frames longer than 250 ms in the video)
  or text clipped/overlapping at rest.

### SIM-03 Onboarding skip and "I have an account"

- Behavior: header Skip and "I have an account" both land on sign-in.
- Steps: `ONBOARD(approve)` -> tap `onboarding.skip` -> sign-in. `ONBOARD()` -> tap
  `onboarding.welcome.haveAccount` -> sign-in.
- Evidence: screenshot of the sign-in landing for each; short video of each tap.
- Fail: either path lands anywhere but `onboarding.signIn.title`, or shows a tour page in between.

### SIM-04 Onboarding resume after relaunch

- Behavior: stored progress resumes at the step the user left (signed out, intro phase).
- Steps: erase PRIMARY (fresh keychain and defaults). Launch `STORED`; Welcome shows. Start, answer
  Approve (Allow), Continue to Reply. Terminate the app (`simctl terminate`). Launch `STORED` again.
- Evidence: screenshot before terminate (Reply) and after relaunch; video of the relaunch.
- Fail: relaunch shows Welcome again, skips past Reply to a later step without the reply answer, or
  presents the signed-in shell.

### SIM-05 Onboarding setup steps (signed-in replay)

- Behavior: the setup phase renders every applicable step: Notifications priming, Install on Mac,
  Local Network priming, Pair, SSH host, Celebrate; Keep Mac Awake and Cloud machine only with their
  flags.
- Steps: `SHELL(settings)` plus `CMUX_IOS_FLAG_KEEP_AWAKE=1` and `CMUX_IOS_FLAG_CLOUD_ONBOARDING=1`;
  tap `shell.settings.replayTour`; confirm `onboarding.progress`; advance through every step with its
  primary or Not Now action. On Notifications, allow the system prompt in one run and choose Not Now
  in a second run. On Pair, the simulator has no camera: the manual/setup-help path must be offered.
  Repeat once without the two flags and confirm Keep Awake and Cloud steps are absent.
- Evidence: screenshot of every step at rest; video of the full replay; screenshot of the system
  notification prompt.
- Fail: a step blank or with placeholder copy; Pair dead-ends with a camera error and no manual
  path; flagged steps shown with flags off (or missing with flags on); the tour cannot finish back to
  the shell.

### SIM-06 Onboarding with Reduce Motion (optional)

- Behavior: with Reduce Motion on, onboarding transitions are crossfades or instant, not slides or
  bouncing animations.
- Steps: Simulator Settings > Accessibility > Motion > Reduce Motion on (via the Settings app UI, not
  `defaults write`); `ONBOARD()`; walk Welcome -> Approve -> Reply.
- Evidence: video; frame-split showing no large translational motion between steps.
- Fail: the same slide/spring animation as with Reduce Motion off.

### SIM-07 Sign-in screen

- Behavior: signed out with onboarding skipped, the sign-in screen shows the provider buttons
  (Apple, Google, GitHub, email code), legal links, and "Use SSH Without an Account".
- Steps: erase; launch with only `CMUX_IOS_ONBOARDING=0`, `CMUX_IOS_SOURCES=mock`. Tap the email
  option and confirm a field appears and the keyboard docks without covering it; dismiss.
- Evidence: screenshot of the sign-in screen (light and dark); video of opening the email field.
- Fail: missing providers or the SSH option; the keyboard covers the active field; any provider tap
  crashes. (A real sign-in completing is not required on the simulator.)

### SIM-08 Guest mode ("Use SSH Without an Account")

- Behavior: choosing the SSH option opens the guest shell with exactly Workspaces, Hosts and
  Settings; feature routes that need an account show the toast "Sign in to open this. SSH hosts work
  without an account."; the choice persists across relaunch.
- Steps: from SIM-07, tap "Use SSH Without an Account". Inspect the tab bar. Open Hosts and add a
  host (SIM-20 form). Terminate and relaunch `STORED`. Separately launch `GUEST` on a fresh install.
  In Settings, find the sign-in / sync offer.
- Evidence: screenshot of the guest tab bar; screenshot after relaunch; accessibility dump of the
  tab bar.
- Fail: Feed, Compose, Search, Cloud or Home tabs visible in guest; relaunch returns to sign-in;
  added host lost after relaunch; no way back to sign in.

### SIM-09 Shell tabs render real mock content

- Behavior: every tab opens with its root and non-placeholder content on mocks.
- Steps: for each `tab` in `home feed workspaces compose hosts search cloud settings`, launch
  `SHELL(tab)`; confirm the root identifier (`home.screen`, `feed.screen`, `workspaces.list`,
  `composer.screen`, `ssh.hosts.list`, `search.screen`, `cloud.screen`, `shell.settings`). Then from
  `SHELL(home)` select every tab through the tab bar (iPhone uses a More overflow when tabs exceed the
  bar; select those from More).
- Expected content: Feed lists `feed.item.feed1` (permission) through feed5; Workspaces lists
  `workspaces.row.ws_studio1` (Mac Studio, reachable) and `ws_mini1` (Mac mini, "Asleep");
  Hosts lists `ssh.host.ssh-devbox`; Cloud lists the `devbox` (running) and `scratch` (paused) mock
  machines; Compose shows `composer.target` and a disabled `composer.send`; Settings shows
  `shell.settings.profile` and `shell.settings.version`; Home shows the mock inbox.
- Evidence: one screenshot per tab (PRIMARY, light); video of the tab-bar walk including More.
- Fail: any tab empty, showing a spinner for over 3 s, or showing an error/offline state on mocks;
  a tab unreachable from the bar.

### SIM-10 Feed: permission Allow and Deny (optimistic)

- Behavior: answering a permission resolves the card immediately (optimistic), shows a resolution
  line ("Allowed..." / "Denied..."), and removes the controls.
- Steps: `SHELL(feed)`. Open `feed.item.feed1` (detail `feed.detail`); tap `feed.action.allow`.
  Relaunch; open feed1; tap `feed.action.deny`. Also, in the list, use the card's inline buttons
  (via VoiceOver custom actions in the accessibility inspector, or a direct tap where the card
  exposes them) and confirm the same result. Try `feed.action.allowOptions` and confirm Once /
  Session / Always scopes are offered.
- Evidence: video of each answer from tap to resolution; screenshot of the resolved card; frame
  timestamps for tap and resolution.
- Fail: the resolution appears later than ~100 ms (more than 6 frames at 60 fps in the video) after
  the tap; controls remain; the list does not reflect the resolution after going back; the Needs
  Input filter still counts the item.

### SIM-11 Feed: question reply and suggestion chip

- Behavior: a question (`feed5`, "Which branch should I base the fix on?") answers by chip or typed
  reply; the composer's Send is disabled while empty.
- Steps: open feed5; tap `feed.suggestion.main` -> resolution contains "main". Relaunch; open feed5;
  tap `feed.action.reply`; confirm `feed.composer.send` disabled; type "d3 release branch"; Send.
  Also answer the multi-question choice item `feed2` (pick an option, Submit).
- Evidence: video of each; screenshot of each resolution; screenshot of the keyboard with the reply
  composer docked above it.
- Fail: Send enabled when empty; composer stays open after Send; resolution missing the text;
  keyboard covers the composer.

### SIM-12 Feed: plan approval

- Behavior: the plan item (`feed3`, plan.md with Schema/Handler/Tests) offers Approve and Request
  Changes; Approve resolves "Plan approved"; Request Changes takes text and resolves.
- Steps: open feed3; Approve. Relaunch; open feed3; Request Changes; type; send.
- Evidence: video; screenshots of both resolutions.
- Fail: checklist not shown; either action leaves the item unresolved.

### SIM-13 Feed filters, menu and floating compose

- Behavior: `feed.filter` switches All / Needs Input / Unread with correct empty states; the menu
  offers Group By and Mark All Read; the floating button `composer.floating` opens the composer.
- Steps: `SHELL(feed)`; cycle filters; Group By workspace and agent; Mark All Read; tap the floating
  compose button.
- Evidence: screenshot per filter and grouping; video of the floating button opening the composer.
- Fail: a filter shows items that do not match; empty state copy missing; floating button absent or
  dead.

### SIM-14 Workspaces list -> detail -> terminal on the mock host

- Behavior: list shows both Macs with status; a row opens the detail with surfaces; a terminal
  surface opens a full-screen terminal (tab bar hidden) rendered by the Ghostty renderer.
- Steps: `SHELL(workspaces)`; scroll to `ws_mini1` (asleep reason visible); tap
  `workspaces.row.ws_studio1` -> `workspaces.detail` with `workspaces.surface.tab_s1a` (Claude Code),
  `tab_s1b` (zsh), `tab_s1c` (browser); tap `tab_s1b` -> `terminal.screen` and `terminal.view`;
  back returns to detail; open `workspaces.changes` -> `viewers.changes`.
- Evidence: screenshot of list, detail, terminal, changes; video of the whole navigation.
- Fail: terminal blank or showing only a background with no prompt text; tab bar visible over the
  terminal; back does not return to detail; Changes empty or erroring on mocks.

### SIM-15 Terminal renders, echoes, key bar

- Behavior: the mock host prints a prompt (`lawrence@mini ~/cmux %`) in the grid area; typed keys
  echo once, in order; Return runs the line; the key bar (Esc, Ctrl, Alt, Tab, arrows, `~ | / -`,
  paste, hide keyboard) is above the keyboard and its keys reach the terminal; Ctrl latches
  (armed/locked states).
- Steps: open the terminal as in SIM-14 (or `TERMPREVIEW`); tap the terminal to focus; type
  `echo hello`, Return; tap Ctrl then `c`; tap the arrow keys; Tab; hide keyboard via
  `terminal.key.hideKeyboard`; tap again to show. Wait for the mock grid change (default 4 s,
  `CMUX_IOS_TERMINAL_GRID_CHANGE_SECONDS`) and confirm the redraw is clean.
- Evidence: video of typing (frame timestamps of keypress to glyph); screenshot of the key bar
  with the keyboard up; zoom screenshot of rendered text (legible, no garbled cells).
- Fail: no prompt text; a character doubled, dropped or out of order; key bar missing or covering
  the last terminal row; keyboard covers the cursor row; garbage after the grid change.

### SIM-16 Terminal rotate and pinch font

- Behavior: rotating to landscape and back reflows the grid to the new size with no clipped rows;
  pinch zooms the font with a size HUD; the Text Size commands work.
- Steps: in the terminal (keyboard shown), rotate left (`Device > Rotate Left` / Cmd-Left in
  Simulator), then back; pinch out and in (Option-drag in Simulator); use the terminal command menu
  "Larger", "Smaller", "Actual Size".
- Evidence: video covering both rotations and the pinch; screenshots portrait and landscape at rest.
- Fail: text stretched or cut off after rotation; grid not refilling the width; HUD absent; font
  size not changing or not restoring with Actual Size; crash on rotation.

### SIM-17 Terminal selection, copy, links, hardware keyboard

- Behavior: long-press selects, the edit menu offers Copy/Select All/Paste; Esc/Ctrl/Option from a
  hardware keyboard reach the program; Command shortcuts do not get typed into the terminal.
- Steps: in the terminal, long-press a word, Copy, then paste into the terminal via key bar Paste.
  With `I/O > Keyboard > Connect Hardware Keyboard` on, type, press Ctrl-C, Esc, and Cmd-K.
- Evidence: video; screenshot of the edit menu.
- Fail: no selection handles/menu; paste inserts something else; Cmd-K text or a literal `k` in the
  terminal.

### SIM-18 Terminal benchmark reports numbers

- Behavior: the bench screen replays a workload through the real renderer and shows a summary with
  frames, p50 and p99 frame interval, hitches and MiB/s; `terminal-bench.json` is written in the app
  caches (`cmux-gallery/terminal-bench.json`).
- Steps: `BENCH(flood)`, `BENCH(htop)`, `BENCH(vim)` on PRIMARY; wait for `terminal.bench.summary`
  to change from "running" to the summary. Copy the JSON from
  `$(xcrun simctl get_app_container $UDID $BUNDLE data)/Library/Caches/cmux-gallery/terminal-bench.json`
  after each run.
- Evidence: screenshot of each summary; the three JSON files; video of the flood run.
- Fail: summary never leaves "running" within 120 s, or shows "unavailable"; JSON missing; `frames`
  0; `mib_per_s` 0 or missing; `display_max_fps` 0. Recorded but not pass/fail on the simulator:
  p50/p99 and hitch counts (device thresholds are in DEV-08).

### SIM-19 Composer send on mock

- Behavior: Compose shows target pill, agent/model/effort pills and the prompt; Send is disabled for
  an empty prompt (`composer.blocker` explains); after typing, Send dispatches and shows
  `composer.outcome` (started) on the mock sink.
- Steps: `SHELL(compose)`; confirm disabled Send; tap `composer.prompt`; type "d3 dogfood: run the
  FeatureKit tests"; open the agent, model and effort pickers once each; Send. Also save a template
  and reuse it.
- Evidence: video from typing to outcome; screenshots of the pickers and the outcome.
- Fail: Send enabled when empty; no outcome within 15 s; outcome shows refused/unsupported on mock;
  a picker empty.

### SIM-20 Hosts: Add SSH Host validation and Keys

- Behavior: `ssh.hosts.add` menu offers "Add SSH Host"; the editor's Save (`ssh.editor.save`) is
  disabled until name and address are valid; saving lists the new host; `ssh.hosts.keys` opens the
  key list (`ssh.keys.list`) with generate (Secure Enclave / Ed25519) options.
- Steps: `SHELL(hosts)`; Add SSH Host; check Save disabled empty; enter only a name (still
  disabled); enter an invalid port (e.g. `99999`) if a port field exists (must refuse); fill name
  `d3box`, address `d3box.local`, user `dev`; Save; row appears. Open Keys; generate an Ed25519 key;
  copy the public key.
- Evidence: screenshots of the empty, partial, invalid and valid form; screenshot of the new row and
  the key list; video of the add flow.
- Fail: Save enabled on an empty or invalid form; saved host missing; Keys screen empty with no
  generate action; generation crashes. (A Secure Enclave key may be unavailable on the simulator; it
  must say so, not crash.)

### SIM-21 Search: Cmd-K and typed results

- Behavior: Cmd-K from the shell opens Search with the field focused; typing returns grouped results
  across feed, workspaces and hosts; tapping a result opens it.
- Steps: `SHELL(settings)` with the hardware keyboard connected; Cmd-K -> `search.screen`,
  `search.field`. `SHELL(search)`; type "backend"; tap the first `search.result.*` hit; also try
  "devbox" (a host) and a nonsense string (empty state). Use hardware arrows over the field.
- Evidence: video of Cmd-K and typing; screenshot of results and of the empty state.
- Fail: Cmd-K does nothing; results do not update per keystroke; tapping a result does not open a
  workspace, feed item or host; no empty state.

### SIM-22 Settings pages

- Behavior: every Settings page opens with real content: profile and version, devices list and
  device detail (rename, remove), Terminal (theme, font, size, cursor, key bar, composer),
  Notifications preferences, Privacy (crash reports), What's New, Diagnostics, Developer (sources,
  mock offline), Demo (only with `CMUX_IOS_DEMO=1`), Replay Welcome Tour, haptics, Erase All Data
  (confirmation only, do not confirm unless on a throwaway simulator).
- Steps: `SHELL(settings)`; open `shell.settings.device.dev-phone` -> `shell.settings.deviceName`;
  `shell.settings.terminal`; `shell.settings.notifications`; `shell.settings.privacy`;
  `shell.settings.whatsNew`; `shell.settings.diagnostics`; `shell.settings.developer`
  (`shell.dev.source.feed`, `shell.dev.mockOffline`). `DEMO(settings)` -> `shell.settings.demo`.
  In Developer, toggle mock offline and confirm Feed/Workspaces show offline banners, then toggle
  back.
- Evidence: one screenshot per page; video of the devices list -> detail -> rename.
- Fail: any page empty or erroring; Demo row present without `CMUX_IOS_DEMO=1` or absent with it;
  mock offline toggle without visible effect.

### SIM-23 Terminal theme live preview

- Behavior: changing theme, font, size or cursor in Settings > Terminal updates the preview
  immediately, and the next terminal opened uses the new settings (SSH/host terminals; the DEV mock
  terminal is documented as not following settings, c11-settings.md 6).
- Steps: `SHELL(settings)` -> Terminal; change theme through 3 values, font size up/down, cursor
  shape; watch the preview.
- Evidence: video of the changes with the preview in frame; screenshots per theme.
- Fail: preview does not change within one frame-ish of the selection (more than ~200 ms); choice
  not persisted after relaunch.

### SIM-24 Diagnostics

- Behavior: Diagnostics shows log lines, crash reports row, Share, Copy Support Info (confirms
  "Copied"), Clear Log (asks first, then clears).
- Steps: `SHELL(settings)` -> `shell.settings.diagnostics`; Copy; Share (share sheet appears; cancel);
  Clear Log -> confirm.
- Evidence: screenshots before/after clear; screenshot of the share sheet; video of Copy feedback.
- Fail: no lines; Copy label not changing; Clear without confirmation; share sheet missing.

### SIM-25 Cloud tab on mock

- Behavior: Cloud lists the mock machines in sections (active, paused), usage section; New Machine
  (`cloud.new`) opens a sheet with name and size; Create adds a row; row actions pause/resume/delete
  update status with progress states.
- Steps: `SHELL(cloud)`; confirm `cloud.machine.vm_mockdevbox0000000001` and
  `cloud.machine.vm_mockscratch00000002`; New -> name `d3-sim` -> `cloud.create.confirm`; pause
  devbox; resume scratch; delete the new machine (confirm dialog).
- Evidence: video of create and lifecycle actions; screenshots at rest after each.
- Fail: sheet does not close; row not added; status never settles; delete without confirmation.

### SIM-26 Dark and light mode

- Behavior: every primary screen is legible in both appearances with no hard-coded white/black
  surfaces or invisible text.
- Steps: `xcrun simctl ui $UDID appearance light`, capture Home, Feed (list and a detail), Workspaces,
  terminal, Compose, Hosts, Settings, onboarding Welcome, sign-in; switch to `dark` and repeat; switch
  appearance once while Feed is visible.
- Evidence: paired light/dark screenshots per screen; video of the live switch.
- Fail: unreadable contrast (text on near-identical background), a surface that does not switch,
  or a flash/relayout glitch on the live switch.

### SIM-27 Dynamic Type at an accessibility size

- Behavior: Feed, Workspaces and Settings (and the onboarding Approve step) scale text at
  `accessibility-extra-extra-extra-large` (AX5) without truncating essential labels or overlapping;
  rows grow; buttons remain reachable; the unread badge and chips scale.
- Steps: `xcrun simctl ui $UDID content_size accessibility-extra-extra-extra-large`; launch
  `SHELL(feed)`, `SHELL(workspaces)`, `SHELL(settings)`, `ONBOARD(approve)`; scroll each; change
  size live once while Feed is visible; restore `large`.
- Evidence: screenshots at AX5 per screen (top and scrolled); video of the live change.
- Fail: overlapping text, clipped buttons with no way to reach them, single-line truncation of item
  titles to under ~5 characters, layout not updating on the live change.

### SIM-28 VoiceOver labels on key controls

- Behavior: key controls have meaningful labels, traits and actions in the accessibility tree:
  tab bar items; feed cards (one element with custom actions Allow/Deny/Reply); workspace rows and
  the detail "Workspace Actions" menu; terminal key bar keys (Escape, Control, Tab, arrows...);
  composer Send and pickers; Hosts add/keys; Cloud size rows (selected/disabled read as state, not
  "Checkmark"/"Lock"); Settings rows; onboarding Continue/Back/Skip.
- Steps: for each listed screen capture the accessibility tree dump; optionally run Accessibility
  Inspector's audit on Feed, Workspaces, terminal and Settings.
- Evidence: tree dumps (text) with the relevant lines quoted in the verdict; audit output if run.
- Fail: an interactive element with an empty label or a label equal to its SF Symbol name or
  identifier; duplicated announcements of one control; feed card actions missing.

### SIM-29 Japanese localization smoke

- Behavior: with Japanese language and region, Feed and Settings (plus the tab bar) show Japanese
  strings, no English leftovers in app-owned copy, no raw keys, and layout holds.
- Steps: launch `SHELL(feed)` and `SHELL(settings)` with `-AppleLanguages '(ja)' -AppleLocale ja_JP`
  instead of English; open one feed detail and the Terminal settings page.
- Evidence: screenshots of each screen.
- Fail: any raw key, English UI strings in app-owned copy (mock fixture content such as titles may
  stay English), clipped Japanese text, wrong plural/number formatting (e.g. "1 panes"-style).

### SIM-30 Small and large device layout

- Behavior: on SMALL and LARGE, onboarding Welcome, sign-in, Feed, Feed detail with the reply
  keyboard up, Workspaces detail, terminal with key bar and keyboard, Compose and Settings fit with no
  clipped controls; the tab bar overflow is correct for the width.
- Steps: repeat the relevant launches from SIM-02, SIM-07, SIM-09, SIM-11, SIM-14, SIM-15, SIM-19
  on SMALL and LARGE (portrait; terminal also landscape).
- Evidence: screenshots per screen per device; video of the terminal keyboard on SMALL.
- Fail: a primary action off-screen or under the keyboard/home indicator; key bar overlapping the
  last row; sheets that cannot be dismissed on SMALL.

### SIM-31 Performance: feed and workspaces scrolling

- Behavior: list scrolling stays smooth with no main-thread hangs.
- Steps: on PRIMARY (and SMALL if time allows), with the app in `SHELL(feed)` and then
  `SHELL(workspaces)`, record `xcrun xctrace record --template 'Animation Hitches' --device $UDID
  --attach <pid> --time-limit 30s` (fall back to a custom trace with Hangs + Time Profiler +
  os_signpost if the template is unsupported on the simulator), performing 5 s of fast flings up and
  down 3 times. Separately record Time Profiler 10 s with Home visible and nothing changing.
- Evidence: the `.trace` files; exported summaries (`xctrace export`) of hitch count, total hitch
  time, hangs and main-thread top symbols; video of the flings.
- Pass bars (simulator, indicative of ios-rewrite.md 9 whose device bars are 120 Hz and 0 hitches
  over 5 s flings): no hang over 250 ms; hitch time ratio under 5 ms/s over the fling windows; no
  single hitch over 100 ms; idle Home 0% CPU after settle (no repeating timer or polling stack in the
  idle profile). Fail on any of these; record the raw numbers either way.

### SIM-32 Performance: terminal flood benchmark under Instruments

- Behavior: the flood workload renders at most one frame per vsync with parsing off the main thread.
- Steps: `BENCH(flood)` under `xcrun xctrace record --template 'Time Profiler' --device $UDID
  --launch -- <app> ` (or attach right after launch) with the os_signpost instrument added
  (subsystem `dev.cmux.ios`, category `terminal`, intervals `frame` and `workload`); 60 s limit.
- Evidence: the trace; signpost interval export; main-thread heaviest stack; the run's
  `terminal-bench.json`.
- Pass bars: the run completes; `frame` signposts present; no hang over 250 ms; main thread not
  dominated (over 50% of samples) by byte parsing; reported hitches recorded. Device bars (8.3 ms
  p99 at 120 Hz) are DEV-08.

### SIM-33 Cold start timing (indicative)

- Behavior: first Home frame quickly after launch on the cached/mock inbox.
- Steps: 5 cold launches of `SHELL(home)` under `xctrace --template 'App Launch'` (or signposts from
  process start to first list commit, if exported).
- Evidence: traces and the five durations.
- Pass bar: median under 1.5 s on the simulator (device bar 400 ms is DEV-09). Fail above.

### SIM-34 Next*UITests green on a CI simulator

- Behavior: the ten `Next*UITests` classes pass on the exact head.
- Steps: dispatch `gh workflow run test-ios.yml --repo manaflow-ai/cmux --ref feat-cmux-next-ios -f
  ui_tests=true` (d3-dogfood.md 6.4); wait with `glaeda-gh wait run`; download the
  `ios-next-uitests` artifact.
- Evidence: `summary.txt`, the xcresults and per-test recordings.
- Fail: any test failing, or skipped without a recorded reason. A known flaky-first-run risk
  (d3-dogfood.md 3) must be resolved, not waived.

## 2. Teardown

Terminate the app, stop log streams and recordings, `xcrun simctl delete` the three simulators,
and remove scratch outside `artifacts/ios-next-verify/` once the evidence is uploaded.

## 3. Physical-device criteria (blocked: need the signed phone build)

All of these require the tagged iPhone build and the same-tag Mac pair (`nxd3`, d3-dogfood.md 6),
which is blocked on signing credentials. Real-Mac terminal paths also need D1b's
`MobileLinkHostAccount` on the cmux-next Mac (d3-dogfood.md 2.1). Mark each BLOCKED until then.

- **DEV-01 Same-account pairing**: the tagged Mac appears trusted without a QR; Settings > Devices
  shows it with a route badge; QR pairing for a second account; revoke kicks a live session.
  Evidence: screen recording on the phone, Mac debug log. (d3 2.2 items 5, 6)
- **DEV-02 Carriers**: V1 `p2p` on same Wi-Fi, DEV Force TURN shows `turn`, V3 direct over Tailscale
  `100.x` and LAN with one Local Network prompt; a tampered SDP fingerprint fails with `auth`.
  (d3 2.2 items 7, 8, 10)
- **DEV-03 Terminal over a carrier**: workspace -> terminal on the real Mac: snapshot appears,
  typing echoes once in order, rotate and keyboard resize the grid, Wi-Fi off/on shows Reconnecting
  then clears with no lost or duplicated input. Echo p50 under 30 ms on LAN (ghostty-next.md 8).
  (d3 2.3 items 11 to 15, 6.3)
- **DEV-04 Roam**: Wi-Fi to cellular mid-terminal keeps or resumes the session with no gap.
- **DEV-05 Push**: token registration; push delivery; NotificationService decisions; lock-screen
  Allow/Deny/Reply/plan Approve under the background budget; remote dismiss; badge = unread; Live
  Activity. (d3 2.4 items 18 to 21)
- **DEV-06 Feed on real FeedDO**: inline approve, multi-question, quoted reply, read state synced
  across devices.
- **DEV-07 Features over the link**: browser stream (C2), 200 MB file download with resume (C4),
  composer live dispatch and dictation (C8), live SSH trust/changed-key/key install/reconnect with a
  Secure Enclave key (C9), viewers on a real repo (C13). (d3 2.5)
- **DEV-08 Terminal performance on device**: `CMUX_IOS_TERMINAL_BENCH=flood|htop|vim` at 120 Hz:
  p99 frame interval at or under 8.3 ms with hitches recorded; 10 min Power Profiler per carrier;
  under 150 MB resident for three live terminals (ghostty-next.md 9).
- **DEV-09 App budgets** (ios-rewrite.md 9): cold start to first Home frame under 400 ms; live data
  under 1.2 s on Wi-Fi; 0 hitches over 5 s flings at 120 Hz; idle Home memory under 120 MB and 0%
  CPU; send tap to bubble under 1 frame.
- **DEV-10 Onboarding on a fresh install**: real permission prompts (notifications, local network,
  camera for QR), Not Now respected at next launch, real QR scan. (d3 2.6 item 27)
- **DEV-11 Accessibility on device**: VoiceOver pass over every tab, AX5, Reduce Motion. (d3 2.6
  item 32)
- **DEV-12 Hardware keyboard and IME**: KeyboardAuditUITests re-run on device; Japanese IME in the
  terminal and composer. (d3 2.3 items 15, 16)

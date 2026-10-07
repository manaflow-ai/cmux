# Quit persistence: Cmd-Q keeps sessions, asks in a cmux dialog

Status: audit + design, 2026-10-04 (hq48). Code audited at `b3105b0f003` (origin/feat-cmux-next at
the start of the audit; the `Quit/` and `CmuxNextDaemon/Connection/` trees are unchanged at
`019d7ff4d24`). Live run on cmux-lawrence-2 with fleet build `9087e8aaea3ab89192e52ba0`, tag
`hq48qp-v1`, from that exact SHA.

Lawrence's requirement: "we need to have confidence that we can cmd + q and then sessions +
terminals will still persist (if user chooses, cmd q should show prompt, to choose behavior) must
not be system prompt but rather the better cmux built in dialog thing".

Coordinator conditions (R138): the quit flow uses CmuxDialog (R96 NO-SYSTEM-DIALOGS), which replaces
the "quit = plain NSAlert" decision; the default choice is Keep sessions running; the setting is
`app.quitBehavior`; the dialog works when the window is not key and for a quit from the Dock; an
automated quit-and-relaunch proof runs on cmux-lawrence-2. The work is split between the dialogs
lead and the durable-sessions owner.

Paths below are relative to `Packages/macOS/CmuxNext/Sources/` unless they start with `cmux-tui/`.

## 1. What happens today

### 1.1 The quit path

- Cmd-Q is the `quit` action (`CmuxNextActions/Catalog/WindowActionCatalog.swift:55-89`; CLI
  `app quit [--keep-sessions|--end-sessions|--end-everything]`). The app menu lists `quit`,
  `quitKeepSessions`, `quitEndSessions`, and `quitEndEverything` (`CmuxNextApp/MainMenu.swift:15,26`).
  The actions are bound at `CmuxNextApp/AppActions.swift:79-89`.
- `requestQuit` ignores a repeated request while a quit is in progress, ends the open sheets, and
  calls `NSApp.terminate` (`CmuxNextApp/Quit/QuitCoordinator.swift:26-36`).
- `applicationShouldTerminate` (`CmuxNextApp/AppDelegate.swift:212-215`) calls
  `QuitCoordinator.shouldTerminate` (`QuitCoordinator.swift:48-66`). That function returns
  `.terminateLater`, reads the origin (the `kAEQuitReason` is read at `:125-131`) and the setting,
  then decides with `QuitPolicy.decide` (`Quit/QuitPolicy.swift:28-59`):
  - Power-off (`kAELogOut`, `kAERestart`, `kAEShutDown`, …, `Quit/QuitOriginTracker.swift:15,36-39`)
    and signals (SIGTERM, SIGINT, SIGHUP, `Quit/QuitSignal.swift:22-28`) always keep sessions and
    never ask.
  - An explicit choice (menu item, CLI flag) runs that choice. A scripted quit (socket or CLI
    without a flag) uses the remembered choice, else keep.
  - An interactive quit asks only when local PTY terminals or incognito programs exist and no
    choice is remembered (`:42-49`). The facts come from `Quit/QuitFactsReader.swift:13-43`,
    which reads only PTY tabs. **Agents are never counted.**
- The setting is `app.quitBehavior` = `ask` (default) | `keep` | `end-keep-layout` |
  `end-everything` (`CmuxNextSettings/QuitBehaviorSetting.swift:3-24`). It shows in Settings as
  "When Quitting" (`CmuxNextSettings/Schema/SettingsSchema.swift:91-103`) and in
  `schemas/settings/settings-schema.json:345-380`.
- The prompt is a **system `NSAlert`**: `Quit/QuitAlert.swift:4` reads "The quit question as
  plain NSAlerts". It is a sheet on a visible window, else a floating panel (`:69-89`), on the
  window that `sheetWindow()` picks (`QuitCoordinator.swift:119-122`: active, then main, then any
  visible window). The buttons are Quit (keeps the sessions), Cancel, and "End Sessions…", plus a
  "Don't ask again" check box. "End Sessions…" opens a second alert with "End Sessions, Keep
  Layout", Cancel, and "End Everything".
- The decision to use a plain NSAlert is commit `4f5c318b408` (2026-09-30, "cmux-next quit: a
  plain NSAlert, end choices behind End Sessions…", from user feedback that "the quit sheet was too
  designed"). It is superseded by `plans/cmux-next/coordination/dialogs.md:4` on
  `feat-cmux-next-dialogs` (`3cea5c2880f`): "every dialog is a cmux dialog, no system alerts or
  panels (Lawrence 2026-10-04; supersedes "quit = plain NSAlert")". **That branch is not merged:
  it is 15 commits ahead of and 100 behind origin/feat-cmux-next.** On that branch,
  `Quit/QuitAlert.swift` already presents through `CmuxDialogCenter` (`.window(w)` or `.app`), with
  Return for Quit (keep) and Escape for Cancel.
- Completion (`QuitCoordinator.swift:84-116`, `Quit/QuitCompletion.swift:18-25`) runs in this
  order:
  1. Write the crash-recovery "quitting" marker.
  2. Remember the choice, if asked.
  3. Save the remote-terminal screens, flush the browser tab records, and run
     `windows.prepareForTermination()` (incognito windows close, window records flush) and the
     sidebar flush.
  4. For an End choice only, `daemon.endSessionsAndStop`.
  5. Shut down CEF last (`CmuxNextBrowser/CEF/CEFEngine.swift:175`).
  6. Reply to AppKit.
- `applicationWillTerminate` (`AppDelegate.swift:243-255`) closes only the daemon connection
  (`DaemonService.swift:353-367`). It sends nothing to the daemon.
- An update relaunch records `.explicit(.keep)` (`CmuxNextApp/UpdaterService+App.swift:12`), so it
  shows no prompt and keeps the sessions.

### 1.2 The daemons

- **cmux-tui (terminals).** The app launches it with `server ensure` and a detached owner
  (`CmuxNextDaemon/Launch/DaemonLauncher.swift:5-7,211-234`). The owner is created with `setsid()`
  (`cmux-tui/crates/cmux-tui/src/local_owner.rs:447-520`), and each PTY has its own `setsid`
  `__terminal-host` (`cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime.rs:1955-1981`). The
  daemon has no idle exit and does not exit when its last client disconnects
  (`cmux-tui/crates/cmux-tui/src/headless.rs:47-51`).
- **The reaper.** The app starts the daemon with `--terminal-reap-grace-seconds 30`. The reaper
  ends only *unplaced* terminals, so a quit and relaunch cannot reap a placed terminal
  (`cmux-tui/crates/cmux-tui-core/src/mux/terminal_reap.rs:1-15`). The live run confirms this:
  the app was down for more than 30 s and both terminals were kept.
- **acpmux (agents).** `CmuxNextAgentPane/AcpmuxDaemonLauncher.swift:23,67` uses `/bin/sh -c 'set -m;
  … &'` with `POSIX_SPAWN_SETSID`, so launchd adopts the daemon. The home is
  `~/.acpmux/tags/<tag>` on tagged builds. The app never stops it: the only `_acpmux/shutdown`
  call is the version handoff (`AcpmuxVersionHandoff.swift:67`). **End Sessions and End
  Everything do not end agents** (slice A4 `endAgents` is planned:
  `plans/cmux-next/durable-sessions.md:217-228`).
- **Terminal end mechanism (End choices).** `shutdown-daemon end_terminals`
  (`CmuxNextDaemon/Connection/DaemonConnection+Commands.swift:318-324`) makes each host send
  SIGHUP to the terminal process groups, wait for a bounded grace, then send SIGKILL
  (`terminal_host_runtime.rs:4664-4686`).

### 1.3 Relaunch

- `ensure()` reuses the running owner. Windows are drawn from the launch snapshot, then from the
  daemon's `personal` window document (`Windows/WindowManager.swift:154-216`).
- Terminals reattach to the **same** `term_…` id and generation with `attach-surface`
  (`TerminalAttachment.swift:158-164`). The daemon's replay is a GHOSTSNP snapshot or up to 32 MiB
  of bytes (`CmuxNextDaemon/Requests/TerminalIO/Input.swift:29-60`). No new shell is started.
- Browser tabs are daemon records and reopen at their URL (`BrowserTabService.swift:8-12`).
- **Agent tabs are not restored**: "cmux-tui has no agent tab kind yet, so … they live only in
  this app session and are not restored after relaunch" (`CmuxNextApp/AgentTabs.swift:8-12`). The
  acpmux session itself is durable (`cmux-tui/crates/acpmux/src/store.rs:1-5`).

### 1.4 Plans: landed versus planned

- `plans/cmux-next/durable-sessions.md` §1 "Today's truth" (:20-27): an app quit or crash keeps
  terminals and agents. An acpmux restart or crash loses agents and the turn in progress. **One
  stale row:** the "Sparkle update" row (:23) says the old daemons keep running. That is no
  longer true, because slice UP (the update handoff for both daemons) landed
  (`DaemonService.swift:116-125`, `AcpmuxVersionHandoff.swift:30-35`).
- Landed: R41 (no false "Process exited"), UP, keep-layout on End Sessions, browser tabs survive a
  quit (`82373908793`), GHOSTSNP scrollback restore (`85e9f54cc4a`).
- Planned, not landed: agent hosts A1-A4 (on `feat-cmux-next-durable-sessions`, "not landed",
  `durable-sessions.md:153`) and P1/P2. Until A3 lands, an acpmux handoff kills a running turn.
  The handoff runs only when the running acpmux reports `agentHosts`, and today no acpmux build
  reports it (`AcpmuxVersionHandoff.swift:30-35`). Until then an update keeps the old acpmux
  running.
- There is no separate session-restore plan. The promises are in `architecture.md:23` ("Quit is
  free … Relaunch = connect + snapshot"), `cmux-tui-contract.md:14,171-188`, and
  `REWRITE.md:91`.

## 2. Live results (cmux-lawrence-2, tag hq48qp-v1)

Setup:
- I started the app (PID 69209). It started cmux-tui (69331) and acpmux (69343). Each of the
  three has PPID 1 and its own PGID.
- I created workspaces `qp-term` (`ws_7f0e…`, `term_92a1…`) and `qp-second` (`ws_563f…`,
  `term_1406…`). Home was already there.
- In `term_92a1…` I wrote a marker, `HQ48-SCROLLBACK-MARKER`, then 200 `pre-N` lines. Then I
  started a loop `sh -c 'while true; do echo tick-$i; sleep 1; done'` (shell PID 72569, loop PID
  72798).
- I created the agent session `hq48-agent` (acpmux id `01a1071f-f767-7e43-a9cd-32e53bdb9836`) and
  sent a turn that ran `for i in $(seq 1 600); do echo agent-tick-$i; sleep 1; done` through the
  Bash tool. The processes were `sr` 74270, `claude` 74274, and the tool shell 74526.
- I opened an Agent tab in Home through `action.run palette.newAgentChat`.

Run 1, keep:
- `debug.quit {open:true}` started the quit the same way as Cmd-Q. The NSAlert reported "Quit
  cmux?" and "Your 2 terminals keep running in the background.", with `default: keep` and
  `running_programs: 0`.
- `{press:"quit"}` at 13:38:45Z ended the app in 2 s. I waited 40 s, which is more than the reap
  grace, then relaunched (new app PID 90795).

| Item | Survived | Evidence |
| --- | --- | --- |
| App process | quit (expected) | 69209 gone at 13:38:47 |
| cmux-tui daemon | yes | 69331 alive after relaunch; the relaunched app reused it (no new owner) |
| Terminal processes | yes | 72569 and 72798 alive throughout |
| Terminal ids | yes | the `terminal list` ids before and after are equal (`term_1406…`, `term_92a1…`) |
| Running command | yes | the tick counter ran on, from tick-191 before the quit to tick-399 after the relaunch, with no gap (303 contiguous lines in `history read`) |
| Scrollback | yes | the marker and `pre-1` are in the history after the relaunch; screenshot `post-term.png` |
| Workspaces / layout | yes | the same 3 daemon workspaces and the same window id `2fee6f22…` with 3 workspaces; the sidebar shows qp-term and qp-second |
| acpmux daemon | yes | 69343 alive |
| Agent turn in progress | yes | the tool kept running (74526 alive, `tool_progress` 90 s → 300 s); the turn **completed** at 611.8 s with "DONE", after three app quits |
| Agent session id / history | yes (in acpmux) | `acpmux ls` showed the same session and turn 7 |
| Agent tab in the window | **no** | `post-home.png`: Home shows only Chief; the Agent tab is gone (`AgentTabs.swift:8-12`) |
| Prompt counts | **wrong** | `running_programs: 0` while the `sh` loop ran; agents are not counted |
| Prompt in `debug.window_snapshot` | **not captured** | `prompt.png` shows the dimmed window without the NSAlert sheet: the system panel is outside the composited capture |

Run 2, End Everything, on the relaunched app:
- `{press:"end"}` then `{press:"end-everything"}`. The app quit in 1 s, and **nothing ended**.
  cmux-tui 69331, both terminal hosts, 72569, and 72798 were alive. All 3 workspaces were still
  there.
- The app log shows the cause: `end sessions failed: close-workspace failed: home_not_closable:
  the home workspace ws_3b7f… cannot close`.
- `closeEveryWorkspace` (`DaemonConnection+Commands.swift:328-338`) sends `close-workspace` for
  the Home workspace too. The first error throws, `shutdown-daemon` is never sent, and
  `DaemonService+Quit.swift:29-31` logs the error and lets the quit go on. **This is a P1 bug.**
  The user chose to end everything, and every terminal keeps running without any warning.

Run 3, End Sessions, Keep Layout (relaunch, app PID 12573):
- The log says "ended 2 terminals, kept layout true, daemon stopped". cmux-tui 69331, both hosts,
  72569, and 72798 are gone.
- acpmux 69343 and claude 74274 were **still alive**. The agent turn completed later, which
  confirms that End choices never touch acpmux.

Cleanup: I stopped acpmux 69343 with `acpmux daemon shutdown` in its tag home. I also stopped an
acpmux that I had started by mistake in the default home (73252). My `acpmux daemon harnesses`
call ran without `ACPMUX_HOME` and auto-started it, and I shut it down the same way. No processes
from this run remain. Screenshots: `cmux-lawrence-2:~/hq48qp/{pre-1,prompt,post-home,post-term,post-agent}.png`.

## 3. Gaps

1. G1 (dialogs): the quit prompt is a system NSAlert. The CmuxDialog conversion exists only on
   the unmerged `feat-cmux-next-dialogs`.
2. G2 (durable sessions, P1): End Everything aborts on `home_not_closable` and quits with every
   terminal still running.
3. G3 (durable sessions): no End choice ends agents. "Quit everything" leaves acpmux and a turn in
   progress running (A4 `endAgents` is not landed).
4. G4 (app lifecycle and tabs): agent tabs are not restored after a relaunch. The session lives,
   but its tab is lost. cmux-tui needs an agent tab kind, or the app needs a persisted local
   record (session id, pane, index).
5. G5 (dialogs and app lifecycle): the prompt facts omit agents (`QuitFactsReader.swift:13-43`),
   and `running_programs` read 0 for a running `sh` loop. Probably `process-info` treats `sh` as
   the shell, or an unmounted surface does not answer within the 1 s deadline. Not verified. An
   interactive quit with agents running and no terminals does not ask (`QuitPolicy.swift:44`).
6. G6 (dialogs): `debug.window_snapshot` cannot show the NSAlert. The CmuxDialog overlay is drawn
   in the window (the R84 `WindowOverlayHost`), so the conversion fixes this.
7. G7 (dialogs): a quit from the Dock while cmux is inactive. The NSAlert floating fallback uses
   `orderFrontRegardless`. The dialogs-branch `QuitAlert` says it "never activates the app by
   itself", so the user may not see the dialog. Not verified live.
8. G8 (docs): `durable-sessions.md:23` (the Sparkle row) is stale after UP.
9. G9 (setting values): the coordinator names `ask|keep|quitAll`. The landed values are
   `ask|keep|end-keep-layout|end-everything`. See decision D1.

## 4. Design

### 4.1 Dialog (owner: dialogs lead, R96)

- One `CmuxDialogSpec`, identifier `cmux.dialog.quit`, presented by `CmuxDialogCenter`. Never
  NSAlert, `runModal`, or `.alert`. Land `feat-cmux-next-dialogs`, or cherry-pick its `Quit/`,
  `CmuxNextDesign/Dialog/` and `debug.dialog` onto origin first.
- Content:
  - Title "Quit cmux?".
  - Lines, as needed: "N terminals and M agents keep running in the background."; "K agents are
    working on a turn now." (named, at most 3); "P programs are running: a, b, c."; the
    incognito and remote lines as today.
  - Buttons: **Keep Sessions Running** (default, Return; it is the current "Quit"), Cancel
    (Escape), and **Quit Everything…** (destructive, opens a confirmation).
  - "Don't ask again" check box.
  - The confirmation: "End N terminals and M agents?"; "Terminals get SIGHUP. Agents in a turn are
    cancelled."; buttons Quit Everything (destructive) and Cancel; plus the existing "End
    Everything (delete workspaces)" as a secondary button if D1 keeps it.
- Facts (`QuitFactsReader`): add `agents` and `agentsInTurn` from acpmux `_acpmux/status` /
  session list (the local tag home), with the same 1 s deadline. A missing answer counts as
  unknown, not zero, and the line then reads "Agents keep running in the background". Ask when
  `terminals > 0 || agents > 0 || incognito`.
- Scope: `.window(w)` on the window that `sheetWindow()` picks. That window is visible and not
  minimized, and it need not be key, which covers Cmd-Q while another window or panel is key.
  With no such window, use `.app`.
- A quit from the Dock or the app switcher while cmux is inactive: the quit is user-initiated, so
  `QuitCoordinator` activates the app (`NSApp.activate()`) before it presents. That is the one
  exception to "never activates by itself". Test it through `debug.quit {open:true, inactive:true}`.
- Cmd-Q pressed again while the dialog shows confirms the default (Keep Sessions Running; D2,
  decided). That
  matches "a second Cmd-Q quits" in Terminal and other apps. `requestQuit` (`:27`) sees
  `isQuitting` and calls `sheet.answerDefault()` instead of returning. A third press does nothing.
  On the confirmation step, a second Cmd-Q does nothing, so it can never confirm a destructive
  choice.
- No prompt for: an update or restart (the existing `.explicit(.keep)`), a signal (keep), or
  power-off and logout (`kAELogOut`, `kAEShutDown`, `kAERestart`, and the show-dialog variants).
  Power-off always keeps the sessions and ignores `quitAll` (D3, decided), because macOS ends the session
  processes during logout anyway, and blocking a logout on a cmux shutdown risks the "cmux
  stopped logout" panel. The layout survives through `session_shutdown.rs` (the tabs stay as host
  losses). The setting does not apply to power-off. State that in the Settings help text.
- Automation: `debug.quit` keeps its report shape. `press` ids are `keep`, `cancel`,
  `quit-everything`, `confirm-quit-everything`, `end-everything`, with the old ids as aliases.
  `debug.dialog` and `debug.window_snapshot` capture the dialog.

### 4.2 Setting (owner: app lifecycle)

- `app.quitBehavior`: `ask` (default) | `keep` | `quitAll`. `end-keep-layout` reads as `quitAll`
  and `end-everything` stays a value accepted for MDM (see D1). This uses the same migration hook
  as `legacyEnd` (`QuitBehaviorSetting.swift:43-47`).
- It is reachable in Settings ("When Quitting": Ask / Keep sessions running / Quit everything)
  and in the palette (`palette.quitBehavior.*`, three toggles through the existing settings
  action path), and it is documented in `settings-schema.json` and `docs/mdm`.
- "Don't ask again" writes `keep` or `quitAll`. A Cancel never writes.

### 4.3 Quit everything and keep running (owner: durable-sessions)

- Quit everything = `endSessionsAndStop(.quitAll)`:
  1. acpmux `endAgents`: cancel each turn in progress (`session/cancel`, bounded wait 5 s), then
     `_acpmux/shutdown`. The sessions stay resumable.
  2. cmux-tui `shutdown-daemon end_terminals keep_layout`: SIGHUP, grace, SIGKILL
     (`terminal_host_runtime.rs:4664-4686`).
  3. If either step fails, it is **not silent**: keep the dialog open with "Could not end N
     terminals: <reason>", with Retry and Quit Anyway.
- G2 is fixed (section 8): End Everything skips Home and collects every close error before
  `shutdown-daemon`.
- Keep sessions running: no change in the daemons. The live run proves the invariants: PPID 1,
  their own PGID and session (cmux-tui `setsid`, acpmux `POSIX_SPAWN_SETSID` plus `set -m`); the
  reaper touches only unplaced terminals; `applicationWillTerminate` only closes sockets. Guard
  these with tests (§5) so that a later change (a `kill_on_drop` in Swift, a launchd
  `AbandonProcessGroup=false` job, a reap grace on the placed set) cannot break them. launchd
  supervision is not needed for app quit. It belongs to the restart-after-crash work in
  `cmux-tui-contract.md` §1.5.
- Agent tabs survive (G4): persist each `LocalAgentTab` (acpmux session id, pane, index) in the
  daemon's window document. That is the same projection as browser tabs, and later a cmux-tui
  `agent` tab kind. On relaunch, reopen it with `select_session` on its id.

## 5. Tests

### 5.1 Unit tests (Swift Testing, run on the fleet)

- `QuitPolicyTests`:
  - Agents only → ask.
  - A remembered `quitAll` skips the prompt.
  - Power-off with `quitAll` → keep.
  - An update relaunch → keep, no prompt.
  - A second request while asking → default keep.
  - A second request on the confirmation step → nothing.
- `QuitAlertContent` and the spec: the default button is keep (Return), Escape is cancel, and the
  destructive button is on the confirmation only. The lines contain the terminal, agent, and
  in-turn counts. The spec identifier is `cmux.dialog.quit`, and the dialog is shown through
  `CmuxDialogCenter` (a headless host, `CmuxDialogHeadlessHost`).
- `QuitBehaviorSetting` migration: `end-keep-layout` → `quitAll`, `end` → `quitAll`.
- `DaemonConnection.endSessionsAndStop(deletingWorkspaces:)` against a fake transport that answers
  `home_not_closable` for Home: `shutdown-daemon` is still sent (G2 red, then green).
- Launcher invariants: `AcpmuxDaemonLauncher.arguments` and spawn flags include SETSID; the
  `DaemonLauncher.ensureArguments` grace stays at the unplaced-only reaper (these exist in part in
  `LauncherTests.swift:49-60`).
- cmux-tui: `terminal_reap` never reaps a placed terminal while no client is attached (Testbox).

### 5.2 Fleet live test: `scripts/fleet-quit-persistence.sh` (owner: durable-sessions)

It runs on cmux-lawrence-2 against a tagged fleet build (`cmux-ci build cmux --ref <sha> --tag
<tag>`). It drives the app only through its own sockets and records every PID it starts. It never
uses pattern kills. Steps (each step is a command that exists today, from §2):

1. Install the artifact under `~/qp/<tag>`, `open -g -n` it, and wait for
   `/tmp/cmux-debug-<tag>.sock`. Record the PIDs of the app, cmux-tui (`--session
   cmux-app-<tag>`), and acpmux (`ACPMUX_HOME=~/.acpmux/tags/<tag>`).
2. With the bundled `cmux --socket <daemon sock>`, run `workspace create --name qp-a` and
   `workspace create --name qp-b`. In qp-a's terminal, write a marker, 200 lines, and a tick loop
   that writes its PID to a file.
3. `ACPMUX_HOME=… acpmux new -d -m claude --policy approve-all --stall 0 "<600 s tool loop>"`.
   Wait for `tool_progress`. Open an agent tab: `action.run palette.newAgentChat` plus
   `debug.agent_pane select_session`.
4. Save the before-state: `workspace list --json`, `terminal list --json`, `history read`, `acpmux
   ls --json`, `debug.windows`, and `debug.window_snapshot`.
5. `debug.quit {open:true}`, then assert the dialog report: `default == keep`, the counts (2
   terminals, 1 agent, 1 in turn), `scope == window`, and the snapshot shows the dialog. Then
   `{press:"keep"}`. Assert that the app PID exits within 10 s.
6. Wait for the reap grace + 10 s, then assert that the cmux-tui, acpmux, shell, loop, and harness
   PIDs are alive.
7. Relaunch and assert:
   - the same terminal ids, workspace ids, and window id;
   - the history contains the marker, and the tick numbers have no gap;
   - the same acpmux session id with its turn still `running`, then `completed` (`acpmux wait`);
   - the agent tab is back with the same session (`debug.agent_pane chat_state`, G4).
8. The "quit everything" leg: `debug.quit {open:true}`, `press quit-everything`, `press
   confirm-quit-everything`. Assert that the app, cmux-tui, terminal hosts, shell, loop, acpmux,
   and harness PIDs are all gone within 70 s. On the next launch, the turn shows as cancelled, the
   workspaces stay (keep layout), and the terminals start fresh shells.
9. Variants: the window not key (another app frontmost); the app inactive with a quit from the
   Dock (`debug.quit {open:true, inactive:true}`); a second Cmd-Q while the dialog shows (`debug.quit
   {open:true}` twice) → keep; an update relaunch (`debug.updater relaunch` if one exists, else a
   handoff test) → no dialog, kept.
10. Cleanup: quit through `app quit --end-sessions`, then `acpmux daemon shutdown` in the tag home.

Today's code passes steps 1-4, 6, and 7 except the agent tab (§2, run 1). Step 5 passes for keep
with the NSAlert, but the snapshot misses the dialog and the agent count is absent. Step 8 fails
(G2 for End Everything, and G3 for agents). Steps 9 and the dialog assertions need the dialogs
work.

## 6. Owners and order

| # | Work | Owner | Gate |
| --- | --- | --- | --- |
| Q1 | G2 fix: End Everything skips or clears Home, collects errors, never fails silently; red test then fix | durable-sessions | unit test + live step 8 for terminals |
| Q2 | Land the dialogs branch Quit conversion on origin (CmuxDialog, `.window`/`.app`, `debug.dialog`) | dialogs lead | `debug.window_snapshot` shows the dialog |
| Q3 | Dialog content: Keep Sessions Running default, Quit Everything…, agent counts, second Cmd-Q, Dock activation | dialogs lead (content), app lifecycle (`QuitCoordinator`, facts) | QuitPolicy and content tests; live steps 5 and 9 |
| Q4 | Setting `ask|keep|quitAll`, migration, Settings + palette + schema + MDM docs | app lifecycle | migration tests |
| Q5 | Quit everything ends agents (`endAgents` = A4 without waiting for A1-A3) | durable-sessions | live step 8 for agents |
| Q6 | Agent tabs persist and reattach (G4) | durable-sessions with the tabs owner | live step 7 for the agent tab |
| Q7 | `scripts/fleet-quit-persistence.sh` as a fleet job, run per release | durable-sessions | green on cmux-lawrence-2 |
| Q8 | Fix the stale Sparkle row in `durable-sessions.md:23` | durable-sessions | doc |

## 7. Decisions (coordinator, 2026-10-04)

- D1 (decided: yes): Quit Everything keeps the workspace layout. Terminals and agents end, and the
  tabs come back with fresh shells (today's End Sessions, Keep Layout, plus `endAgents`). End
  Everything (delete the workspaces, Home stays) is a secondary button on the confirmation step
  only.
- D2 (decided: yes): a second Cmd-Q while the dialog shows chooses Keep Sessions Running. On the
  confirmation step it does nothing.
- D3 (decided: yes): logout, shutdown, an update relaunch and a signal never prompt and always
  keep. `quitAll` does not apply to them.

## 8. Landed in this lane

- G2 fixed, with a red test commit first: `SessionEnding` (`CmuxNextDaemon/Connection/SessionEnding.swift`)
  skips the home workspace (`WorkspaceSnapshot.isHome`), never stops at the first error, and
  returns every failed step in `EndedSessions.failures`.
  - `DaemonService.endSessionsAndStop` returns the failures and keeps the connection for Retry.
  - `QuitCompletion` shows them in `QuitFailureAlert` ("Some sessions did not end"), with Retry
    and Quit Anyway, until the CmuxDialog conversion replaces both alerts. The quit never goes on
    silently.
  - `debug.quit` reports `failure` and answers `retry` and `quit-anyway`.
- `scripts/fleet-quit-persistence.sh` is the 5.2 acceptance test. Its expected-fail list (with
  owners) is at the top of the script. The `end-everything-*` checks must pass.

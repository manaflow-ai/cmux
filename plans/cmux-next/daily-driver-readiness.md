# cmux-next daily-driver readiness

## Current audit: 2026-10-12 (cx-urd.5)

Re-scores the rows the 2026-10-04 audit left UNVERIFIED, on official
nightly-next `1.0.0-nightly.3829509799401` (run 38295097994, `de3b3eceb3cf`).
It ran on a leased cua capture slot. Hostnames in the screenshots are redacted.
Each failing row has a bead.

| Row | Score | Evidence |
| --- | --- | --- |
| Claude Code TUI task and resume | WORKS | A real task wrote `hello.txt`. `/exit`, then `claude -c`, answered from the same session. [Screenshot](evidence/urd5-claude-resume.png) |
| Codex TUI task and resume | WORKS | A real task wrote `codex.txt`. Resumed with `codex resume --last`, it answered "codex.txt" to a follow-up. Codex redraws the resumed transcript, so the screenshot alone does not show the restart. [Screenshot](evidence/urd5-codex-resume.png) |
| Several browser tabs | PARTIAL | Three browser tabs opened in one workspace with titles and URL bar. [Screenshot](evidence/urd5-sidebar-browser.png) |
| Browser back/forward/reload | UNVERIFIED | Pages never painted (load stayed at starting), and `browser back/forward/reload` timed out. This may be slot-only (sandboxed WebKit networking): cx-urd.64. |
| Rename | BROKEN, fix in [#20000](https://github.com/manaflow-ai/cmux/pull/20000) | `cmux workspace <id> rename` committed, but the sidebar did not follow. [Idle strip](evidence/urd5-rename-idle-30s.png): "Daily driver" renamed to "Daily"; frames at 2, 5, 10, 20 and 30 s still show "Daily driver". [Busy strip](evidence/urd5-rename-after-agent-event.png): before, then 1, 3, 6 and 12 s after renaming "status" to "Status check". The new name only appears once an unrelated agent-hook update ("Claude is waiting") forces a resync. The resource `workspace.rename` and `workspace.move` paths sent no tree delta: cx-urd.63. |
| Groups | WORKS | `workspace group create/add` made a collapsible Projects group holding Research. [Screenshot](evidence/urd5-sidebar-browser.png) |
| Idle/Running (agents) | WORKS | With `cmux agent hook install claude codex`, the "status" row showed the running spinner during a Claude turn ([screenshot](evidence/urd5-agent-working.png)) and "Claude finished" after it (first frame of the [busy strip](evidence/urd5-rename-after-agent-event.png)). |
| Idle/Running (plain commands) | MISSING | Status reads only agent hooks, OSC 7501 and chat turns. `sleep 30` shows no status: cx-urd.65. |
| Notifications | WORKS (sidebar) | `cmux notify` put the unread badge (1) and body ("all green") on the Research row. [Screenshot](evidence/urd5-sidebar-browser.png). macOS banners are not observable on capture slots, so they are UNVERIFIED there. `notify --reply` was verified live under cx-wnivp. |
| SSH | WORKS | `remote.connect` and `remote.newWorkspace` against a private sshd on the slot opened a remote terminal (`SSH_CONNECTION ... 22101`). [Screenshot](evidence/urd5-ssh.png) |
| Cloud | UNVERIFIED | Capture slots have no test Cloud account, and personal credentials never go on a slot: cx-urd.66. |
| Update install | WORKS | `scripts/cmux-next/update-e2e.py` from 3829509799401 to 3830170534701: 20 PASS, 1 PENDING (rollback is not built). It used a local copy of the feed, because the live appcast holds only one item and no deltas: cx-urd.67. The Claude screenshot footer shows "Update installed · Restart to update". |
| Import classic | WORKS | After `cmux workspace import-classic`, the sidebar gained the "Terminal" row (below workspace-1). [Screenshot](evidence/urd5-ssh.png) |

Top fix: cx-urd.63 (rename/move delta), red-then-green in #20000.

Localization audit: this update is contributor evidence only. It changes no
product strings or catalogs.

## Audit: 2026-10-04

**Not ready to replace classic yet.** The current target is Leo's terminal-first
layout: named workspace/session rows, live Idle/Running status, collapsible
folder groups, Claude Code and Codex TUIs, a split browser, and the sidebar
update/help footer. ACP is optional for this verdict.

The ranked findings and exact repro steps are in
[HQ #1288](https://github.com/manaflow-ai/cmuxterm-hq/issues/1288).
[Real side-by-side captures](https://github.com/manaflow-ai/cmux-app-screenshots/tree/487fcf6/captures/cmux-next/classic-parity-20261004)
show shell output and a loaded browser beside the terminal in both products.
The screenshots preserve the original UI pixels; host profiles and window
sizes differ, so they do not establish controlled theme parity.

Tested next: official nightly-next `57346c6c3c984177cebfdca28e44ce28cbb2dfb0`,
version `1.0.0-nightly.3720357958801`, downloaded directly on a picker host.
An isolated build of the same source, local backend, passed fleet job
`22100843937c7b7e715aa94d`. Classic comparison: `8305cff51f0afae7f083fa848f69bd7d4f351b55`,
local-backend fleet job `02c0000105a0842399f6d2e1`. No app artifacts were relayed
through the submitter.

| Current runtime item | Score | What the evidence establishes |
| --- | --- | --- |
| Shell input | WORKS | Foreground Ctrl-U and Return executed a command with visible output and prompt. No measured typing-latency claim. |
| Scrollback | WORKS | Printed 120 numbered lines; targeted wheel scrolling exposed earlier output. |
| Terminal/browser split | WORKS | Split Browser Right created the layout; entering a URL loaded a real page beside the terminal. |
| Browser tabs/navigation | PARTIAL | Tab labels and URL bar are visible. Back/forward/reload cycle and several browser tabs remain unverified. |
| Basic keep-session reopen | WORKS | Quit and Keep Sessions then relaunch preserved one workspace, terminal buffer, tab names, and browser split. Agent resume and crash restore remain unverified. |
| Workspace context menu | WORKS | Persistent foreground CUA exposed the real menu. Transient foreground restoration had hidden it. |
| Rename, groups, Idle/Running accuracy | UNVERIFIED | F2 is absent on this nightly and already owned by #17188. File/context rename routes exist. Real named/grouped session proof and live status still need capture. |
| Claude Code and Codex TUIs | UNVERIFIED | Real pooled-provider tools/auth are not consistently provisioned on picker hosts. No real task or resume is scored. |
| Footer | ROUGH | Classic's Help footer is visible; next shows Settings and Account without a visible Help entry. Update installation was not exercised. |
| Settings | PARTIAL | Settings exists as a tab; the old missing-Settings verdict below is obsolete. Full Settings-window behavior is unverified. |
| Config isolation | HAVE (source) | This nightly defaults to cmux-next.json, with one-time classic seeding. The old shared-config blocker below is obsolete for this nightly. |
| Classic NIGHTLY coexistence | BROKEN | Both share com.cmuxterm.app.nightly and /tmp/cmux-nightly.sock. Classic owned the socket during capture. App exit cause is unproven. |
| Long-run stability/resources | ROUGH | Two 24 h soaks and one 20-minute soak on a reserved CI mini, with 0 crashes. The 24 h reports are FAIL on false hangs (cx-urd.70). WebKit growth is unexplained (cx-urd.72), and idle CPU is over budget (cx-urd.71). See [Soak receipts](#soak-receipts-cx-urd4). |

The overnight BusyWatchdog crash was fixed and merged in
[#17290](https://github.com/manaflow-ai/cmux/pull/17290), after an executed red
50,000-read regression and a green 112-test control suite, exact-head local
fleet compile, and launch smoke. The audited published nightly predates that
repair. A new nightly and longer soak are still required.

Release identity belongs to Lawrence's release decision. Missing F2 is already
in open #17188; live status is already in #16819/#16431. Groups source is merged
in #17186; it is not a source-missing finding. Avoid duplicate fixes in those
lanes. The optional ACP appendix remains unverified and follows
`agent-pane-gaps.md` and `acp-ui-integration.md` ownership.

For new capture chunks, use `capture-host acquire`, use its printed alias, run
CUA directly under the lease, quit only the owned app, confirm the PID is gone,
and release. Never nest `with-host-lock` under a lease. Prepare the actions
before acquiring and record a four-minute cleanup deadline to leave time for
quit/release. Pull artifacts on the mini with `cmux-ci artifact`, or directly
from fleet CAS there; never copy app bundles between hosts. Repair guidance is
in HQ REPAIR.md, updated by merged #1273/#1284.

Localization audit: this update changes contributor evidence only, with no
product strings or localization catalog changes. `localize-changes --base HEAD`
prepared zero new/changed keys, then the strict catalog validator failed on
22,088 pre-existing catalog parity errors (including Accounts needs-review
entries). No catalog was modified; that inherited repair is outside this report.

## Historical 2026-10-03 report (superseded where noted above)

Checked source: `origin/feat-cmux-next` at `91d0fd4c1d76073cfa6327b3a00cc0f101d14c49`.
The exact SHA produced fleet job `816bd0a3235568c95ae0caec` (`dd-91d0fd4c`) in
142.60 seconds. This was the brief's explicit `--backend-mode local` build, so
it proves packaging and compilation only. It does not prove Cloud, sign-in,
remote, or shared-backend behavior.

## Verdict

**Not ready to replace classic cmux today.** Tagged builds have separate bundle,
control-socket, and cmux-tui state identities. The config isolation fix is open
in [PR #17198](https://github.com/manaflow-ai/cmux/pull/17198); the untagged
release identity and socket still collide with classic, and the Settings window
is not implemented. Three bounded runtime slices ran on the exact tagged
artifact. Long soak and resource tests remain deferred to `cx-aws-fleet`.

## Checklist

Scores mean `works`, `rough`, `broken`, or `missing`. `UNVERIFIED` means the
capture could not establish a runtime result. The requested screenshot for each
row is recorded as a missing evidence item rather than inferred from source.

| Area | Score | Evidence and screenshot |
| --- | --- | --- |
| Terminal input | ROUGH | Tagged `terminal.write` produced a 25-line command result and prompt in `terminal screen read`; a new foreground CUA click/key slice returned the foreground delivery route, but the terminal text remained visually unverified. [Screenshots](evidence/terminal-after-cli-input.png) and [foreground](evidence/runtime-cua-main-after-foreground.png) |
| Scrollback, copy/paste | ROUGH | Scrollback output and clipboard types/text were read back; terminal paste was not visually confirmable under the modal. [Screenshot](evidence/terminal-after-cli-input.png) |
| Fonts and themes | UNVERIFIED | No capture. |
| Splits and tabs | WORKS | `pane split --right` and terminal-tab creation returned IDs; two panes and six tabs were listed. [Screenshot](evidence/layout-split-tabs.png) |
| Workspaces and sidebar | ROUGH | The Home workspace and sidebar were visible, and the workspace remained focused; no independent sidebar mutation was attempted. [Screenshot](evidence/layout-split-tabs.png) |
| SSH | UNVERIFIED | No live remote route in local-backend build; no screenshot. |
| Claude Code via ACP (start, stream, approve, diff, resume) | UNVERIFIED | Agent catalog and acpmux are bundled; no live ACP turn or screenshot. |
| Codex via ACP (start, stream, approve, diff, resume) | UNVERIFIED | Same limitation; no live ACP turn or screenshot. |
| Browser pane | BROKEN | A picker-host CUA slice launched the tagged artifact and `cmux browser open https://example.com` returned `unknown or incomplete browser action`; the follow-up browser list stayed empty. [Screenshot](evidence/runtime-cua-browser.png) |
| Notifications | WORKS | `cmux notify` created an unread notification and `notification list` returned it with title, subtitle, body, and session. The visual notification surface was not asserted. [Screenshot](evidence/runtime-cua-notification.png) |
| Session restore after relaunch | WORKS | After killing and relaunching the tagged app, the same workspace, two panes, and six tabs were listed before and after. [Screenshot](evidence/restore-after-relaunch.png) |
| Import classic sessions | ROUGH | Import exists but intentionally omits commands, scrollback, and remote panels; no screenshot. |
| Settings | MISSING | No Settings window; JSON/palette settings only; no screenshot. |
| Update path | BROKEN | Development/tagged bundles disable Sparkle install; team update is manual artifact download. No screenshot. |
| Keyboard shortcut parity | ROUGH | Action catalog has keyboard surfaces and defaults, but classic parity is not proven; no screenshot. |
| Idle CPU/memory | ROUGH | Soak quiet phase: app 80-140 MB (budget < 150 MB). Idle app CPU was 0.01% on build 97f72304 and 0.26% at 7.3 wakeups/s on 57c2d569951a; both are above the 0.0% budget (cx-urd.71). `bench-idle.sh` itself was not run. |
| CPU/memory with 10 sessions | WORKS | 10 agents, 10 printing terminals and 4 browser tabs: app mean CPU 0.3-0.7%, daemon 1.7-2.1%; the daemon levels off at 0.64-1.03 GB within 2 h (architecture.md has no daemon budget). |
| Crash-free 20-minute scripted session | WORKS | `readiness-soak.py` for 25 min on 57c2d569951a: PASS, 0 crashes, 0 hangs, 99/99 agent turns. |
| Classic coexistence | ROUGH | Tagged app launched beside the existing classic app with its isolated bundle/socket/tui state. The pre-fix artifact still used classic `cmux.json`; PR #17198 separates it. Untagged release still collides. [Screenshot](evidence/layout-split-tabs.png) |

## Runtime receipts

The earlier bounded slices used `/Users/Shared/cmux-build-fleet/bin/with-host-lock`; the new picker-assigned slice held the picker lease, which owns that same remote `host.lock` (nesting `with-host-lock` would deadlock), and also returned before five minutes. The exact tagged artifact was downloaded on
the mini from the controller and verified as
`2da47e7d35b332bd54fd7129e13358120aa467b0fd4873fee44bd5e5fd92d066` before
launch. The terminal screen receipt is kept with the capture evidence; the GUI
screenshots show the host's iCloud modal covering the terminal renderer, so the
visual CUA result is recorded as rough rather than works.

- Terminal slice: command output, prompt, scrollback, and clipboard readback.
- Layout slice: split-right, tab creation, workspace/pane/tab listings.
- Relaunch slice: workspace, panes, and tabs listed before and after relaunch.
- CUA system slice: foreground click/key delivery returned by `cua-driver`; browser open/list failed; notification create/list worked. The host wallpaper manifest selected `met-death-of-socrates-436105.jpg`.

Evidence files: `plans/cmux-next/evidence/terminal-after-cli-input.png`,
`plans/cmux-next/evidence/layout-split-tabs.png`, and
`plans/cmux-next/evidence/restore-after-relaunch.png`, `plans/cmux-next/evidence/runtime-cua-main-before.png`, `plans/cmux-next/evidence/runtime-cua-main-after-foreground.png`, `plans/cmux-next/evidence/runtime-cua-browser.png`, and `plans/cmux-next/evidence/runtime-cua-notification.png`.

## Ranked blockers

1. **Interactive evidence is chunked.** Each foreground CUA chunk will hold
   `with-host-lock` for at most five minutes, then release it so other lanes can
   interleave. The 20-minute soak and ten-session measurement belong on the
   dedicated capture host `cx-aws-fleet` is adding.
2. **No shared backend in this build.** The local backend cannot establish
   Cloud, sign-in, SSH relay, notifications, update, or agent service behavior.
3. **Untagged release collision.** The release identity is still
   `com.cmuxterm.app`, and the release control socket is the same stable cmux
   socket as classic. Only tagged reloads are safe for coexistence.
4. **Global settings collision.** The tested artifact shared
   `~/.config/cmux/cmux.json`; [PR #17198](https://github.com/manaflow-ai/cmux/pull/17198)
   moves next to `cmux-next.json` with one-time classic seeding. It needs to
   merge and reach the next build before this blocker is closed.
5. **Settings window missing.** User-facing settings are currently JSON/palette
   paths, so settings discovery and notification preferences are incomplete.
6. **Classic import is lossy.** It recreates workspace topology and titles but
   omits commands, scrollback, and remote panels.
7. **ACP end-to-end evidence is absent.** Bundling acpmux is a packaging fact,
   not proof of start, streaming, approvals, diffs, or resume for either ACP
   client.
8. **Browser auth and shared-host behavior are absent.** CEF presence in the
   artifact does not prove browser pane readiness against the real backend.
9. **Shortcut and CLI parity are incomplete.** The old Swift CLI compatibility
   layer is superseded; static next action-surface tests do not establish the
   classic runtime contract.
10. **Idle CPU is over budget.** The ten-session and crash-free receipts
    pass (see [Soak receipts](#soak-receipts-cx-urd4)), but idle app CPU on
    57c2d569951a, the first soaked build with Chromium tabs, is 0.26% against
    0.0% (cx-urd.71).

## Soak receipts (cx-urd.4)

`scripts/cmux-next/readiness-soak.py` ran on cmux8s, a reserved CI mini.
Capture-mini leases end after 10 minutes, so the soak cannot run there.
Each run had 10 fake-agent sessions, 10 printing terminals and 4 browser tabs.
The reports name only "build 108"; the commits come from the fleet build
(57c2d569951a) and the cmux-next-dev release notes (97f72304).

| Run | Build | Result | App CPU / memory | Daemon memory |
| --- | --- | --- | --- | --- |
| 20 min, 2026-10-14 | 57c2d569951a (feat-cmux-next, Chromium tabs) | PASS: 0 crashes, 0 hangs, 99/99 turns | 0.68% / 139 MB; idle 0.26%, 7.3 wakeups/s | 101 -> 270 MB through load, flat once quiet |
| 24 h, 2026-10-13 | 97f72304 (cmux-next-dev, WebKit tabs) | 0 crashes, 2813/2813 turns | 0.34% / 77-88 MB; idle 0.01% | levels off at 636 MB |
| 24 h, 2026-10-12 | cmux-next-dev of 2026-10-11 (WebKit tabs) | 0 crashes, 2815/2815 turns | 0.31% / 72-80 MB; idle 0.01% | levels off at 1035 MB |

Both 24 h runs were marked FAIL only for over 1,000 false hangs. In each, the
debug socket vanished at about 11:00Z while every turn kept completing
(cx-urd.70). The 10-13 run also saw WebKit grow from 5 to 17 processes at
22h41m, from 460 to 950 MB (167 MB at the start); the source is not yet known
(cx-urd.72).

## Coexistence facts

The tagged artifact's Info.plist is `com.cmuxterm.app.debug.dd.91d0fd4c`, with
`/tmp/cmux-debug-dd-91d0fd4c.sock`; its daemon session is
`cmux-app-dd-91d0fd4c` and its state directory is
`~/Library/Application Support/cmux/tags/dd-91d0fd4c/tui`. These are isolated
from classic. The artifact's own bundle environment also carries the local
backend on port 3777. The normal settings path remains the user's global
`~/.config/cmux/cmux.json`; the capture plan therefore uses a scratch config.

### Source-level audit performed without the capture mini

| Surface | cmux-next tagged debug | Classic / untagged comparison | Result |
| --- | --- | --- | --- |
| Bundle ID | `scripts/reload.sh` derives `com.cmuxterm.app.debug.<tag>`; the built artifact is `com.cmuxterm.app.debug.dd.91d0fd4c`. | Xcode defaults remain `com.cmuxterm.app.debug` and `com.cmuxterm.app`. | Tagged debug is isolated; untagged release/debug identities collide. |
| Defaults domain | `UserDefaults.standard` therefore follows the tagged bundle domain for app defaults; updater policy also reads the release domain `com.cmuxterm.app`. | Classic uses `com.cmuxterm.app`; both products still use the global `~/.config/cmux/cmux.json` unless `CMUX_NEXT_CONFIG_FILE` is set. | App defaults are tagged, config file is shared. |
| Control socket | `ControlSocketPath` resolves the tag to `/tmp/cmux-debug-dd-91d0fd4c.sock`; the artifact `LSEnvironment` carries the same value. | Release resolves to `~/.local/state/cmux/cmux.sock`; untagged debug resolves to `/tmp/cmux-debug.sock`. | Tagged socket is isolated; untagged release socket collides. |
| Daemon session/state | `DaemonLauncher` uses `cmux-app-dd-91d0fd4c` and `~/Library/Application Support/cmux/tags/dd-91d0fd4c/tui`. | Untagged session is `cmux-app` with the cmux-tui default session root. | Tagged daemon state is isolated. |
| Classic import | `ClassicSessionImporter` reads `~/Library/Application Support/cmux/session-com.cmuxterm.app.json`. | The classic snapshot is read-only input; it is not overwritten by import. | Import is present but topology/title/cwd only; commands, scrollback, and remote panels are omitted. |
| Update identity | `UpdateBuildIdentity` classifies tagged development bundles as `.development` and disables Sparkle install. | Stable release uses the release track and stable defaults domain. | Tagged update is manual artifact distribution. |

This audit is source and artifact metadata evidence only. It does not claim that
two processes were simultaneously launched or that any runtime behavior passed.

Classic import reads the stable classic session snapshot read-only and omits
commands, scrollback, and remote panels. The untagged next release path still
uses the classic bundle ID and stable socket, so it must not be launched beside
classic.

Tagged development builds classify as development updater builds and disable
Sparkle installation. Updating the team artifact is therefore a manual
`cmux-ci artifact` download, not an in-app update.

## Team download path today

After `wait` succeeds, each team-tailnet Mac can download the verified artifact
without HQ publication:

```bash
JOB_ID=816bd0a3235568c95ae0caec
TAG=dd-91d0fd4c
ZIP="$HOME/Downloads/$TAG.zip"
DEST="$HOME/Applications/cmux-dogfood/$TAG"
~/.local/bin/cmux-ci artifact "$JOB_ID" "$ZIP"
mkdir -p "$DEST"
ditto -x -k "$ZIP" "$DEST"
```

Launch the exact `cmux DEV dd-91d0fd4c.app` from that private destination with
`CMUX_NEXT_CONFIG_FILE` pointing at a per-tag scratch JSON file. The client
verifies the SHA-256 and atomically publishes the ZIP after the download. It
requires the fleet client and team-tailnet access. `publish-hq` is not valid for
this local-backend artifact: HQ publication requires a shared HTTPS development
backend with matching origins and readiness. A separate exact-SHA remote-backend
build is needed before publishing an HQ link. No public CDN path is claimed.

## Bounded capture plan

Each row below is a separate invocation. It must acquire the host lock, drive
only the tagged app, save its screenshot/evidence, and release the lock before
the next row. No invocation may wait on the lock while holding it.

1. **Terminal chunk (<=5 min):** input, scrollback, copy/paste, fonts, themes.
2. **Layout chunk (<=5 min):** splits, tabs, workspaces, sidebar, shortcuts.
3. **Connectivity chunk (<=5 min):** SSH and session restore after relaunch.
4. **Agent chunk (<=5 min):** Claude and Codex ACP start/stream/approve/diff/resume.
5. **Browser/system chunk (<=5 min):** browser pane, notifications, settings, import.
6. **Update chunk (<=5 min):** update check/path and team artifact handoff.

The crash-free 20-minute scripted session and ten-session CPU/memory run are
deliberately excluded from these shared-mini chunks. Run them later on the
dedicated `cx-aws-fleet` capture host, once it is available.

## Follow-up lanes

The first lane should run the six <=5-minute capture chunks with the tagged app,
preserving one screenshot per row. The dedicated `cx-aws-fleet` host should run
the idle/ten-session/20-minute receipts once it is available. A second lane
should produce a shared-backend build and repeat Cloud, SSH, ACP, browser,
notifications, update, and import checks. A product lane should decide whether
Settings and the lossy import are acceptable before any classic replacement
announcement.

No user-facing strings or source behavior were changed by this document, so no
localization catalog update was required.

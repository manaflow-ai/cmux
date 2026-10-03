# cmux-next daily-driver readiness

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
| Idle CPU/memory | UNVERIFIED | `scripts/cmux-next/bench-idle.sh` was not run because the tagged app could not acquire the host lock. |
| CPU/memory with 10 sessions | UNVERIFIED | No capture. |
| Crash-free 20-minute scripted session | UNVERIFIED | No capture. |
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
10. **Resource and stability budgets are unmeasured.** Idle, ten-session, and
    crash-free twenty-minute receipts remain required before a replacement
    recommendation.

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

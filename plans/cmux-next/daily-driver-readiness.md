# cmux-next daily-driver readiness

Checked source: `origin/feat-cmux-next` at `91d0fd4c1d76073cfa6327b3a00cc0f101d14c49`.
The exact SHA produced fleet job `816bd0a3235568c95ae0caec` (`dd-91d0fd4c`) in
142.60 seconds. This was the brief's explicit `--backend-mode local` build, so
it proves packaging and compilation only. It does not prove Cloud, sign-in,
remote, or shared-backend behavior.

## Verdict

**Not ready to replace classic cmux today.** Tagged builds have separate bundle,
control-socket, and cmux-tui state identities, but the default settings file
is shared, the untagged release identity and socket collide with classic, the
Settings window is not implemented, and the required interactive capture could
not start because the capture mini was occupied by another active dogfood lease.

## Checklist

Scores mean `works`, `rough`, `broken`, or `missing`. `UNVERIFIED` means the
capture could not establish a runtime result. The requested screenshot for each
row is recorded as a missing evidence item rather than inferred from source.

| Area | Score | Evidence and screenshot |
| --- | --- | --- |
| Terminal input | UNVERIFIED | No capture: mini host lock held by `pr-17180-activity-dogfood-v1`. |
| Scrollback, copy/paste | UNVERIFIED | No capture. |
| Fonts and themes | UNVERIFIED | No capture. |
| Splits and tabs | UNVERIFIED | Source catalog exposes split-right/down and tab actions; no screenshot. |
| Workspaces and sidebar | UNVERIFIED | Source catalog exposes workspace actions; no screenshot. |
| SSH | UNVERIFIED | No live remote route in local-backend build; no screenshot. |
| Claude Code via ACP (start, stream, approve, diff, resume) | UNVERIFIED | Agent catalog and acpmux are bundled; no live ACP turn or screenshot. |
| Codex via ACP (start, stream, approve, diff, resume) | UNVERIFIED | Same limitation; no live ACP turn or screenshot. |
| Browser pane | UNVERIFIED | Fleet artifact contains CEF and browser actions; local backend does not prove browser auth; no screenshot. |
| Notifications | MISSING | `plans/cmux-next/notifications.md` states there is no Settings window yet; no runtime screenshot. |
| Session restore after relaunch | UNVERIFIED | Tagged daemon state path is source-confirmed; no relaunch capture. |
| Import classic sessions | ROUGH | Import exists but intentionally omits commands, scrollback, and remote panels; no screenshot. |
| Settings | MISSING | No Settings window; JSON/palette settings only; no screenshot. |
| Update path | BROKEN | Development/tagged bundles disable Sparkle install; team update is manual artifact download. No screenshot. |
| Keyboard shortcut parity | ROUGH | Action catalog has keyboard surfaces and defaults, but classic parity is not proven; no screenshot. |
| Idle CPU/memory | UNVERIFIED | `scripts/cmux-next/bench-idle.sh` was not run because the tagged app could not acquire the host lock. |
| CPU/memory with 10 sessions | UNVERIFIED | No capture. |
| Crash-free 20-minute scripted session | UNVERIFIED | No capture. |
| Classic coexistence | ROUGH | Tagged bundle/socket/tui state are isolated; `~/.config/cmux/cmux.json` remains shared. Untagged release collides. |

## Ranked blockers

1. **Capture capacity is unavailable.** The required foreground CUA run,
   screenshots, 20-minute session, and ten-session measurement have no evidence
   until the active capture lease releases.
2. **No shared backend in this build.** The local backend cannot establish
   Cloud, sign-in, SSH relay, notifications, update, or agent service behavior.
3. **Untagged release collision.** The release identity is still
   `com.cmuxterm.app`, and the release control socket is the same stable cmux
   socket as classic. Only tagged reloads are safe for coexistence.
4. **Global settings collision.** Tagged and classic builds both read and watch
   `~/.config/cmux/cmux.json` unless `CMUX_NEXT_CONFIG_FILE` is explicitly set.
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

## Follow-up lanes

The first lane should reserve the capture mini and run the checklist with the
tagged app, preserving one screenshot per row and the idle/ten-session/20-minute
receipts. A second lane should produce a shared-backend build and repeat Cloud,
SSH, ACP, browser, notifications, update, and import checks. A product lane
should decide whether Settings and the lossy import are acceptable before any
classic replacement announcement.

No user-facing strings or source behavior were changed by this document, so no
localization catalog update was required.

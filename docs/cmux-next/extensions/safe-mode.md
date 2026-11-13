# Safe mode and rollback

Safe mode is one switch that turns every extension off, so an extension can never break cmux for
good. Rollback puts one local extension back to its last version that worked.

Code: `cmux-tui/crates/cmux-tui-core/src/apps/safe_mode.rs`, `apps/rollback.rs`,
`src/safe_mode_flag.rs`; CLI `cmux-tui/crates/cmux-tui/src/cli/safe_mode.rs`.

## What it turns off

Safe mode holds off every app that runs a script in the app host (`runtime.main`):

- every third-party app;
- every local app (`<state>/apps/local/*`) and the customize app (`local/customize`);
- every bundled first-party app with a script: agents, caffeinate, codemirror, coderouter, diffs,
  finder, inbox, integrations, memory, notes, search, skills, usage. cmux works without each of
  them: every place they draw in falls back to its native view (R5).

While it is on, the daemon starts no app host at all: no VM, no stream, no mount. `apps-mount` of a
held-off app answers `apps.safe_mode`, `apps-run` answers the same, a host that would restart
does not, and the local folder watch reloads nothing (saves made meanwhile apply when safe mode
ends). The supervisor counts every host process it spawns (`Supervisor::host_spawns`, live hosts
and load trials); a run that stays in safe mode keeps it at zero.

It leaves on what is cmux itself, not extension code:

- apps with no script, drawn by the app: the App Store (how you remove what broke), Home, and the
  Cloud and Remote Desktop panes;
- first-party native servers (Cloud, Remote Desktop), which ship and are signed with cmux. Only a
  first-party app can have one (`servers.rs`), so no third-party code runs this way.

Themes: there is no theme pack contribution yet. When one lands, its kill switch is
`safe_mode::holds_off` (hold off an app that contributes a theme even with no script) plus the
theme resolver reading `apps-list`'s `safe_mode.on` and drawing the built-in theme.

## Three ways in

1. **You**: `cmux safe-mode on`, or `apps-safe-mode {op: "safe_mode.set", args: {on: true}}` from
   any client. Entering is always allowed, from any origin. Running hosts stop at once; their
   views show the native fallback.
2. **The environment**: `CMUX_SAFE_MODE=1` when the daemon starts. It holds for that run only and
   is never written to the flag file.
3. **A crash loop**: when 3 app launches in 5 minutes began and never settled, the next launch
   comes up in safe mode with reason `crash-loop`, naming the extensions that were mounted in
   those launches.

The flag lives in `<state root>/safe-mode.json` (the folder that holds the session folders:
`CMUX_TUI_STATE_DIR`, else `~/Library/Application Support/cmux-tui/sessions` on macOS). The daemon
reads it once when its app supervisor starts. `cmux safe-mode on` writes it directly when no
daemon answers, so the next start comes up in safe mode even when the app's window is wedged
(`--state-dir DIR` names another root). A missing or unreadable file is off.

### The crash loop rule

The app reports two things to the daemon (`apps-safe-mode`, verified app connection only, so an
agent can neither fake a loop nor settle one away):

- `safe_mode.launch_began`, when it starts;
- `safe_mode.launch_settled {reason: "frame"}` once it drew its first frame and stayed up for 10
  seconds, or `{reason: "quit"}` on a clean quit.

A launch that is still open when the next one begins never settled: it failed. When a launch
begins and 3 failures began within the 5 minutes before it, safe mode turns on before anything
mounts. A settled launch (a first frame or a clean quit) clears the count, and tripping uses the
failures up, so a new loop needs 3 new failures. The record is `<session>/apps-launches.json`: it
survives a daemon restart and keeps at most 8 failures. A failure stamped after now (the clock went
back) or older than the window is dropped, so a skewed clock can only miss a loop, never invent one.

## The way out

`safe_mode.set {on: false}` with origin user: only you, through cmux itself, can leave (an agent or
an extension cannot). Leaving clears the launch count, applies the saves held meanwhile, and tells
every client (`apps-changed` with `transaction: "safe-mode"`) to mount again.

With cmux quit, `cmux safe-mode off` removes the flag file so the next start is normal. While cmux
runs, `cmux safe-mode off` is refused with that explanation.

## What a person sees

- Every place that showed an extension shows cmux's own view.
- `apps-list` carries `safe_mode: {on, reason, sinceMs, extensions}`, and each held-off app's row
  (and its App Store `state`) carries `run_state: "off: safe mode"`. An app whose host failed (a
  script that does not load, repeated crashes) carries `run_state: "failed: <why>"`.
- `cmux safe-mode status` says whether it is on, why, and which extensions were running when cmux
  crashed.

## Rollback

When a local app's host reports a mount that drew without an error, the daemon keeps the files that
host loaded as the app's last good version: `<session>/apps-last-good/<app>/files` (`<app>` with
every byte outside `[A-Za-z0-9._-]` written `%XX`, so `local/spy` is `local%2Fspy` and no two ids
share a folder), with `meta.json` (version, fingerprint). One copy per app: a newer good version
replaces it, and a copy is at most 16 MiB and the local reload's 2,000 files (dot files and
`node_modules` are not copied). The copy is made on its own thread, off the supervisor lock, and
only when the folder still holds what the host loaded: the print recorded at spawn is the one the
local watch last read, and the folder must match it before and after the copy. Keeping a copy and
rolling back are serialized per app, so a rollback never meets a half-written copy.

`apps.rollback {app}` (`apps-store`) puts those files back into the app's folder. Only origin user
can roll back, like leaving safe mode: an agent's call, through MCP or the CLI, gets `apps.origin`
(`cmux apps rollback <app>` asks cmux and prints that answer). The files it replaces go to
`apps-last-good/<app>/replaced`, and the ones the previous rollback replaced move to
`replaced.previous` (rotated, so a second rollback never destroys the only copy of the first's;
older ones are dropped). A rollback refuses, before it changes anything, when a path it would write
goes through a symbolic link in the app's folder (the link itself or a linked directory on the way),
since the write would land outside the folder; the error names the link. The app then reloads like a
save (in safe mode, when safe mode ends). Every row carries `can_rollback`: true when a last good
copy exists and the folder holds something else now, which is the case for a failed or paused
extension whose last change broke it. The copies are on disk, so rollback works after a daemon
restart.

Shipped apps (first-party, samples, `CMUX_APPS_DIRS`) are read in place from their folders and
change only with cmux or that folder, so no earlier version of theirs is on disk to keep:
`apps.rollback` answers `apps.rollback.unsupported` for them.

## Cost

With safe mode off: one flag file read when the supervisor starts, and one `Option` check where a
host would spawn, a view would mount or a run would start. Nothing per frame. A local app's
host spawn reads the print the local watch already has (no disk work under the lock), and its
files are copied once per new good version, on a thread of its own.

## Follow-ups (Swift shell, not in this change)

- The two launch calls, from the existing launch code, no new logic: in
  `CmuxNextApp/AppDelegate.swift` `applicationDidFinishLaunching`, send
  `{"cmd":"apps-safe-mode","op":"safe_mode.launch_began"}` on the app's verified daemon
  connection; in `CmuxNextApp/LaunchSettle.swift`, from `launchSettle.whenSettled` plus 10
  seconds, send `safe_mode.launch_settled {reason: "frame"}`, and from `AppDelegate`
  `applicationWillTerminate` send it with `reason: "quit"`. (`Crash/AppRunMarker` already tells a
  crash from a quit for its own page recovery; the daemon's rule is the one for extensions.)
- Action catalog entries "Restart in Safe Mode" and "Leave Safe Mode" (palette, a menu item, CLI
  `cmux action run`): a descriptor in `CmuxNextActions/Catalog/AppStoreActionCatalog.swift` and
  `cmux-action-catalog/src/catalog/app_store.rs`, a handler in `Handlers/AppStoreHandlers.swift`
  that sends `safe_mode.set` with origin user, and the exports regenerated by
  `ActionSurfaceParityTests` on a Mac. Until it lands, leaving safe mode while cmux runs needs
  the app's own call.
- Hold a key at launch (Shift) to start in safe mode: `AppDelegate` sends `safe_mode.set {on:
  true}` before the first window.
- Views that failed with `off: safe mode` mount again on `apps-changed` with `transaction:
  "safe-mode"` (today the client re-lists on it, and a failed view mounts again when reopened).
- The notice that names the paused extension: read `apps-list` `safe_mode.extensions` and offer
  Roll Back (when `can_rollback`), Remove, and Leave Safe Mode.

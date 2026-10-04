# Proposal: `workspace.create` takes the first terminal's launch (atomic create)

Status: spec proposal (durable-sessions lead, 2026-10-04). Spec text only; no code until the
protocol lead (ad349) reviews it through the coordinator and a cmux-tui window is granted.
Revision 2 (2026-10-04): ad349 verdict REVISE, required points R1-R5 and two result fields added
below (marked R1-R5). Coordinator decisions: R1 uses the new-tab creation rule; R5 lets a page
create a default workspace with a fresh user gesture.
Revision 3 (2026-10-04): ad349 APPROVED revision 2 (762a1a96b12). Added: the `kind` field of
`origin.confirmation.issue` (G1), one gesture per create in the host (G2), and mode repair of
existing state files (F1). Coordinator decisions (c), (d), (e) of revision 2 stay as written.

## Why

The Mac app creates a workspace with two requests (`create-workspace`, then `create-terminal`),
because the single `workspace.create` cannot carry the app's launch inputs. A failed second
request left a half-created workspace (interim app fix: `WorkspaceCreation` closes it again).
With these fields the app sends one idempotent request, and the daemon commits the workspace and
its first terminal in one commit (the daemon side landed in 7de249cb3d5; R1 changes its failure
model, see Atomicity).

## Capability

`workspace-create-launch-v1`. A client sends the new fields only when the daemon serves it;
otherwise it keeps the two-request path with rollback.

## New optional fields of `workspace.create`

All fields below except `key` and `terminal_id` are accepted only with `initial_content:
terminal`; with `empty` they are `validation.invalid` (reason `field_requires_terminal`).
`terminal_id` with `empty` is also `field_requires_terminal`. Unknown fields stay refused
(`extra: false`).

| Field | Type | Validation | Semantics |
| --- | --- | --- | --- |
| `key` | string | canonical lowercase UUID, exactly 36 bytes, `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$` | The workspace key the caller reserved (window claim, room pin). An existing workspace with this key, live OR tombstoned, is `creation.conflict` (details `{"conflict":"workspace_key","key":…}`). Never a silent reuse. |
| `cwd` | string | absolute (`/` first), 1..4096 bytes UTF-8, no NUL; kept as given (not normalized) | The first terminal's directory. R1: checked in validation, before the commit (see Atomicity). |
| `argv` | array of strings | 1..256 items; each item 1..8192 bytes, no NUL; total ≤ 65536 bytes | The first terminal's command, resolved with the terminal's `PATH`. Absent: the user's login shell. R5: `argv` is public (see Secrets in argv). |
| `env` | object (string → string) | ≤ 256 entries; keys `^[A-Za-z_][A-Za-z0-9_]{0,127}$`; each value ≤ 32768 bytes, no NUL; total keys + values ≤ 262144 bytes; R4: no key from the daemon-owned set | Added to the first terminal's environment (over the daemon's inherited environment, under the daemon-owned keys). Values are NEVER logged, never echoed in errors, results, events or public projections; only key names may appear (for example in a validation error naming the bad key). Stored in the terminal's durable launch spec for restart (R3: plain text at rest, see Env secrecy at rest). |
| `terminal_id` | string | exactly 32 bytes lowercase hex | The first terminal's host id, reserved by the caller (the app puts it in `CMUX_SURFACE_ID` before the request). An existing terminal with this id, live or tombstoned, is `creation.conflict` (details `{"conflict":"terminal_id"}`). |
| `keep` | boolean | none | The first terminal outlives its last tab (`terminal-reap-v1`). Default false. |

## Validation order and atomicity (R1)

The daemon uses the new-tab creation rule (`new-tab-accept-first.md` 3.0, 3.1, 3.5): one creation
path and one failure model for every create that makes a terminal. `workspace.create` with
`initial_content: terminal` is a caller of the shared `TerminalCreationIntent` accept step.

1. Origin check (R5), then the idempotency lookup (R2). A replay ends here.
2. Validation of every field, with no state change: shapes and limits from the table, the
   daemon-owned env keys (R4), the `key` and `terminal_id` conflict checks, and `cwd`. The daemon
   does a `stat` of `cwd` here: a path that is not an existing directory is `validation.invalid`
   (reason `cwd_not_found`). Nothing is created and no reserved id is consumed.
3. One commit (one F_FULLFSYNC) writes the workspace row, its first screen, pane, tab, the terminal
   row with lifecycle `launching`, the launch spec, the creation intent in state `executing`, the
   workspace ledger and the projection rows. The reply follows this commit (stage A of new-tab).
4. The spawn runs after the commit, on the terminal work pool (new-tab 3.2).

A launch failure after the commit does NOT remove the workspace. The workspace stays, with its
tab and a terminal in `exited` and the cause (`launch-failed: <reason>`), in one commit, as in
new-tab 3.5. The `terminal-lifecycle` event carries the cause; the app shows the exited-terminal
view with `respawn`. Example: the `cwd` directory is deleted between the `stat` and the spawn.
Then the terminal ends `exited` with cause `launch-failed: cwd_not_found`. The `stat` only makes
the common failure a validation failure; it cannot remove the race.

A daemon crash after the commit is recovered as in new-tab 3.6 (relaunch in place or adopt;
never cancel). A crash before the commit loses the request with no state.

Removed claim: revision 1 said "a spawn failure leaves no workspace". That claim is wrong under
this rule and is withdrawn.

The app's rollback (B) in `WorkspaceCreation` (close the workspace after a failed
`create-terminal`) still applies to the two-request path on daemons that do not serve
`workspace-create-launch-v1`. With the capability the app does not roll back: an exited first
terminal is the documented result, and the app shows it.

## Idempotency and conflicts (R2, R3)

- `idempotency: required` stays.
- R2 order: the idempotency lookup runs BEFORE the `key` and `terminal_id` conflict checks. A
  replay with the same idempotency key and the same fingerprint returns the stored result (or the
  stored failure). A replay of a successful create therefore returns the first result, never
  `creation.conflict` for its own `key` or `terminal_id`.
- The same idempotency key with a different fingerprint is `idempotency.conflict` (unchanged).
- A new idempotency key that names an existing `key` or `terminal_id` is `creation.conflict`;
  nothing is created and no reserved id is consumed.
- R2 test: create with idempotency key K, `key` W and `terminal_id` T; then send the same request
  with K again. The second reply is the same result (same workspace, tab, terminal, `key` and
  `terminal_id`), with no `creation.conflict` and no second workspace.

R3, the env hash key:

- The fingerprint includes `env` through HMAC-SHA256 of its canonical JSON (sorted keys, no
  whitespace, UTF-8) under a per-daemon env hash key. The raw values are never in the fingerprint.
- The key is 32 random bytes, generated at first use, stored in the registry, and never sent out
  (not in any result, event, export, snapshot or log). The key is NOT derived from the machine id.
- Freestyle clones are byte-identical (memory snapshot), so cloned daemons share the key. That is
  acceptable: the key only binds a replay to its own request on one daemon; it gives no secrecy
  between clones, and no fingerprint leaves the daemon.
- Each stored fingerprint carries the key version. On rotation the daemon keeps the old key for as
  long as it keeps idempotency records made with it, and re-checks a replay with that old key. If
  the old key is gone, a replay of a record with the old version is the typed
  `idempotency.expired` (non-retryable with the same key; retry with a new idempotency key). It is
  never a false `idempotency.conflict` and never a second run.

## Env secrecy at rest (R3)

- `env` values are plain text in the durable launch spec (the daemon needs them to relaunch after
  a crash). The current per-terminal env path already keeps them with the creation receipt in the
  local state directory (`cmux-tui/crates/cmux-tui-core/src/mux.rs:1642-1646`).
- The registry file and every file that holds a launch spec are owner-only (mode 0600) in a 0700
  directory. A test asserts the mode on a fresh state directory.
- F1, an existing file with wider permissions (coordinator decision): at start the daemon TIGHTENS
  every registry and launch-spec file to 0600 and its directory to 0700. For each change it writes
  one warn line with the path and the old mode, never the contents. The daemon does NOT refuse to
  start: a refusal would lock the user out of their sessions for a mode problem that the daemon
  can repair itself. If the repair fails (for example the file has a different owner), the daemon
  logs the path, the mode and the error, and continues.
- Every export or snapshot path redacts env values and keeps only the key names: journal export,
  the launch snapshot, the diagnostics bundle, and every public read (`terminal.get`, resource
  lists, `CreatedTerminalPath`).

## Daemon-owned env keys (R4)

A caller `env` key in the daemon-owned set is `validation.invalid` (reason `env_key_reserved`,
details `{"key": <name>}`). The error names the key, never the value. The daemon's values always
win. The set, from the daemon source at 1e1d1bf68b9:

| Key | Set at (cmux-tui/crates/...) | Meaning |
| --- | --- | --- |
| `CMUX_TUI_SOCKET` | `cmux-tui/src/main.rs:2239` | daemon socket for the CLI and hooks |
| `CMUX_MUX_SOCKET` | `cmux-tui/src/main.rs:2240` | legacy alias of the socket |
| `CMUX_TUI_HOOK` | `cmux-tui/src/main.rs:2248` | agent hook helper path |
| `CMUX_TUI_TERMINAL_ID` | `cmux-tui-core/src/surface.rs:2177` | the terminal's public id |
| `CMUX_TUI_SESSION_ID` | `cmux-tui-core/src/surface.rs:2181-2185` | the session's public id |
| `CMUX_SIDEBAR` | `cmux-tui-core/src/mux.rs:8432` | sidebar plugin marker |
| `CMUX_TUI_AGENT_BROWSER_PROVIDER` | `cmux-tui/src/agent_browser_provider.rs:44` | agent-browser integration marker |
| `AGENT_BROWSER_PROVIDER` | `cmux-tui/src/agent_browser_provider.rs:45` | agent-browser provider name |
| `AGENT_BROWSER_PLUGINS` | `cmux-tui/src/agent_browser_provider.rs:46` | agent-browser plugin list |
| `AGENT_BROWSER_SESSION` | `cmux-tui-core/src/surface.rs:6077` | per-terminal agent-browser session |
| `CMUX_TUI_CLAUDE_WRAPPER_ACTIVE` | `cmux-tui/src/claude_wrapper.rs:33,67` | claude shim marker; a caller value disables hook injection |
| `GHOSTTY_ZSH_ZDOTDIR` | `cmux-tui-core/src/shell_integration.rs:128` | shell integration (zsh) |
| `GHOSTTY_BASH_ENV` | `cmux-tui-core/src/shell_integration.rs:143` | shell integration (bash) |
| `GHOSTTY_BASH_INJECT` | `cmux-tui-core/src/shell_integration.rs:146` | shell integration (bash) |
| `GHOSTTY_BASH_UNEXPORT_HISTFILE` | `cmux-tui-core/src/shell_integration.rs:153` | shell integration (bash) |
| `GHOSTTY_SHELL_INTEGRATION_XDG_DIR` | `cmux-tui-core/src/shell_integration.rs:160` | shell integration (fish) |

Keys that are NOT in the set, and why:

- `TERM`, `COLORTERM`: the daemon sets them first and lets a caller value win by design
  (`surface.rs:2304-2310`, `terminal_host_runtime.rs:5086-5089`).
- `ZDOTDIR`, `ENV`, `HISTFILE`, `XDG_DATA_DIRS`: shell integration reads the caller value and
  keeps it (`shell_integration.rs:81`, `127-161`), so a caller value is valid.
- `PATH`: the app sends the login-shell `PATH`. Rule: the daemon puts its `claude` shim
  directory (`cmux-tui/src/main.rs:2254`, `claude_wrapper.rs:80-87`) first in the final `PATH`,
  on top of the caller value. Finding: today the caller env is appended after the daemon env
  (`cmux-tui-core/src/mux/terminal_work.rs:305`), so a caller `PATH` replaces the shim `PATH`,
  and a caller `CMUX_TUI_SOCKET` or `CMUX_TUI_HOOK` replaces the daemon value. Only
  `CMUX_TUI_TERMINAL_ID` and `CMUX_TUI_SESSION_ID` are overwritten after the merge today
  (`surface.rs:2177-2185`). The daemon change must apply the daemon-owned set after the caller
  env.
- `CMUX_TUI_SHELL_INTEGRATION`, `CMUX_TUI_CLAUDE_HOOKS_DISABLED`: user opt-out switches
  (`shell_integration.rs:54`, `claude_wrapper.rs:35`); a caller may set them.
- `CMUX_TUI_PROCESS_SCOPE`: the daemon sets it only on journal hook processes
  (`unix_process_scope.rs:36,360`), not on terminals, so the set does not include it.
- `CMUX_SURFACE_ID`: the daemon does not set it; the app sets it to the reserved terminal id. Rule:
  `env.CMUX_SURFACE_ID` is valid only with `terminal_id` and only when the two are equal;
  otherwise `validation.invalid` (reason `env_surface_id_mismatch`, details
  `{"key":"CMUX_SURFACE_ID"}`). `CMUX_WORKSPACE_ID`, `CMUX_TAB_ID`, `CMUX_PANEL_ID`,
  `CMUX_PANE_ID` are legacy app identity keys (`cmux-tui/src/local_owner.rs:397`); the daemon does
  not set them, and a caller may.

The set is one constant in the daemon, shared by `workspace.create` and `create-terminal`, and the
spec lists it. A new daemon-set key goes into the constant and this table in the same commit.

## Origin (R5)

The daemon derives the request origin (`plans/cmux-next/request-origin.md`, approved
2026-10-04, commit a65a6f95ada: `page` on a `page_relay` connection, `user` on a verified app
connection, `app` on an app-supervisor connection, `agent` otherwise).

| Origin | `workspace.create` with defaults | with `argv`, `env`, `cwd` or `keep` |
| --- | --- | --- |
| `page` | only with a fresh user gesture (below); else `origin.forbidden` | `origin.forbidden`, always |
| `app` | needs `workspace:write` (as today) | needs `workspace:execute`, the scope of `workspace.run` and `pane.run` (`scopes.json:884,1620`); else the grant refusal its other ops get |
| `agent`, `user` | allowed | allowed, as `create-terminal` today |

"Defaults" means `initial_content` and the existing name and placement fields only; `key` and
`terminal_id` are also allowed for a page (they carry no command and no secret).

The page user gesture: the mechanism that the Settings page and the file pages use, with no native
confirmation sheet. The host records the time of the last real key or mouse event in the page's
view (`PageWKWebView.hasRecentUserGesture(within: 1)`,
`Packages/macOS/CmuxNext/Sources/CmuxNextPages/PageWKWebView.swift:36-55`). `PageRouter` passes it
as `PageCallContext.userGesture` (`CmuxNextPages/PageRouter.swift:90,103`;
`CmuxNextPages/PageError.swift:22`); page script cannot set it. Settings uses it in
`SettingsPageProvider.writer` (`CmuxNextApp/Pages/SettingsPageProvider.swift:207-213`); the file
pages require it as "+ gesture" (`plans/cmux-next/finder.md`, refusal `gesture.required`).
To carry it to the daemon, `DaemonPageRelay` asks `origin.confirmation.issue` (request-origin.md)
for this exact operation and params hash, with `kind: "gesture"` (G1), only when `userGesture` is
true. The token is bound to the params hash and the relay connection, and the page never sees it.

G1, the `kind` field of `origin.confirmation.issue` (protocol change):

- `kind` is `"confirmation"` (the default, the existing meaning: a native sheet approved the call)
  or `"gesture"`. Any other value is `validation.invalid`.
- A gesture token NEVER changes the derived origin: the request stays `page`. Only a
  `confirmation` token makes a page_relay call `user`, as today.
- The daemon accepts a gesture token only for an allow-list of (operation, defaults-only params).
  Today the list has one entry: `workspace.create` with defaults (Origin table above). A gesture
  token on any other operation, or on `workspace.create` with `argv`, `env`, `cwd` or `keep`, is
  `origin.forbidden`.
- Issuing either kind needs a verified_app caller (request-origin.md). Before P8 no connection is
  verified_app, so before P8 no page can create a workspace.
- The field lands in the workspace-create window, on top of the origin landing (not in ad349's
  origin window), with its own red tests (Red tests 9-11).

G2, one gesture backs one create:

- Daemon: a gesture token is single-use. One token gives at most one create; a reuse is
  `origin.forbidden`.
- Host (Swift, `DaemonPageRelay` with `PageWKWebView`): the host mints at most one gesture token
  per recorded gesture. When it issues a token, it consumes the recorded gesture time
  (`lastUserEventUptime` is cleared), so a second request after the same click has no gesture.
  A new real key or mouse event records a new gesture.
- Swift test (React UIs lead): after one click, a page asks for two gesture tokens inside 1 s. The
  first request gets a token; the second request is refused (no token is issued, and the call goes
  to the daemon with no gesture, where it is `origin.forbidden`).

Secrets in argv: `argv` IS visible in public reads (`terminal.get`, resource lists, the journal),
like `ps` output on the machine. Callers must pass secrets through `env`, never `argv`.

## Result

`CreatedTerminalPath`, plus `key` when the request named one, plus `terminal_id` when the request
reserved one (the app checks it against `CMUX_SURFACE_ID`). The terminal lifecycle in the result
is `launching`.

## Logging rule (all daemon and app code on this path)

`env` values and `argv` items are not logged at any level. Logs name only the operation, the
key, the terminal id and the env key count.

## Red tests

1. R1: `cwd` that does not exist is `validation.invalid` (`cwd_not_found`) and creates nothing
   (no workspace row, no reserved id consumed).
2. R1: a launch failure after the commit (test hook fails the spawn) leaves the workspace with its
   tab and an `exited` terminal with cause `launch-failed: <reason>`.
3. R2: create, then replay with the same idempotency key: same result, no `creation.conflict`.
4. R3: a replay whose fingerprint has an old key version is re-checked with the retained old key;
   with the old key removed it is `idempotency.expired`, never `idempotency.conflict`, and nothing
   runs a second time.
5. R3: journal export, launch snapshot and diagnostics bundle contain no env value; the registry
   file is mode 0600.
6. R4: each key of the daemon-owned set in `env` is `validation.invalid` naming the key and not
   the value; a caller `PATH` keeps the shim directory first.
7. R5: a page request with `argv`, `env`, `cwd` or `keep` is `origin.forbidden`; a page default
   create without a gesture token is `origin.forbidden`; with one it succeeds once and a reuse of
   the token is refused; an app without `workspace:execute` cannot send `argv`.
8. The result echoes `key` and `terminal_id` when the request named them.
9. G1: a gesture token on any operation other than `workspace.create` with defaults is
   `origin.forbidden`.
10. G1: a gesture token never gives origin `user` (the derived origin of the call stays `page`).
11. G1: a `confirmation` token (explicit kind and the default with no `kind`) works as before.
12. F1: a registry file at mode 0644 is 0600 after the daemon starts, its directory is 0700, and
    exactly one warn line names the file path and the old mode (no contents).

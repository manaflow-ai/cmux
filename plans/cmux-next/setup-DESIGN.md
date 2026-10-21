# `cmux setup`: setup an agent can do

Lawrence: "the chief should be able to just set stuff up." Leo: "nobody reads
the docs except agents." So every setup task gets one entry point an agent
finds and runs, with machine-readable results, and the person is asked only
for what a person must do: an OAuth sign-in, a secret, a macOS switch.

## Inventory (2026-10-21, feat-cmux-next)

| Task | Done today | Agent path today | JSON | Safe to re-run |
| --- | --- | --- | --- | --- |
| cmux sign-in, accounts | GUI (Settings > Accounts, sidebar) | `cmux accounts list` reads; `cmux cloud sign-in` opens the browser; reauth/connect are person-only | yes (list) | list yes; sign-in refuses when signed in |
| Harness install and sign-in | GUI (Settings > Agents, Harnesses page) | `cmux setup harness [ID ...]`; `cmux harness list/doctor/login --json`; install and sign-in are the user's | yes | yes |
| Folder trust | GUI (TrustAsk line, sub-session card) | none: raw `acp.trust.set` over the acpmux socket | - | - |
| Add an ssh machine | GUI (Connect to Machine...) | `cmux acp host setup SSH --json`; `cmux remote connect` | yes (acp) | yes |
| acpmux peers, host updates | none in the app | `cmux acp host ls/update --json` | yes | yes |
| Cloud machine | GUI (New Cloud Machine sheet) | `cmux cloud new-machine` opens the sheet; `cmux-vm create` (operator) | sheet no; cmux-vm yes | cmux-vm yes (idempotency keys) |
| Tailscale, mesh | CLI only | `cmux host enable/status --json`; needs Tailscale signed in | yes | yes |
| MCP servers | docs only; chats cmux starts get them (acpmux `agent_tools`) | `cmux setup mcp [claude\|codex ...]`; `cmux agents doctor --json` checks cmux-cua | yes | yes |
| Computer Use | GUI (Computer Use Setup) | `cmux setup computer-use`; the person allows it on the app's sheet, and grants are switches in System Settings | yes | yes |
| Browser import | GUI (Import from Browser...) | `cmux bookmark import-from-browser`, `cmux browser import-cookies` (consent panel); history and passwords person-only | partly | bookmarks/history merge |
| Keyboard shortcuts | GUI (Keyboard Shortcuts) | `cmux keybinding list/resolve --json`; edits only over the raw socket or keybindings.json | reads yes | yes |
| Notifications | GUI (Settings) | `cmux settings get/set notifications.*`; macOS permission asked on first use | yes | set yes; toggle-workspace-mute no |
| Team invites | web dashboard | `POST /api/teams/<id>/invitations`; `cmux home invite --email` for Home conversations | API yes | no |

There is no onboarding sequence in cmux NEXT (Lawrence, 2026-10-09): the
onboarding window shows one step, browser import or Computer Use, when asked.

## The surface

`cmux setup` is a CLI scope beside `cmux agents`, for agents: every command
prints one JSON object, with or without `--json`.

- `cmux setup list`: every task above as `{id, summary, setup, check, apply,
  person}`. `setup` is the `cmux setup` command when setup runs the task;
  `check` and `apply` are the commands that do it today; `person` is what
  only the person can do. One read gives an agent the whole map, including
  tasks setup does not run yet.
- `cmux setup status`: the read-only check of every task setup runs.
- `cmux setup <task> ... [--dry-run]`: check, then change only what is not
  already right. The result is

  ```json
  {"schema_version": 1, "task": "trust", "state": "changed", "dry_run": false,
   "before": {...}, "after": {...}, "undo": "cmux setup trust /repo --level unknown",
   "user_action": null}
  ```

  `state` is `ok` (nothing to do; nothing written), `changed`, `planned`
  (`--dry-run`), `needs_user` (`user_action` names the one thing the person
  does: `{kind, text, command, url}`) or `failed`. `undo` is the command
  that puts the old state back. Exit 0 unless the task failed (1) or the
  arguments are wrong (2).

Default allow, with undo: an agent runs a task without asking when it stays
on this Mac and has an undo. It asks first only for what reaches outside
(invites, a paid Cloud machine, opening this machine to a new peer).

The Chief loads the `cmux-setup` skill (shipped in optchat-chief's
`BUILTIN`, written to `~/.cmux/chief/skills/`), and its prompt points there.
`cmux docs search setup` and the MCP `cmux_docs` tool find the same map.

## Tasks setup runs

1. `trust [FOLDER] [--level trusted|untrusted|unknown]`.
   It writes acpmux's own record (`acpmux::trust`), the answer the pane's
   Trust question and the trust gate read, through the running daemon when
   there is one so a sub-session waiting on the folder goes on at once.
   Claude Code's and Codex's files keep their one writer. The record already
   holding the level is `ok`; `undo` names the level it held before.
   It writes even when an auto-trust rule already answers: acpmux does not
   count a rule alone as the person's answer (a Web turn still asks). A
   linked worktree, or any folder in a repository, takes the record made for
   its worktree's root or its repository (#23151; `via` in the result names
   that folder). That answer already holding the level is `ok`. Forgetting
   it forgets it at `via`, as the pane's Undo does, so every worktree of the
   repository asks again; `written` names the folder whose record changed
   and `through` whether the daemon or the record file took it.
2. `harness [ID ...]`: for each named harness, else every configured or
   discovered one, whether its CLI is installed (its command resolves),
   signed in and outdated. It runs acpmux's health check
   (`acpmux::harness_health`, the rows of `_acpmux/harness/health`) as a
   library, so the answer is fresh and needs no daemon. A sign-in that
   evidence (`auth.check`, the agent's login files) leaves unknown is asked
   of an ACP harness itself, as `cmux harness login ID --status` does
   (`initialize` and `session/new`); `cmux harness doctor` runs a prompt
   turn and stays the deep check. Setup never reads the login keychain
   itself, as the health check does not (cx-hh0vu), and does not start a
   harness whose sign-in may be there: one whose profile env names a
   Keychain item, Codex keeping its login in the keychain
   (`cli_auth_credentials_store` `keyring` or `auto`), or a Claude Code
   adapter. What any other harness reads when it starts is its own. One
   whose unknown the check already explained (a provider key that is not
   set) is not asked either; both keep `signed_in: null` with the reason
   in `auth_detail`. Outdated compares the installed version
   with the newest one the daemon last read (`harness-health.json`), so
   setup asks no registry. A named id that is not configured is checked
   with the profile acpmux ships for it (`configured: false`). The result
   is

   ```json
   {"schema_version": 1, "task": "harness", "state": "needs_user", "dry_run": false,
    "harnesses": [{"id": "gemini", "name": "gemini", "state": "needs_user",
      "configured": true, "installed": true, "program": "gemini",
      "path": "/usr/local/bin/gemini", "version": "0.1.0", "signed_in": false,
      "auth_detail": "session/new failed (-32000): ...", "outdated": false,
      "latest": "0.1.0", "update": null, "problem": null,
      "user_action": {"kind": "oauth", "command": "cmux harness login gemini", ...}}],
    "undo": null, "user_action": {"kind": "oauth", ...}}
   ```

   A harness is `ok` when it is installed and nothing says it is signed
   out (`signed_in` is `null` when cmux cannot see the sign-in, such as
   Claude Code's keychain login; its first chat asks if it must). Signed
   out is `needs_user` with kind `oauth` and `cmux harness login ID`, or
   the profile's own login command (`codex login`) for a harness not
   configured yet; a missing CLI is `needs_user` with kind `install` and the profile's docs
   as `url`. The task state is `needs_user` when any harness is, and its
   `user_action` is the first one. It writes nothing: install and sign-in
   are the person's, and an update has no undo, so an outdated harness
   names its `update` command instead of running it. UniiChat (the bundled
   adapter, offered everywhere) counts only when named or configured; no
   harness at all is `needs_user` to install one. `cmux setup status`
   adds a `harness` check with the same rows.
3. `machine SSH_TARGET [--name NAME]`. It reads the peers
   from the running acpmux daemon (or acpmux's config without one; it never
   starts a daemon to check) and matches the peer by `--name`, or without
   it by ssh host. Without `--name`, a default name (the host's first
   label) that already names a peer elsewhere is `needs_user`
   (`user_action.kind` `name`) and nothing runs: moving that peer would
   drop it, and a `ws://` peer's token with no undo.
   - connected and on this build: `ok`, nothing runs, not even ssh;
   - connected on another build: `cmux acp host update NAME`, `changed`,
     `undo` null (`undo_note`: the old binary is not kept);
   - not registered: `cmux acp host setup SSH_TARGET --name NAME`,
     `changed`, `undo` `cmux acp host rm NAME` (acpmux stays installed on
     the machine);
   - registered at that host but not connected: `host setup` again (it
     keeps the remote config and token and re-registers by name), `undo`
     null;
   - the name pointed at another ssh host: `host setup` moves it, `undo`
     `cmux acp host add NAME OLD_URL`.

   Before any change it runs `ssh -o BatchMode=yes -o ConnectTimeout=15
   TARGET true`; a refusal or timeout is `needs_user` with
   `user_action.kind` `ssh` and that command. It never asks for a password
   and never writes a key or `~/.ssh/config`. `--dry-run` runs only that
   probe and reports the `plan`. The work runs as `cmux acp host
   setup|update --json` (this executable as a child): acpmux's functions
   for it are private, print their own JSON and exit the process on a
   failed update. The result adds `target`, `name`, `daemon`, `before` and
   `after` (`{name, url, connected, outdated, remote_build, error}`), `ssh`
   (`{command, reachable, error}`), `plan`, `remote_version`, `reverse`,
   `error` and `undo_note`. `reverse` is `{supported: false}` today: `host
   setup` registers the machine here only. Once #22823 lands, the task
   moves to `acp host enroll` (install, daemon, harness, peers both ways,
   doctor) and `reverse` reports the way back.

   `cmux setup status` adds a `machine` check: every peer with
   `connected`, `outdated` and, when it needs one, the `cmux setup machine`
   command that fixes it.
4. `mcp [claude|codex ...]`: gives Claude Code and Codex the cmux MCP
   server (`cmux mcp serve`) when they run outside cmux, in a terminal or
   another app (default: each one installed). Chats cmux starts already get
   it, and cmux-cua, from acpmux (`agent_tools`); cmux-cua needs the app's
   per-session socket token, so no user config can hold it. Each
   harness's own CLI writes its own config, so the file keeps its one
   writer: `claude mcp add --scope user cmux -- <this cmux> mcp serve` and
   `codex mcp add cmux -- <this cmux> mcp serve`; `undo` is `claude mcp
   remove --scope user cmux && codex mcp remove cmux` for what changed.
   Setup only reads the user-scope config (`~/.claude.json` or
   `$CLAUDE_CONFIG_DIR/.claude.json`, `$CODEX_HOME/config.toml`):
   - an entry that runs `cmux mcp serve` from a command that still runs:
     `ok`, no CLI runs;
   - none: add it, `changed`;
   - one named `cmux` whose command is gone (an app that moved): remove
     and add it, `undo` puts the old one back;
   - one named `cmux` that runs something else: the person's, left as it
     is, `needs_user` (`kind` `conflict`) with the `mcp remove` that frees
     the name;
   - a named harness that is not installed: `needs_user` (`kind`
     `install`, `cmux setup harness ID`); one not named is
     `not_applicable`.

   `cmux mcp serve` answers a client outside a cmux chat only when the
   settings file says `"mcp": {"enabled": true}`, the person's opt-in. It
   is not a key in the app's settings schema, so agents cannot set it, and
   the settings file has one writer (the config owner); until it is on,
   setup writes nothing: changes are `planned` and the task is
   `needs_user` (`kind` `setting`) naming the file and the key. The result
   adds `server` (`{name, command, args}`), `settings`, `enabled` and
   `clients` (`{id, name, state, installed, config, entry, undo,
   user_action, error}`). `cmux setup status` adds an `mcp` check.
5. `computer-use`: lets agents use the Mac through cmux Computer Use. The
   state is the app's `computer_use.status` (`{phase, accessibility,
   screen_recording, helper}`, the model behind Computer Use Setup and
   `cmux agents doctor`). Phase `off`: setup sends `settings.set
   computerUse.enabled true` with `confirm: true`; the key is the
   person's, so the app asks them on its native sheet and setup waits for
   that one click. Allowed is `changed` with `undo` `cmux settings set
   computerUse.enabled false --confirm` (the same sheet), or `needs_user`
   with that `undo` while a grant is still missing or the phase has not
   caught up (`kind` `wait`). A rerun reads `settings.get
   computerUse.enabled` first, so a lagging phase never shows a second
   sheet. Not allowed is `needs_user` (`kind` `declined`: the person
   declined, or cmux had no window for the sheet), and the agent asks
   before trying again. Once on, each missing grant is `needs_user`
   (`kind` `grant`) whose `command` opens its System Settings pane (`open
   'x-apple.systempreferences:...'`), Accessibility first. Managed
   settings that turn it off (`kind` `policy`), a helper that is starting
   (`kind` `wait`) or not ready (`kind` `app`, `cmux action run
   palette.computerUse.setup`) and no running app (`kind` `app`) are named
   and left. Capture consent is not reported by the app yet. Off macOS,
   with no app socket named, it is `not_applicable`. `cmux setup status`
   adds a `computer_use` check.

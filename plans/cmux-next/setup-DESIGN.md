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
| Cloud machine | GUI (New Cloud Machine sheet) | `cmux setup cloud-machine`; from an agent the person allows it on a card in cmux | yes | yes (setup keeps its machine) |
| Tailscale, mesh | CLI only | `cmux host enable/status --json`; needs Tailscale signed in | yes | yes |
| MCP servers | docs only; chats cmux starts get them (acpmux `agent_tools`) | `cmux setup mcp [claude\|codex ...]`; `cmux agents doctor --json` checks cmux-cua | yes | yes |
| Computer Use | GUI (Computer Use Setup) | `cmux setup computer-use`; the person allows it on the app's sheet, and grants are switches in System Settings | yes | yes |
| Browser import | GUI (Import from Browser...) | `cmux setup browser-import --browser B [--cookies]`: bookmarks, and cookies after the person's Allow on the consent panel; history and passwords person-only | yes | bookmarks yes; cookies ask again |
| Keyboard shortcuts | GUI (Keyboard Shortcuts) | `cmux keybinding list/resolve --json`; edits only over the raw socket or keybindings.json | reads yes | yes |
| Notifications | GUI (Settings); macOS asks on the first banner | `cmux setup notifications` (the macOS permission); `cmux settings get/set notifications.*` | yes | yes; toggle-workspace-mute no |
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
- `cmux setup status`: the read-only check of every task setup runs. Each
  check keeps its task-specific fields and also has `check_status` (`ok`,
  `needs_action`, or `failed`) and `recovery`. `recovery` is the existing
  structured `user_action` or exact `fix` command; when several nested peers
  or clients need work it is an array of those exact actions. Nested machine,
  harness, and MCP failures therefore remain visible to an agent instead of
  collapsing into a task-level `ok`. A missing safe command stays `null` with
  the original error, rather than guessing a credential, account, or repair.
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
     `not_applicable`;
   - neither installed and none named: nothing to wire, so the task is
     `ok` with no `user_action`, whether the switch below is on or not.

   `cmux mcp serve` answers a client outside a cmux chat only when the
   settings file says `"mcp": {"enabled": true}`, the person's opt-in. It
   is not a key in the app's settings schema, so agents cannot set it, and
   the settings file has one writer (the config owner); until it is on,
   setup writes nothing: changes are `planned` and the task is
   `needs_user` (`kind` `setting`) naming the file and the key. The result
   adds `server` (`{name, command, args}`), `settings`, `enabled` and
   `clients` (`{id, name, state, installed, config, entry, undo,
   user_action, error}`). `cmux setup status` adds an `mcp` check by the
   same rules (`ok` with neither harness installed). A harness CLI that
   cannot be waited on is killed and reaped before the row is `failed`, as
   one past the 30 s limit is.
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
   declined, cmux had no window for the sheet, or the sheet went
   unanswered past the app's 120 s deadline, error code `timeout`), and
   the agent asks before trying again. Once on, each missing grant is `needs_user`
   (`kind` `grant`) whose `command` opens its System Settings pane (`open
   'x-apple.systempreferences:...'`), Accessibility first. Managed
   settings that turn it off (`kind` `policy`), a helper that is starting
   (`kind` `wait`) or not ready (`kind` `app`, `cmux action run
   palette.computerUse.setup`) and no running app (`kind` `app`) are named
   and left. Capture consent is not reported by the app yet. Off macOS,
   with no app socket named, it is `not_applicable`. `cmux setup status`
   adds a `computer_use` check: `needs_setup` while off, and, as the run
   says, `needs_user` (`kind` `wait`) when `computerUse.enabled` is already
   on but the phase still reads `off`.
6. `cloud-machine [--forget]`: makes sure the person has a cmux Cloud
   machine for agents. All of it goes through the app socket: `auth.status`
   (signed in, `cloud_unavailable`), `cloud.machines` (`machines`, the
   `creations` in flight, `last_error`, and `loaded` once cloud-team-ready
   adds it) and `action.run newCloudMachine`. Signed out is `needs_user`
   (`kind` `sign_in`, `cmux cloud sign-in`).

   Setup keeps what it asked for in `<state root>/setup/cloud-machine.json`
   (beside the daemon's `sessions`, written whole by rename): the run's
   idempotency key, and the machines and creations cmux showed, saved
   before the create is sent; then the `creation_id` or the machine it
   became. One run at a time decides, under an `flock` on
   `cloud-machine.lock` beside it, held from reading the list through the
   create.

   The list decides first. A `last_error`, `loaded: false`, or an empty
   `machines` (without `loaded: true`) while setup has a machine or a
   request on file is `kind` `wait`: nothing is cleared or created. A kept
   machine cmux shows is `ok`; missing from a list that is not empty (or
   says `loaded: true`), it is gone and setup makes a new one. Until cmux
   sends `loaded`, a `wait` on an empty list ends when cmux shows its
   machines, or with `cmux setup cloud-machine --forget` once the person
   says none is on its way. A kept creation (the `creation_id` the app
   answered) is followed: its row's `machine_id` is setup's machine, else
   the one new machine once the row leaves (`inferred: true`). A kept key
   with no answer (the connection dropped, the wait ran out, the app
   answered no result): with more than one new machine (named by new
   creations or new rows) setup claims none (`kind` `many_machines`);
   otherwise a new creation still on its way is waited for; the one new
   machine is claimed as `inferred: true` with an `undo_note` (no creation
   setup recorded names it, so the person may have made it); only when
   nothing new appeared is the create sent again with the same key. A state
   from before `known_creations` was kept counts every listed creation as
   known. The app's answer to a key lives in memory (256 keys),
   so after cmux restarts only the list keeps a second card and a second
   paid machine from happening. Any other machine cmux shows is `ok` and
   left alone; a creation in flight that setup did not ask for is `wait`.

   Otherwise setup runs `newCloudMachine`, which from an agent always asks
   the person on a card in cmux; the app answers within 30 s, the person's
   answer included. Made is `changed` with `undo` `cmux cloud kill-machine
   --target machine:ID --confirm && cmux setup cloud-machine --forget` (a
   state file it cannot write adds a `warning`, never a lost `changed`);
   `machine` is `{id, title, status, target}` on `ok` and `changed` alike.
   Still on its way is `needs_user` (`kind` `wait`). Only the app's decline
   reason is `kind` `declined` (the person declined, or cmux had no window),
   and the agent asks before trying again. The key is dropped only then, or
   when nothing ran (`busy`, `data.not_run`, or a request that never left);
   on any other refusal (a plan with no room, `idempotency_conflict`) it
   stays, the result is `kind` `app` with the app's text, and reruns decide
   from the list; `--forget` lets setup ask again once the cause is fixed.
   Plan limits are not read beforehand (the app has no read of them on its
   socket; `cloud.plan.get` is an app op behind the daemon); a plan with no
   room comes back as `daemon_error` ("new Cloud machine: ..."). Known
   limit: the decline is matched on the app's English reason
   (`CloudStrings.createDeclined` is localized), so in another language a
   decline reads as `kind` `app` with the app's text, and the key stays.

   A paused machine is `ok` with a `note` naming `cmux cloud
   resume-machine`; a failed one is `needs_user` naming the undo.
   `--dry-run` asks nothing and writes nothing, not even the lock:
   `planned` with `cost` (a machine costs money every hour it runs and does
   not pause by itself), `planned` with the undo when the run would claim a
   machine, or `ok` when there is a machine. `--forget` drops the state file and
   changes nothing in cmux; run it after the machine is killed, or once the
   person says no machine is on its way. `cmux setup status` adds a
   `cloud_machine` check by the same rules (`needs_setup` when the run
   would send a create, also one sent again with its key). When cloud-team-ready's `cloud
   list-machines` lands (owner personal|team), setup reads it instead of
   `cloud.machines`.
7. `notifications`: lets cmux show macOS notifications. The state is the
   app's `notifications.status` (`{authorization, alert, alert_style, sound,
   badge, bundle_id}`, `UNUserNotificationCenter.notificationSettings`, read
   without prompting; Release-safe, unlike `debug.notifications`).
   `not_determined`: setup sends `notifications.request`, macOS shows its
   prompt and setup waits for the person's click; allowed is `changed`,
   not allowed, or the prompt left unanswered past the app's 600 s, is
   `needs_user` (`kind` `declined`), and the agent asks before trying
   again; macOS failing the request (`internal_error`) is `failed`. `denied` is `needs_user` (`kind` `grant`) whose
   `command` opens cmux's page in System Settings > Notifications (`open
   'x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=BUNDLE_ID'`).
   macOS has no command that takes the permission back, so `undo` is that
   pane command and `undo_note` says so. `authorized` and `provisional`
   are `ok`, except `authorized` with banners off (`alert_style` `none`, or
   `alert` false; `alert` is `alertSetting`, which can stay true with the
   style None, and is all an older app sends): no banner shows, so it is
   `kind` `grant` with the same pane. An app without the methods
   (`method_not_found`) is `kind` `app` with the Notifications pane command. A launch that never uses the
   system center (an automation launch, a GUI job, or a host that is not the
   cmux app bundle) answers `unavailable`.
   Which notifications show stays `notifications.*` settings. `cmux setup
   status` adds a `notifications` check.
8. `browser-import --browser BROWSER[:PROFILE] [--cookies [--domain D]
   [--reason TEXT]]`: brings another browser's bookmarks, or its sign-ins,
   into cmux. `--browser` reads the way the app's cookie import reads
   `--from`: a browser (registry id or product name, ignoring case, spaces
   and punctuation; the registry is the app's `browser-sources.json`,
   compiled in), then optionally `:` and one profile (its folder or the
   name the browser shows), for bookmarks and cookies alike; `chrome:` is
   `chrome`. A browser with no name (`:Work`, a blank) is a usage error
   (exit 2), since the app would open its picker, and so is a flag given
   twice or a flag-like next word taken as a value (`--domain --dry-run`;
   `--domain=--x` is meant). Without `--browser` it is `needs_user`
   (`kind` `choose`): the agent asks which browser, or for bookmarks runs
   `cmux action run bookmark.importFromBrowser` to show the person the
   app's picker of the browsers it found (with `--cookies` its `command`
   is null: the picker imports bookmarks).

   Bookmarks are not secrets, so setup does them. The state is
   `bookmark.list`, where each imported profile is one Bookmarks Bar folder
   with `source_key` `<browser id>/<profile folder>` and the title
   "Imported from <Browser> (<profile name>)". The check is per browser: a
   browser any profile of which was imported counts as done (`ok`, nothing
   runs); import another profile with `--browser ID:PROFILE`, which is
   `ok` only when that profile's folder is there: setup asks the app's
   `bookmark.importSources {browser, source?}` for the source keys the
   import would use (the app matches the profile's folder or name; with no
   profile, every profile of the browser) and looks for those, never at
   the title, which is localized and the person may rename; a browser or
   profile the app does not find, with no folder of it there yet, is
   `needs_user` (`kind` `browser`); a profile the browser no longer has is
   still `ok` when named by its folder (`chrome:Profile 9`), which the
   stored source key keeps, though not by its shown name, which went with
   it.
   `bookmark.list` answers `loaded` false with an empty list until the app
   has the stored bookmarks; setup reads again until 2 seconds after the
   first answer (each reread gets only the time left), then is
   `needs_user` (`kind` `wait`), so folders already there never count as
   new. A dry run is `planned` with the `undo`
   `cmux bookmark remove --target bookmark:FOLDER_ID`. Otherwise setup runs
   `bookmark.importFromBrowser {browser, source?, profile}` (`profile` is
   the cmux browser profile `bookmark.list` answered for) and reads the
   list again: `changed`, with `after.folders` the folders of those source
   keys that were not there before and the `undo` `cmux bookmark remove
   --target bookmark:<id>` for each; the person's own folders and other
   imports never enter it. A new folder of another profile of the browser
   came from an import running at the same time (`chrome:Work` next to
   `chrome:Default`): it is in `after.other`, with a `note`, and the undo
   leaves it; it is no sign this run's import landed, so a run whose app
   stopped waiting with only such folders in is still `wait`. Two runs of the same profile at once both name its folder;
   the app's import returns no ids, so setup cannot tell them apart. The app replaces a folder of the same `source_key` in
   place (same id, new title and children), as when the browser's
   profiles changed between `bookmark.importSources` and the import: such
   folders, whose title or
   children changed, are in `after.refreshed`, and an answer that the
   import ran with no new folder is `changed` with `undo` null and a `note`
   that the folder was refreshed in place and the Undo on the app's toast
   is its only undo. The app may stop waiting before the import ends
   (`timeout`, or a lost answer): setup reads the list anyway, and the
   folders that came in are `changed` as above, with their `undo` and a
   `note` that the import may still be adding profiles (run `cmux setup
   browser-import --browser B --dry-run` again to see them); none yet is
   `needs_user` (`kind` `wait`: run it again in a few seconds). A browser
   the app does not find, or with no readable profile, is `needs_user`
   (`kind` `browser`); profiles that could not be read next to ones that
   came in are named in `unread`.

   Cookies are the person's: `--cookies` runs `browser.importCookies
   {from, domain?, reason}` (from an agent or script, never origin `user`),
   and the app asks the person on its consent panel (then macOS asks for
   the browser's Keychain key). Allowed is `changed`. Denied, timed out, or
   another request already waiting is `needs_user` (`kind` `declined`):
   nothing was read, and the agent asks before trying again. An answer lost
   after the panel (`timeout` or a dropped connection) is `kind` `app`
   saying the outcome is unknown: the agent must not run `--cookies` again
   without asking the person. The app reads no imported cookies back, so a
   cookie run is never `ok` and running it again asks again; it has no
   `undo` (clearing the profile's cookies clears every cookie), and
   `undo_note` says so. History and passwords are person-only (Import from
   Browser... in cmux); every result names that in `person`. `cmux setup
   status` adds a `browser_import` check: the browsers whose bookmarks are
   in.

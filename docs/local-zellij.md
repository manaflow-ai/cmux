# Local zellij persistence

`cmux local-zellij` is the zellij counterpart of [`cmux local-tmux`](local-tmux.md):
an explicit, opt-in profile that keeps named local sessions alive across cmux
quit, crashes, and app updates. It starts zellij sessions in a private socket
directory under `~/.cmux/local-zellij` and attaches cmux terminals to them as
zellij clients. Ordinary cmux terminals still launch their usual Ghostty PTY.

## Quick start

```sh
cmux local-zellij start work --cwd ~/src/project --command 'npm run dev'
cmux local-zellij list
cmux local-zellij status work
cmux local-zellij attach work
cmux local-zellij close work
```

`start` creates the session in the background and attaches it to the caller's
workspace. `--detached` creates the session without attaching. To use it from
a terminal outside cmux:

```sh
cmux local-zellij attach work --headless
```

With `--command`, the session opens with that command running through
`/bin/sh -lc`, between zellij's default tab bar and status bar. Without it,
the session uses your zellij default layout and shell.

## Lifecycle

The zellij server owns the shell, agents, dev servers, PTYs, and scrollback.
cmux owns only a client surface. Each cmux client attaches with
`options --on-force-close detach`. zellij applies that option on the client,
so closing a surface, quitting cmux, or a crash detaches the client instead of
quitting the session, even when your zellij config sets `on_force_close "quit"`.

On cmux session restore, a terminal whose saved startup command is exactly the
attach command cmux generated (marked `CMUX_LOCAL_ZELLIJ=1`) reattaches to its
session. Any other command in that slot is ignored. As with local-tmux, the
live session takes precedence over saved agent resume metadata, so an agent
running inside zellij isn't launched a second time.

### After logout or restart

A logout, restart, or shutdown ends the zellij server and its processes, and
the session ends with it. As with local-tmux, this persists processes across
cmux's lifecycle, not across the machine's. To keep processes running while
this Mac is offline, use `cmux ssh-tmux`, `cmux mosh-tmux`, or a persistent
cloud VM.

cmux creates its sessions with zellij's session serialization off. Only the
`cmux local-zellij` CLI, which clears cmux's socket credentials and terminal
identity from the environment, ever starts a zellij server. A serialized
session would outlive its server, and a cmux terminal's `zellij attach` would
then resurrect it into a new server that inherits that terminal's
credentials. If zellij ever does list an owned session as exited, `status`
reports `exited`, and `start` and `attach` refuse it until you `close` it.

## Identity and safety

The registry at `~/.cmux/local-zellij/sessions.json` stores a stable logical
UUID per session with its name, cwd, and the last workspace and surface cmux
attached it to. The zellij session is named after both: `work` becomes
`work-3f2a9c1d`, the name plus the first eight hex digits of the UUID
(`list --json` and `status --json` report it as `zellij_session_name`).

zellij keeps exited sessions in a resurrection cache shared by every zellij
session you run, not only the ones in cmux's socket directory. The token is
what shows that an exited `work-3f2a9c1d` came from this profile, so `status`,
`attach`, `close`, and session restore never act on an unrelated zellij
session that happens to be called `work`. For the same reason, sessions
started outside `cmux local-zellij` are never adopted.

`start` and `close` hold a profile-wide lock around both the zellij call and
the registry update, so a `close` racing a `start` of the same name cannot
leave a live session without a record. `start` saves the record before it creates the
session, so if creation can't be confirmed (say, the follow-up listing
fails), rerunning `start` finds the same session instead of starting a second
one; with `--command` it refuses rather than running the command again. If
zellij reports the session as exited before `start` could check it, `start`
keeps the record and says so; `close` removes it.

The state and socket directories are created mode `0700` and the registry
`0600`; cmux refuses to use them if another user owns them or they are group-
or world-accessible. zellij's sockets are the access boundary for its
sessions, so don't share these directories with another Unix user.

`close` runs `zellij delete-session --force`, which ends the session and drops
its resurrection entry, then removes the registry record. Closing a cmux
surface never ends the session.

## Limitations

- Requires a local `zellij` executable on `PATH` or in a common install
  location, or set `CMUX_LOCAL_ZELLIJ_BIN`. Tested with zellij 0.43.
- Session names must match `[A-Za-z0-9_][A-Za-z0-9_-]*` (no leading dash,
  which zellij would read as an option) and fit in a Unix socket path, with
  room for the 9-byte ownership token (macOS allows 104 bytes). zellij hangs
  instead of failing on a longer socket path, so cmux rejects such names up
  front. Set
  `CMUX_LOCAL_ZELLIJ_STATE_DIR` to a shorter directory if your home path
  leaves too little room.
- Unlike local-tmux, there is no `detach` or `cleanup` subcommand yet, and the
  Settings panel lists only local-tmux sessions.
- Identity comes from the registry token in the session name, not from a
  server-incarnation marker like local-tmux's. Anyone who can create zellij
  sessions as your user can create one with the same name.

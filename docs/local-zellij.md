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

A logout, restart, or shutdown ends the zellij server and its processes. If
zellij's session serialization is on (the zellij default), the session is kept
as an exited session: `list` and `status` show it as `exited`, and attaching
resurrects its layout. zellij asks before rerunning each saved command. This
brings back the layout and commands, not the old process memory, SSH
connections, or exact scrollback. To keep processes running while this Mac is
offline, use `cmux ssh-tmux`, `cmux mosh-tmux`, or a persistent cloud VM.

`start` refuses a name that belongs to an exited session. Attach to it or
`close` it first. An exited session you created with plain zellij, outside
cmux, is never adopted; `start` names it and asks you to delete it or pick
another name.

## Identity and safety

The registry at `~/.cmux/local-zellij/sessions.json` stores a stable logical
UUID per session with its name, cwd, and the last workspace and surface cmux
attached it to. Sessions are identified by name inside the private socket
directory, which only this profile uses.

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
- Session names must match `[A-Za-z0-9_-]+` and fit in a Unix socket path
  (macOS allows 104 bytes). zellij hangs instead of failing on a longer
  socket path, so cmux rejects such names up front. Set
  `CMUX_LOCAL_ZELLIJ_STATE_DIR` to a shorter directory if your home path
  leaves too little room.
- Unlike local-tmux, there is no `detach` or `cleanup` subcommand yet, and the
  Settings panel lists only local-tmux sessions.
- Sessions are matched by name, not by a server-incarnation marker like
  local-tmux's, so a session recreated under the same name is treated as the
  same session.

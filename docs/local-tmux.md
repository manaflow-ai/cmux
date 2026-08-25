# Local tmux persistence

`cmux local-tmux` is an explicit, opt-in persistence profile for local terminal
processes. It starts one user-owned tmux server under `~/.cmux/local-tmux` and
attaches a cmux terminal to a named tmux session. The default cmux terminal
profile still launches its ordinary Ghostty PTY.

## Quick start

```sh
cmux local-tmux start work --cwd ~/src/project --command 'npm run dev'
cmux local-tmux list
cmux local-tmux status work
cmux local-tmux detach work
cmux local-tmux attach work
cmux local-tmux close work
```

`start` creates the session and attaches it to the caller's workspace. Use
`--detached` to create only the durable owner, then attach it later. A session
can also be attached directly from a non-cmux terminal:

```sh
cmux local-tmux attach work --headless
```

The alias `cmux tmux attach work` is accepted for scripts that prefer the
shorter tmux vocabulary.

## Lifecycle and identity

The tmux server owns the shell, agent, dev-server, PTY, and scrollback process;
cmux owns only the client surface. Closing or updating cmux therefore detaches
the client instead of terminating the session. On cmux session restore, the
generated attach command is carried in the existing terminal snapshot and is
replayed only when it has the `TMUX= CMUX_LOCAL_TMUX=1` marker.
New sessions receive a bounded 10,000-line tmux history limit.

The registry stores a stable logical UUID, the tmux name/socket, cwd, and
workspace title/cwd hints. Runtime workspace and surface IDs are hints only:
reattach matches the durable title/cwd association and validates any live
surface before reusing it. `--new-client` deliberately creates another cmux
client instead of reusing a restored one.

## Discovery, cleanup, and safety

```sh
cmux local-tmux list --json
cmux local-tmux cleanup --prune
cmux local-tmux detach work --client <client-id>
cmux local-tmux detach work --all
```

`list` reports unmanaged sessions found on the profile socket and stale
registry entries. `cleanup` previews stale registry records by default;
`cleanup --prune` removes them. Neither form kills an unknown live session.
Detach refuses to guess when multiple clients are present unless `--client` or
`--all` is supplied.

The state directory is created mode `0700`, the registry and lock mode `0600`,
and tmux's Unix socket is never exposed by cmux. GUI/API operations still use
cmux's authenticated control socket. Headless operations are limited by the
operating-system user and those filesystem permissions; do not share the
state directory or socket with another Unix user.

## Limitations

- This slice requires a local `tmux` executable (or `CMUX_LOCAL_TMUX_BIN`).
- A terminal application that depends on a particular outer PTY, GUI window,
  or terminal emulator-specific device protocol may need its own reconnect
  handling; tmux preserves bytes and processes, not those external resources.
- The profile uses one tmux server socket per Unix user. Names must match
  `[A-Za-z0-9._:-]+` and are limited to 128 characters.
- Closing a cmux surface does not kill the tmux session. Use `local-tmux close`
  when the durable owner should be terminated.

The next slice can expose the same registry through a first-class socket RPC
namespace and richer workspace metadata, without changing the default local
terminal process model.

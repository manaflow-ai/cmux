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
shorter tmux vocabulary. The alias is attach-only; use `cmux local-tmux` for
session listing and lifecycle operations.

## Lifecycle and identity

The tmux server owns the shell, agent, dev-server, PTY, and scrollback process;
cmux owns only the client surface. Closing or updating cmux therefore detaches
the client instead of terminating the session. On cmux session restore, the
generated attach command is carried in the existing terminal snapshot and is
replayed only when it has the `TMUX= CMUX_LOCAL_TMUX=1` marker.
New sessions receive a bounded 10,000-line tmux history limit.

The registry stores a stable logical session UUID bound to a tmux server
incarnation marker, the immutable `$N` session ID, and the session creation
time. The random server marker lives only in that tmux server's memory, so a
restarted server cannot inherit an old record even if it reuses `$N`. Attach,
detach, and close check the marker inside the same tmux request that performs
the operation and fail closed on a mismatch. A tmux-side session rename keeps
the immutable binding and updates the registry name instead of creating a
second record.

The registry also stores the tmux socket, cwd, and the last authoritative
workspace/surface identifiers. Reattach validates workspace IDs against the
live control plane; if the workspace still exists but its old surface is gone,
cmux creates a replacement client surface. Title and cwd remain display and
diagnostic hints only: when the saved workspace identifier is stale, pass an
explicit `--workspace` rather than attaching to a mutable lookalike.
`--new-client` deliberately creates another cmux client instead of reusing a
restored one.

### What persistence covers

The owner is a local tmux server, not the cmux GUI. It remains alive when cmux
quits, crashes, updates, or closes a surface, and normally remains alive while
the Mac sleeps with its process image preserved. Reattach then validates the
server-incarnation marker and immutable tmux session ID before reconnecting the
correct session; a missing surface is recreated.

This is not persistence through a machine shutdown. Logout, restart, shutdown,
forced power loss, or a killed tmux server terminates the local process, its
children, live PTY state, and in-memory scrollback. The registry file may still
be present, but the server marker deliberately no longer matches, so reattach
fails closed instead of attaching to an unrelated replacement. Recreating the
commands after login would be a separate resurrection feature and cannot
restore process memory, an SSH connection, or exact scrollback. For continuity
while this Mac is offline, run the owner on a remote host with `cmux ssh-tmux`,
`cmux mosh-tmux`, or a persistent cloud VM.

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
and the tmux Unix socket path may appear in CLI lifecycle output. It is not a
cmux control endpoint and remains protected by those filesystem permissions.
GUI/API operations still use cmux's authenticated control socket. Headless
operations are limited by the operating-system user; do not share the state
directory or socket with another Unix user.

## Diagnosing protected-folder access errors

If a shell in tmux reports `Operation not permitted` while reading a file in
`~/Documents` or another protected folder, record the failure before restarting
cmux, replacing the tmux server, or changing permissions. A live server and a
successful attach do not establish that its child processes can read that file.

First identify the affected server. Inside the affected tmux pane, run:

```sh
tmux display-message -p 'socket=#{socket_path} server_pid=#{pid} server_version=#{version}'
tmux -V
```

`server_version` comes from the running server; `tmux -V` describes the client
binary currently on `PATH`. They can differ after a package upgrade. Record the
server PID and start time as well as the cmux and macOS versions. On macOS,
substitute the reported server PID in these read-only commands:

```sh
ps -p <server-pid> -o pid=,ppid=,lstart=,command=
lsof -a -p <server-pid> -d txt
```

The `txt` entries show mapped executable and code files.
If the mapped executable path has been replaced or removed, record that too; it
is a possible confounding factor, not proof of the permission failure's cause.

Outside the pane, use `tmux -S <socket-path>` to query the same server, or
`tmux -L <socket-name>` for an explicitly named server. A plain `tmux ls`
does not list every server. For the cmux local-tmux profile,
`cmux local-tmux list --json` includes `socket_path`; external tmux launchers
may use a different socket.
Do not infer that a session died from a query against another socket.

Compare the original failing operation in the affected pane, a direct cmux
shell outside tmux, and a direct shell in the other terminal app. Use the same
absolute path and record which app hosts each shell. For a directory-listing
failure, run this POSIX-shell snippet in each context, replacing the example
path with the affected directory:

```sh
diagnostic_dir="$HOME/Documents/path/to/affected-directory"
date -u '+%Y-%m-%dT%H:%M:%SZ'
/bin/ls -a "$diagnostic_dir" > /dev/null
diagnostic_status=$?
printf 'directory listing exit=%s\n' "$diagnostic_status"
```

Standard output is discarded to avoid printing directory entries; standard
error remains visible so the exact error can be recorded. If the original
failure used a relative path such as `ls .`, also record the working directory
and repeat that exact command: a fresh lookup by absolute path may behave
differently from access through an existing working directory.

For a file-read failure, choose one harmless, existing regular file and use
this additional check in the same shell contexts:

```sh
diagnostic_file="$HOME/Documents/path/to/harmless-file"
date -u '+%Y-%m-%dT%H:%M:%SZ'
cat "$diagnostic_file" > /dev/null
diagnostic_status=$?
printf 'file read exit=%s\n' "$diagnostic_status"
```

A successful file read does not establish that listing its directory works.
Record each command, time, exact error, and exit status without including
private contents. If a separate server succeeds, also record its version and
launch context: that result alone does not isolate server age, TCC state, or
cmux as the cause. If a later retry succeeds without intervention, report the
failure as currently non-reproducible rather than permanently fixed.

When reporting the problem, include:

- Whether the session uses `cmux local-tmux` or an external launcher.
- The tested app build/revision and whether newer relevant changes were tested;
  a marketing version alone may not distinguish a release from a development
  build.
- The affected server's version/start time and how its socket was selected.
- The failing operation and the results for the same path in each shell context.
- Any available permission-denial record at the failure time, with private
  paths and unrelated process details removed.

`EPERM` is not specific to TCC, and a daemon's parent PID alone does not identify
its responsible application. `Operation not permitted` (EPERM) and
`Permission denied` (EACCES) are different errors; record the exact wording or
errno rather than treating them as interchangeable. See
[Apple's guidance](https://developer.apple.com/forums/thread/678819).
The related [report](https://github.com/manaflow-ai/cmux/issues/2866) is an
investigation, not evidence that every similar failure has the same cause.

## Limitations

- This slice requires a local `tmux` executable (or `CMUX_LOCAL_TMUX_BIN`).
- A terminal application that depends on a particular outer PTY, GUI window,
  or terminal emulator-specific device protocol may need its own reconnect
  handling; tmux preserves bytes and processes, not those external resources.
- The profile uses one tmux server socket per Unix user. Names must match
  `[A-Za-z0-9_-]+` and are limited to 128 characters.
- Closing a cmux surface does not kill the tmux session. Use `local-tmux close`
  when the durable owner should be terminated.

The next slice can expose the same registry through a first-class socket RPC
namespace and richer workspace metadata, without changing the default local
terminal process model.

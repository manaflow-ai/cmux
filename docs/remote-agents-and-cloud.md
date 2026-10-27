# Remote agents and cmux Cloud

Run an agent on a machine you own and view it from your Mac, or use a machine
managed by cmux Cloud. The repository and tools execute on the remote host;
your Mac is a client. Closing the client does not move the files or stop the
remote agent.

This guide describes the cmux NEXT command surface checked on 2026-10-25.
Use the CLI bundled with the app you are running. Available commands can differ
between builds. See the [acpmux README](../cmux-tui/crates/acpmux/README.md) for
harness profiles and protocol details, and the [cmux-tui build prerequisites](../cmux-tui/README.md#build)
before building from source.

## Connect your own machine

You need SSH access to your own Mac or Linux host, persistent storage, a
compatible acpmux executable, and the agent harness you want to run. Authenticate
that harness as yourself on the execution host: after installing Claude Code or
Codex, run `claude auth login` or `codex login` there. SSH does not forward your
model login or GitHub credentials automatically.

For example, a NIGHTLY installation exposes the bundled CLI in this shell with:

```sh
export PATH="/Applications/cmux NIGHTLY.app/Contents/Resources/bin:$PATH"
acpmux --version
acpmux daemon start
```

For a compatible remote Mac, `acpmux host setup my-mac` installs acpmux and its
daemon over SSH and adds the peer. It copies the invoking executable: do not
use a Mac executable to bootstrap a Linux machine.

On your own Linux host, install a build for its architecture. To build from
source, install the Rust toolchain and Zig version required by the
[cmux-tui README](../cmux-tui/README.md#build), then initialize the submodules
before building. Install the resulting binary at `~/.local/bin/acpmux`, which
`host doctor` checks by default:

```sh
git clone --branch feat-cmux-next https://github.com/manaflow-ai/cmux.git
cd cmux
git submodule update --init ghostty ghostty-next
cd cmux-tui
cargo build --release -p acpmux
mkdir -p "$HOME/.local/bin"
install -m 755 target/release/acpmux "$HOME/.local/bin/acpmux"
export PATH="$HOME/.local/bin:$PATH"
acpmux daemon run --listen 127.0.0.1:47811
```

The daemon runs in the foreground. For unattended use, configure your own
service supervisor with that executable, persistent home and harness PATH;
verify it remains available after SSH logout. Add `~/.local/bin` and the harness
installation directory to that service's PATH as well; the shell export above
affects only the current shell. Keep the WebSocket listener on
loopback. The peer connection below tunnels it through SSH.

Don't rely on `--listen` alone to carry over to later starts. If you use a port
other than 47811 (for example because another daemon already holds it), also
merge `"listen": "127.0.0.1:PORT"` into the `websocket` object of
`~/.acpmux/config.json`, keeping its token and the file's other fields, so
`acpmux daemon start` and later restarts use it, and give the same port in the
peer URL below.

The daemon creates its home and its files owner-only, whatever your umask. It
refuses a home or log that something else left writable by other users, and its
error names the `chmod` that fixes it. If a service supervisor or a shell
redirect creates the log, create it owner-only (for example with `umask 077`).
An older acpmux that refuses its own new home under a group-writable umask
needs `chmod 700 ~/.acpmux` before it starts.

Back on your Mac, use an SSH alias that reaches your own remote account:

```sh
ssh my-linux
# After leaving the remote shell:
acpmux host add my-linux ssh://my-linux
acpmux host ls
acpmux host doctor my-linux --json
```

Run the SSH probe before adding a host. If the first connection is offline,
`host add` saves the peer, exits 0, and prints a warning to stderr with the
SSH probe and doctor commands to run next. With `--json`, the response includes
`warning: {"reason":"peer_unreachable","try":"ssh -o BatchMode=yes HOST true",
"detail":"the peer was saved and will keep reconnecting"}`. WebSocket URLs
use `acpmux host ls` as the next command. Saving failures remain errors:

```sh
ssh -o BatchMode=yes my-linux true
acpmux host add my-linux ssh://my-linux:47921
acpmux host doctor my-linux --json
```

When testing a second home, clear inherited daemon variables. `ACPMUX_SOCKET`
wins over `ACPMUX_HOME`, so a shell opened inside another agent can report that
agent's live daemon and make `daemon start` a no-op:

```sh
env -u ACPMUX_SOCKET ACPMUX_HOME="$HOME/acpmux-test" acpmux daemon status
```

Inspect the selected home and socket before shutting anything down.

An SSH URL can include a user, such as `ssh://me@host`. An explicit URL port
selects the remote **acpmux listener** (default 47811), not the SSH server port;
configure the SSH server port in your SSH alias. Accept the host key once, then
verify `ssh -o BatchMode=yes my-linux true`: the peer cannot answer password/2FA
prompts. You can use your own Tailscale network, a private network or an ordinary
SSH route. The peer reads credentials from the remote default `~/.acpmux` home.
acpmux reads the peer's authentication through SSH; you do not need to paste
its daemon token. Peering grants access to session contents and tools, so add
only hosts and accounts you trust.

Run `host doctor` from your Mac against the SSH alias; on the host itself, use
`acpmux daemon status` and `acpmux daemon harnesses`. `host doctor` without
`--harness` skips harness checks; a healthy peer does not prove that an agent
can run. Its `--harness ID` option is described below. Verify the remote
harness with `acpmux daemon harnesses` on that host and a real session prompt.

`host enroll` and `host setup` install the invoking binary. Use them only for a
compatible remote OS and architecture. For a Linux host reached from a Mac, use
the Linux installation and `host add` steps above instead. `host update`
refuses a peer of another OS or architecture unless you pass `--binary-dir DIR`
with a build named `acpmux-<target>` there (for example
`acpmux-x86_64-unknown-linux-musl`); otherwise update that host by rebuilding
it there. Same-target peers can use the plain
`acpmux host update NAME`.

## Work with a remote session

Choose an existing project on the remote host. Its path must be a known local
session cwd or within the daemon's permitted remote project roots (`webRoots`).
For a fresh host, merge `"webRoots": ["/home/me/project"]` into the existing
`~/.acpmux/config.json`, preserving its token and other fields, then restart your
daemon with the same home/listener. This authorizes remote access to that
directory; choose only the project root you intend to expose.

When a tool call asks for permission (a command, or a read the harness does not
already treat as safe), it waits on the chat's pending-permission card in cmux
NEXT on your Mac. Whether the host accepts an Allow from that card depends on
how the chat reaches the host:

- A session reached through your Mac's peer daemon (`acpmux new --host`,
  `cmux agent open-tab --host`, or `--group` with `--host`) cannot be approved
  from the card yet: the host refuses the Allow, and the card says "Remote
  approvals are off". Peer-route approvals are in progress; until they ship, use it for prompts that need no tool approval: a prompt
  that needs no tools, a read-only Codex review (below), or a `vmHost` VM.
- For tool approvals, connect the host in cmux NEXT with **File › Connect to
  Machine…** and start the chat there, on that machine. Before such a chat's
  first prompt, the app restarts the host's agent daemon with an approval key
  only the app holds when nothing on it would be lost. Otherwise the card's
  notice offers "Restart with approvals", which does the same.

Use the CLI bundled with the app (its default home), so the app and the CLI
share one daemon and the app shows the remote chat; open it with
`cmux agent open-tab` (below) or by passing `--group NAME` to
`acpmux new --host`.
`acpmux session allow` is refused for remote sessions; `acpmux pending` and
`acpmux send` point to the app's card for an allow, and `session deny` and
`session cancel` work from the CLI. A start mode that never asks (for example
the codex-acp adapter's `read-only`) is refused from a bare CLI unless a person
starts it in cmux NEXT on that host or approves a preset for it there; an agent
session lends its own mode to a session it starts with the same harness. The
Codex bridge's `ask` and `read-only` modes still ask or stay in the sandbox, so
they start from the CLI (see "Read-only Codex reviews" below). A prompt that
needs no tools completes from the CLI alone. On a Linux agent VM whose config
sets `vmHost` (see the Claude paragraph below), sessions your peer daemon starts
with no `--policy` run without asking.

`--tag` and `--host` with `--group` need an acpmux built from feat-cmux-next on
2026-10-26 or later; check that `acpmux new --help` lists them.

```sh
acpmux new --host my-linux -m codex --name api-work --cwd /home/me/project --tag task=api -d
acpmux ls
acpmux session info my-linux/api-work
acpmux send my-linux/api-work "Summarize this project's structure."
acpmux attach my-linux/api-work
```

`host doctor --harness ID` checks a client profile that can be copied to the
host. If the remote daemon already discovers `ID` on its PATH, the check reports
that discovery and skips profile copying. Verify actual readiness with
`acpmux daemon harnesses`, then create and prompt a real remote session:

```sh
acpmux daemon harnesses
acpmux new --host my-linux -m codex --name api-work --cwd /home/me/project -d
acpmux send my-linux/api-work "Reply with exactly CODEX_REMOTE_OK. Do not use tools."
```

`acpmux harness doctor codex` speaks ACP directly. A Codex app-server that
answers `unknown variant session/new` is a protocol mismatch; it is not repaired
by logging in. Use the bridge through a real `acpmux new --host` session.

Creation labels are repeatable and are applied before the session is listed:
`acpmux new --tag key=value` (and the same option on `run`, `exec` and `ensure`).
If a remote policy, mode or folder check refuses a start, the JSON error's
`error.data.try` is a complete shell-quoted command. Copy it verbatim; it keeps
the prompt and launcher options. A `--prompt-file` is piped through stdin so
the file does not need to exist on the remote host.

Replace `codex` with an installed harness, such as `claude`. A remote-started
Claude session needs the host's sandbox, which acpmux has only on macOS so far:
on a Linux host, `acpmux new --host` refuses `-m claude`. The exception is a
dedicated agent VM (`vmHost`): the VM is the sandbox, so Claude runs there, and
sessions your peer daemon starts with no policy run approve-all. A Cloud VM
cmux created for you is one by default (its `/etc/cmux/vm-kind` reads `owner`);
a team VM, a personal machine and an SSH-added machine never are. Turn it off
or back on per machine with `acpmux host vm-host [NAME] off|on` (no restart;
`on` is refused on a machine cmux did not create), or set `"vmHost": true` or
`false` in that machine's `~/.acpmux/config.json`. A Mac ignores `vmHost`, and
Web clients and sessions started with an explicit `--policy` keep their
approvals. Ctrl-Q detaches
the TUI; the agent remains on the host. You can use that TUI in a cmux terminal.
To view a remote session as a native cmux NEXT chat tab, select a local pane,
wait for the app's peer inventory to load, and run:

```sh
cmux agent open-tab api-work --host my-linux --focus
```

The tab binds to the peer session mirrored by your Mac's daemon. If the name is
ambiguous, use its session ID from `acpmux ls --json`. This does not move the
agent. For remote chat placement in local sidebar groups, see the
[acpmux peer guide](../cmux-tui/crates/acpmux/README.md#peers-every-session-on-every-machine-from-one-mac).
The generic action form also accepts the peer host:

```sh
cmux action run agent.openSessionTab --target PANE --session api-work --host my-linux
```

To create a remote chat inside a sidebar workspace group on the Mac where you
run the command:

```sh
acpmux new --host my-linux -m codex --group "Remote demo" -d "say hi"
```

`--group` runs the local `cmux agent open` using the returned session ID. The
workspace belongs to your Mac; the agent and its files stay on the peer. It
joins a suitable group of that name or creates one. Opening the workspace may
move focus.
Use `--name api-work --reuse` to rerun a launch without creating another
session. Without `--name`, each invocation creates a new session and row.

If opening the sidebar fails, the session still runs and the warning gives a
`cmux agent open ID --name ... --key ... --group ...` command to retry on your
Mac. Run it with the CLI bundled with that Mac's app and the same local acpmux
daemon that mirrors the peer. For wrappers that run acpmux **on the remote
host**, omit `--group` there and open the returned session ID on the controller
Mac after creation. Passing a peer name as `agent open --host` is not needed
for an ID already mirrored locally.

To end the current turn, stop the agent, or continue a saved session:

```sh
acpmux session cancel my-linux/api-work
acpmux session stop my-linux/api-work
acpmux send my-linux/api-work "Continue from the saved conversation."
```

Stop preserves the session log. Adding `--purge` deletes it; do not use purge
to repair a connection. Closing an app tab closes a viewer. `session resume`
resumes held queued prompts; it is not a machine-resume command.

Durable one-shot wake subscriptions use the local socket methods `_acpmux/watch_add`,
`_acpmux/watch_ls`, and `_acpmux/watch_rm` (`durable-watches-v1`). Add takes `to`, nonempty
local or `HOST/name` sessions, `until`, optional `match`, and `once: true`; it delivers batched
messages with excerpts and inspection commands. State and undelivered messages survive restart;
offline peers notify once, failed deliveries retry, and a one-shot watch is removed after delivery.
Unreadable state is quarantined as `watches.json.bad-<timestamp>`; older cursors default safely; peer replay uses eight workers. The CLI and MCP tools are follow-ups; `acpmux wait` remains the
script interface.

### Read-only Codex reviews

A Codex review that only reads can start without your approval. On the host
itself (its unix socket) start it in `read-only` or `ask`:

```sh
acpmux new -m codex --mode read-only --policy deny-all -n review -d "Review lane/my-fix"
```

From your machine, start it on an enrolled peer with policy `deny-all`:

```sh
acpmux new --host my-linux -m codex --policy deny-all -n review -d "Review lane/my-fix"
```

The peer settles that session in the Codex bridge's `read-only` mode. Commands
run without asking inside a read-only sandbox with no network, and every
request to escalate out of the sandbox is refused. A start from the Web, from a
paired device, or from an origin the host does not know stays in `ask`, where
`deny-all` refuses every command.

A read-only session can read any file the sandbox allows, and its transcript
goes back to whoever started it. Do not start one where it could read secrets
you would not hand to that person.

Codex's own rules on the host still apply in every mode. A command that a rule
in `~/.codex/rules` explicitly allows, such as a prefix someone once approved
with "always allow", runs without asking. In `ask` it runs outside the sandbox;
in `read-only` it stays inside the read-only sandbox.

## Use cmux Cloud

Open cmux NEXT and sign into your account/team. Cloud operations require the
account's access and entitlement. Creation may require confirmation in the app.
Cloud manages its guest software; do not run standalone acpmux host setup or
update against a managed Cloud machine.

The live action catalog is the command reference. Some app actions print only
general help when passed `--help`, so inspect the catalog as well:

```sh
cmux action list --category cloud --json
cmux action describe cloudPauseMachine --json
cmux machine list
cmux cloud new-machine
```

Use an ID from the machine list to select the machine explicitly:

```sh
cmux cloud machine-status --target machine:MACHINE_ID
cmux cloud ssh --target machine:MACHINE_ID
cmux cloud setup-github --target machine:MACHINE_ID
cmux cloud pause-machine --target machine:MACHINE_ID
cmux cloud resume-machine --target machine:MACHINE_ID
cmux cloud exec --target machine:MACHINE_ID --command 'uname -a'
```

`cloud ssh` opens a terminal in the app. It does not attach the invoking CLI's
stdin/stdout to SSH. Pause and resume act on the whole machine and initiate
asynchronous work; check machine status before assuming the operation finished.
Pausing stops computation, including every agent on that machine. Resuming can
require network and provider connections to be established again.

The catalog also exposes file access, for example:

```sh
cmux cloud file-read --target machine:MACHINE_ID --path /workspace/README.md
```

`cloud exec` runs one command through the Cloud API and returns `exit_code`,
`stdout` and `stderr`; pass the command with `--command`.

File access is not automatic transcript backup or history hydration. Do not
assume a particular no-wake behavior from the existence of this command.
The `cloud new-machine`, `pause-machine` and `resume-machine` names above are
the current app actions; old `cmux vm` examples are not interchangeable with them.

## Persistence and reconnect

The execution host owns the acpmux journal and the harness's native resume
files. In the default local store, acpmux keeps session metadata and numbered
event segments under `~/.acpmux/sessions`; an app or `ACPMUX_HOME` can select a
different home. If you deliberately run an isolated standalone daemon from
inside an agent session, unset the inherited `ACPMUX_SOCKET` before setting
`ACPMUX_HOME`; otherwise commands can still target the enclosing session's
daemon. Check `acpmux daemon status` for the actual socket and home before
starting or stopping it. The checkout, harness login and native state must also remain
available to resume execution.

An SSH drop or app restart normally leaves remote work running. A daemon
restart can adopt surviving agent-host processes; otherwise the next prompt
attempts native harness resume. If native loading fails, transcript rehydration
may preserve conversation without preserving tool execution state. Abrupt host
or disk loss is not equivalent to a daemon restart and can lose unsynced data.

The app fetches a bounded history page and streams new events. On reconnect it
uses event sequence numbers to fetch missed history and deduplicate replay.
Previously viewed transcript tails can paint immediately, but the current app
cache is memory-only and disappears on quit. It is not an offline backup; a
failed attach can discard a cached tail. A peer's stale session listing is also
not a complete copy of its transcript.

## Diagnose a problem

| Symptom | Start here |
| --- | --- |
| Remote sessions unreachable | `acpmux host ls`, then `acpmux host doctor my-linux --json`; a peer-unreachable error says the prompt was not submitted and gives `acpmux host ls` as the retry check. Resume a paused machine before expecting live agent traffic. |
| Daemon missing | On its host, `acpmux daemon status`, then `acpmux daemon start` for a standalone daemon. For a service-managed daemon, inspect that service and its configured home/listener. |
| Another service owns the socket | Use the CLI from the running app and record its socket/holder error. Do not delete a live socket or terminate an unknown process. |
| Harness fails to start | `acpmux daemon harnesses`; verify that host's harness installation/login. `acpmux harness doctor codex` performs a handshake and a real prompt, which can consume usage. |
| Stuck or stale chat | `acpmux session info my-linux/api-work` and `acpmux session tail my-linux/api-work`. Restore connectivity before interpreting stale state; cancel/stop only the intended session. |
| Cloud action unavailable | Inspect `cmux action describe cloudPauseMachine --json`, account/team access and the explicit machine target. A command being listed does not mean its current context is eligible. |

Enroll preserves an existing peer URL and listener port. If the remote daemon
already listens on a non-default port, pass that URL to `host add` or let
`host enroll` find the saved peer; it will not restart the daemon on 47811 or
change its listener. A restart can briefly show `reconnecting`; check
`acpmux host ls`, then re-add the same `ssh://HOST:PORT` URL if needed.

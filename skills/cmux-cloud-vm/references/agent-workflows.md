# Agent workflows on cmux Cloud machines

Use the matching recipe after target and capacity authorization in [the skill](../SKILL.md).

The Mac-side `cmux vm` verbs these recipes used (route, run, exec, agent, dev, push,
pull, tree, open, fork with flags, `cloud domains`) were removed with the Swift CLI.
Every recipe below starts a terminal on the machine through the app, then works
inside the machine with its own `cmux`.

## 0. Get a terminal on the machine

```bash
cmux action list --category cloud --available
cmux cloud open-machine --target machine:vm-…              # a shell on the machine
cmux cloud new-terminal-on-machine --target machine:vm-…   # another terminal there
```

Creating a machine (`cmux cloud new-machine`) opens the app's sheet and needs the
user's authorization. Prefer an existing machine and another workspace on it.

Everything after this runs in that machine terminal.

## 1. Set up a project workspace

```bash
cmux env set --from-file .env.cloud               # secrets stay on the machine, out of the layout
cat > /tmp/app-layout.json <<'JSON'
{"name":"app","cwd":"work/app","layout":{"direction":"horizontal","split":0.6,"children":[
  {"pane":{"surfaces":[{"type":"terminal","name":"claude","command":"claude"}]}},
  {"pane":{"surfaces":[{"type":"terminal","name":"dev","command":"bun run dev"},{"type":"browser","url":"http://localhost:3000"}]}}]}}
JSON
cmux layout apply --name app /tmp/app-layout.json --json
cmux terminal list
cmux terminal term_… screen wait --pattern 'localhost:3000' --timeout-ms 120000
cmux notify --title "Workspace ready: app" --body "open the app workspace on this machine"
```

`cmux layout export --workspace <ws>` prints the same document for reuse. `layout apply`
builds a new or empty workspace; it does not rearrange an occupied one.

Getting code onto the machine has no cmux verb now: clone on the machine
(`git clone https://github.com/org/repo work/repo`) or use git over its own
credentials. `vm push` and `git bundle` transfer through cmux were removed.

## 2. Run a command or agent and read the result

```bash
cmux workspace current run --name tests -- sh -c 'cd work/app && make test'
cmux terminal list                                      # find the new term_… id
cmux terminal term_… process wait --timeout-ms 900000   # exits 1 on timeout
cmux terminal term_… output read > test.log             # the full output, not just the screen
```

`process wait` returns the exit status. Report the real outcome from it and the log;
a finished wait is not a passed test. `cmux agent claude --timeout 600 "fix the tests"`
runs an agent in the calling terminal until it exits (guest adapter verb).

## 3. Drive an interactive program headlessly

```bash
cmux terminal term_… write --text $'run the failing test again\n'
cmux terminal term_… screen wait --pattern 'passed|failed' --timeout-ms 300000
cmux terminal term_… screen read
cmux terminal term_… keys ctrl+c
```

No pane is attached and no Mac focus moves. `screen wait` exits 1 on timeout with its
result, so branch on it rather than sleeping.

## 4. Agents on other machines

Inside a machine, `cmux self peers` lists the owner's other machines and their
routes, and `cmux vm ls` lists them where the guest supports it. Peer verbs such as
`vm exec`, `vm terminal …` and `vm push` toward another machine are not available;
open a terminal on that machine from the Mac instead.

### Queue a message into a Codex session

`codex queue` talks to the Codex app-server session store. Run it in a terminal on
the machine that owns the session, as the same user and with that user's original
`CODEX_HOME`; do not run it from a copied home directory. The queue is local to
that app-server instance, so a successful enqueue in another home does not reach
the visible session.

Use the session's exact UUID (or an exact session name) and quote the message:

```bash
codex queue --thread <codex-thread-uuid> --message 'Please re-check the failing test and report the result.'
```

`Queued` only means the app-server accepted an item into its queue database; it
does not mean that the agent has read, started, or completed the message. Verify
delivery by inspecting the target session's next turn and visible terminal state
(`cmux terminal term_… screen read` or `output read`). If the target is busy, the
message waits for the session's queue semantics rather than interrupting an
in-flight turn. If the target thread is not loaded, the message remains queued
until you open or resume that thread.

Do not copy `CODEX_HOME`, manually edit `queue_*.sqlite`, or treat a copied
database's `Queued` response as delivery evidence. Those operations enqueue for
the copy only and can race the app-server's writer. If the local control socket
is inaccessible (for example, a cloud container may report `Operation not
permitted` for `/home/<user>/.codex/app-server-control/app-server-control.sock`),
type into the session's terminal instead:

```bash
cmux terminal term_… write --text $'Continue with the next step.\n'
cmux terminal term_… screen read
```

When a remote app-server endpoint is intentionally exposed, use the installed
CLI's `--remote <wss://…>` together with `--remote-auth-token-env <ENV_VAR>` and
the endpoint's authenticated token. Do not put an app-server token in a terminal
command, prompt, or repository file. Use `ws://` only for loopback endpoints.

## 5. Checkpoints and forks

```bash
cmux cloud snapshot-machine --target machine:vm-…
cmux cloud fork-machine --target machine:vm-…
cmux cloud restore-machine --target machine:vm-… --snapshot <snapshot-id>
```

These drive the app's actions and need authorization. Naming a fork at creation,
`--detach`, and JSON output of the new machine id were removed with `vm fork`.

## 6. Desktop, browser and services

Shells on desktop machines get `DISPLAY=:1`. Drive the desktop from inside the
machine (for example `DISPLAY=:1 xdotool key ctrl+l`). `vm open <id>:desktop`,
`vm open <id>:port/<n>` and `cloud domains publish|verify|access|rm` were removed;
`cmux cloud machine-ports --target machine:vm-…` shows the ports in the app and
`cmux cloud copy-machine-link --target machine:vm-… --port 3000` copies a private
preview link. Publishing a public HTTPS domain has no CLI path now.

## 7. Showing the human

```bash
cmux cloud open-machine --target machine:vm-…
cmux notify --title "Review ready" --body "tests tab has the results"
```

`cmux notify` from a machine terminal appears on the Mac pane that shows that
terminal. `cmux cloud hand-off-machine --target machine:vm-…` shows the app's handoff
details.

## 8. Cleanup etiquette

- Leaving a machine running for the user to inspect is fine; say so in your handoff.
- `cmux terminal term_… close` ends a terminal; `cmux workspace ws_… close` closes a
  workspace. Limit these to resources created for this task.
- Never run `cmux cloud kill-machine` on a machine you didn't create without explicit
  user confirmation.

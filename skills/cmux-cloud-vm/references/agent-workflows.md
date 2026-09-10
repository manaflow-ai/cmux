# Agent workflows on cmux Cloud machines

Recipes for doing the user's work *on* a machine while keeping the user in the loop. All of them assume `cmux auth status` reports signed-in.

## 0. Decide and route (every task starts here)

```bash
cmux vm route --json                  # {machine, created, reason, would_provision}
cmux vm tree                          # what is already running where (terminals, agents, open panes)
```

- Reuse the routed machine when `would_provision` is false — its checkout and deps are warm.
- `would_provision: true` means a new machine slot; check `cmux vm ls` (plan meter, free window) and prefer Base or an idle machine before creating.
- Long-running or interactive work → `vm agent` / a session terminal, not `exec`.

## 1. Cloud dev box from the local repo ("set it up like magic")

One verb does the whole thing when the project has a recognizable dev command:

```bash
cmux vm dev <id>                       # route → optional push → detect command/port → layout apply --name → open geometry on the Mac
cmux vm dev <id> --port 3000 --name app   # override the detected port and workspace name
cmux vm dev <id> --no-open                # stage the workspace; print `vm workspace open` instead of opening a local pane
cmux vm dev <id> --dry-run --json         # inspect the plan without socket traffic
cmux vm push <id> . work/app --watch   # in a second terminal: keep the machine in sync while you edit locally
```

By hand, the same steps as separate primitives (use these when the dev command needs a pidfile, a database, or a seed step). For a layout, use `vm layout apply --name`; do not create a starter-shell workspace with `vm workspace new --no-open` and then expect it to be empty:

```bash
cmux vm run --sync -- bun install                                # --sync runs inside the synced work/<dir>
# idempotent dev server with a workspace-scoped pidfile/log
cmux vm run --sync -- sh -c 'pid=$(cat .cmux-dev.pid 2>/dev/null); if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && netstat -tlnp 2>/dev/null | grep -q ":3000 .*[ /]$pid/"; then echo "dev server already up (pid $pid owns :3000)"; else rm -f .cmux-dev.pid .cmux-dev.log; if netstat -tln 2>/dev/null | grep -q ":3000 "; then echo "port 3000 is owned by another process" >&2; exit 1; fi; nohup bun run dev > .cmux-dev.log 2>&1 & echo $! > .cmux-dev.pid; fi'
cmux vm run --sync -- sh -c 'for i in $(seq 1 60); do wget -qO- http://localhost:3000 >/dev/null 2>&1 && exit 0; sleep 1; done; tail -n 20 .cmux-dev.log; exit 1'
id=$(cmux vm route --json | jq -r '.machine')                    # the machine the router bound
cmux vm open "$id":port/3000 --print                             # tokened URL to give the user
```

Sticky binding means every `vm run` from this directory lands on the same machine. The explicit reuse-or-create spelling still works when you want full control:

```bash
id=$(cmux vm ls --json | jq -r '[.vms[] | select(.displayName == "agent-pool" and (.status | test("^(running|ready|standby|paused)$")))][0].id // empty')
[ -n "$id" ] || id=$(cmux vm new --base --detach --json | jq -r '.id')
cmux vm wait "$id" --wake
cmux vm push "$id" . work/app
cmux vm exec "$id" -- sh -c 'cd work/app && bun install'
```

Finish with `cmux notify --title "Cloud dev server up" --body "<url>"`.

## 1b. Stage a finished workspace for the human (layout + env + code)

The person wants to open one workspace and find everything in place: the checkout, the secrets, an agent pane, a test watcher, the app in a browser pane. Build it headlessly, verify, then open.

```bash
id=$(cmux vm route --json | jq -r '.machine')
cmux vm push "$id" . work/app                                         # code (or a git bundle, §3)
cmux vm env set "$id" --from-file .env.cloud                          # secrets: on the machine, never in the layout
cat > /tmp/app-layout.json <<'JSON'
{"name":"app","cwd":"work/app","layout":{"direction":"horizontal","split":0.6,"children":[
  {"pane":{"surfaces":[{"type":"terminal","name":"claude","command":"claude","focus":true}]}},
  {"direction":"vertical","split":0.5,"children":[
    {"pane":{"surfaces":[{"type":"terminal","name":"tests","command":"bun test --watch"},{"type":"terminal","name":"shell"}]}},
    {"pane":{"surfaces":[{"type":"terminal","name":"dev","command":"bun run dev"},{"type":"browser","url":"http://localhost:3000"}]}}]}]}}
JSON
ws=$(cmux vm layout apply "$id" /tmp/app-layout.json --json | jq -r '.workspace_id')
cmux vm tree "$id"                                                     # the panes exist; agents/tests show their state
cmux vm terminal wait "$id" "$(cmux vm tree "$id" --json | jq -r '.resources[] | select(.title=="dev") | .key')" --pattern 'localhost:3000' --timeout 120
cmux vm workspace open "$id" "$ws"                                     # same geometry on the Mac (or: layout apply … --open)
cmux notify --title "Workspace ready: app" --body "cmux vm open $id/$ws"
```

Reuse a human's arrangement: `cmux vm layout export <id> <ws> > team-layout.json`, commit it next to the repo, and `cmux vm layout apply <fork> team-layout.json` on every fork. A layout the person saved on the Mac (`cmux layout save dev`) applies in the cloud with `--from-saved dev`.

## 2. Hand a task to an agent on the machine

```bash
term=$(cmux vm agent --agent claude --sync --json -- "run the test suite, fix failures, commit on a branch" )
echo "$term" | jq -r '.reattach'                                  # cmux vm open <machine>/<ws>/<term>
cmux vm tree "$(echo "$term" | jq -r '.machine')"                 # [agent claude running] … (open: surface:N)
```

The agent runs as a detached terminal in the machine's cmux-tui session: it keeps going if the pane closes, and `cmux vm open <reattach address>` brings it back (reusing the pane if one already shows it). Fan out by calling `vm agent` once per task with `--machine` pinned to different machines (or forks, §4) and watch them all in `cmux vm tree`.

When you need the result, not the terminal, block until the agent is done and take its output in one call:

```bash
cmux vm agent --agent claude --machine <id> --sync --wait --output --timeout 1800 -- "run the suite, fix failures, commit on a branch" > agent.log; echo "exit=$?"
# fan-out: start each without --wait, then wait on the terminals
for t in $t1 $t2 $t3; do cmux vm terminal wait-exit <id> "$t" --timeout 1800; cmux vm terminal output <id> "$t" > "$t.log"; done
```

`--wait` polls the process (Ctrl-C stops your wait, not the agent), `--output` pages the full scrollback after exit, and the agent's exit code becomes yours (1 on a timeout or signal, with a line saying which).

Inside the machine the agent authenticates like it would locally (its own login, or CodeRouter's env/config under `/root`, set once with `vm exec`). Never copy the user's tokens onto a machine unless they ask.

## 2b. Agents talking to agents (same machine, and across machines)

On one machine, an agent drives a sibling terminal headlessly — from the Mac or from inside the machine with the same verbs:

```bash
# from the Mac
cmux vm terminal send <id> <term> 'run the failing test again' --keys enter
cmux vm terminal wait <id> <term> --pattern '❯|\$ $' --timeout 600 && cmux vm terminal read <id> <term>
# from inside the machine (an agent's own hooks/scripts); default target = its own terminal
cmux send-key --terminal <term> enter
cmux terminal read <term>
```

Across machines, an existing peer route lets the source machine speak to the peer with the Mac grammar. This build cannot create new peer grants:

```bash
# inside <builder>:
cmux vm agent reviewer --agent codex --name "review" --cwd work/app -- "review the diff on branch feat/x and write REVIEW.md"
cmux vm terminal wait-exit reviewer <term> --timeout 1800                     # the agent's process ended
cmux vm terminal output reviewer <term> | tail -n 40                          # what it said
cmux vm exec reviewer -- cat work/app/REVIEW.md
cmux vm env set reviewer GITHUB_REPO=org/app                       # settings for the peer's shells
cmux vm push reviewer ./deploy_key ~/.ssh/deploy_key --mode 600    # one file over the link into the peer's `cmux file receive`; never through exec
cmux vm agent reviewer --agent codex --wait --output -- "summarize REVIEW.md in three lines"   # until-done on the peer
cmux vm layout apply reviewer review-layout.json --name review     # a workspace on the peer, ready for the human
```

A machine never holds a control-plane credential and can reach only its previously configured peers. The earlier Mac enrollment broker is no longer implemented.

## 3. Repo with history (private repos, no credentials on the machine)

```bash
git bundle create /tmp/repo.bundle --all
cmux vm push <id> /tmp/repo.bundle work/repo.bundle
cmux vm exec <id> -- sh -c 'cd work && git clone repo.bundle app && cd app && git checkout main'
```

Public repos can just clone on the machine: `cmux vm exec <id> -- git clone https://github.com/org/repo work/repo`.

## 4. Builds and tests in the cloud instead of the local Mac

```bash
t=$(cmux surface new-terminal --machine <id> --no-open --json -- sh -c 'cd work/app && make test' | jq -r .terminal_id)
cmux vm terminal wait-exit <id> "$t" --timeout 900        # exited code=<n> | exited signal=<s> | pending (exit 1)
cmux vm terminal output <id> "$t" > test.log              # everything the run printed, not just the visible screen
cmux vm pull <id> work/app/dist ./dist-from-cloud
```

A durable terminal outlives the CLI call and the Mac; `wait-exit` returns the exit code and `output` the full log (`--json` gives `next_offset`, so a long run can be read incrementally with `--after`). For a quick command that finishes in seconds, `cmux vm exec <id> --timeout 300 -- <cmd>` is enough. Report the real outcome from the exit code and the log — a finished wait is not a passed test.

## 5. Parallel experiments with checkpoints and forks

```bash
cmux vm snapshot <id> --name pre-experiment
fork_a=$(cmux vm fork <id> --name try-approach-a --detach --json | jq -r '.id')
fork_b=$(cmux vm fork <id> --name try-approach-b --detach --json | jq -r '.id')
cmux vm agent --agent codex --machine "$fork_a" --no-open -- exec "try approach A in work/app"
cmux vm agent --agent codex --machine "$fork_b" --no-open -- exec "try approach B in work/app"
cmux vm tree                                           # both agents, side by side
cmux vm rm "$fork_a"; cmux vm rm "$fork_b"             # only the forks you created
```

## 6. Desktop and browser tasks

Desktop machines run xfce + TigerVNC + noVNC and the CUA driver (`cua-computer-server`, the computer-use API that screenshots/clicks/types on display `:1`). Drive it from inside the machine (`vm agent` with a computer-use-capable agent, or your own script against the server), and show the human the screen:

```bash
cmux vm open <id>:desktop              # the screen as a browser pane beside the shell
cmux vm exec <id> -- sh -c 'DISPLAY=:1 xdotool key ctrl+l'   # quick desktop pokes
```

## 7. Showing the human

```bash
cmux vm tree <id>                      # the map: which terminal is which, what is already open
cmux vm open <id>/<ws>/<term>          # one terminal as a pane (reuses an open pane)
cmux vm open <id>                      # shell (+ screen on desktop machines)
cmux vm open <id>:desktop              # the screen
cmux vm open <id>:port/3000            # the app they should look at
cmux vm handoff <id>                   # attach block another human/agent can follow
```

Pair with `cmux notify` so they know why a pane appeared. Prefer `--print`/`--detach`/`--no-open` until the moment you intend the user to look; `vm open` never steals focus unless `--focus true`.

## 8. Cleanup etiquette

- New cmux machines have no idle timeout and remain available until explicitly paused or
  stopped. Older/provider-managed machines may still be asleep; opening or running a command
  wakes them, so leaving one for the user to inspect is fine (say so in your handoff).
- Delete forks and scratch machines you created once their purpose is served.
- Never `vm rm` or `vm base reset` a machine you didn't create without explicit user confirmation — both discard data permanently.

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

## 2. Hand a task to an agent on the machine

```bash
term=$(cmux vm agent --agent claude --sync --json -- "run the test suite, fix failures, commit on a branch" )
echo "$term" | jq -r '.reattach'                                  # cmux vm open <machine>/<ws>/<term>
cmux vm tree "$(echo "$term" | jq -r '.machine')"                 # [agent claude running] … (open: surface:N)
```

The agent runs as a detached terminal in the machine's cmux-tui session: it keeps going if the pane closes, and `cmux vm open <reattach address>` brings it back (reusing the pane if one already shows it). Fan out by calling `vm agent` once per task with `--machine` pinned to different machines (or forks, §4) and watch them all in `cmux vm tree`.

Inside the machine the agent authenticates like it would locally (its own login, or CodeRouter's env/config under `/root`, set once with `vm exec`). Never copy the user's tokens onto a machine unless they ask.

## 3. Repo with history (private repos, no credentials on the machine)

```bash
git bundle create /tmp/repo.bundle --all
cmux vm push <id> /tmp/repo.bundle work/repo.bundle
cmux vm exec <id> -- sh -c 'cd work && git clone repo.bundle app && cd app && git checkout main'
```

Public repos can just clone on the machine: `cmux vm exec <id> -- git clone https://github.com/org/repo work/repo`.

## 4. Builds and tests in the cloud instead of the local Mac

```bash
run=test-$(uuidgen | tr 'A-Z' 'a-z' | cut -c1-8)
cmux vm exec <id> -- sh -c "cd work/app && rm -f /tmp/$run.log /tmp/$run.status && nohup sh -c 'make test > /tmp/$run.log 2>&1; echo \$? > /tmp/$run.status.tmp && mv /tmp/$run.status.tmp /tmp/$run.status' >/dev/null 2>&1 &"
cmux vm exec <id> -- sh -c "cat /tmp/$run.status 2>/dev/null || echo running"   # poll; status appears atomically when done
cmux vm exec <id> -- tail -n 30 /tmp/$run.log
cmux vm pull <id> work/app/dist ./dist-from-cloud
```

Report the real outcome from the log — a finished poll is not a passed test.

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

- Machines sleep on their own — idle machines cost nothing while asleep, so leaving one for the user to inspect is fine (say so in your handoff).
- Delete forks and scratch machines you created once their purpose is served.
- Never `vm rm` or `vm base reset` a machine you didn't create without explicit user confirmation — both discard data permanently.

# Agent workflows on cmux Cloud machines

Recipes for doing the user's work *on* a machine while keeping the user in the loop. All of them assume `cmux auth status` reports signed-in.

## 1. Cloud dev box from the local repo ("set it up like magic")

The routed path — no machine id anywhere:

```bash
cmux vm run --sync -- bun install                                # --sync runs the command inside the synced work/<dir>
# idempotent start: reuse a live server on the port, otherwise launch one with a
# workspace-scoped pidfile/log so a later run can tell whose server it is talking to
cmux vm run --sync -- sh -c 'if wget -qO- http://localhost:3000 >/dev/null 2>&1; then echo "dev server already up (pid $(cat .cmux-dev.pid 2>/dev/null))"; else rm -f .cmux-dev.log; nohup bun run dev > .cmux-dev.log 2>&1 & echo $! > .cmux-dev.pid; fi'
# wait for the port, not a fixed delay; fail loudly with this run's log if it never comes up
cmux vm run --sync -- sh -c 'for i in $(seq 1 60); do wget -qO- http://localhost:3000 >/dev/null 2>&1 && exit 0; sleep 1; done; tail -n 20 .cmux-dev.log; exit 1'
id=$(cmux vm run --json -- true | jq -r '.machine')             # the machine the router bound
cmux vm open "$id" 3000 --print                                 # tokened URL to give the user
```

Sticky binding means every `vm run` from this directory lands on the same machine, so the synced checkout and installed deps persist between commands. The explicit reuse-or-create spelling still works when you want full control:

```bash
# only a ready machine you set aside for agent work — never the user's own named machines
id=$(cmux vm ls --json | jq -r '[.vms[] | select(.displayName == "agent-pool" and (.status | test("^(running|ready|standby|paused)$")))][0].id // empty')
[ -n "$id" ] || id=$(cmux vm new --base --detach --json | jq -r '.id')
cmux vm wait "$id" --wake
cmux vm push "$id" . work/app
cmux vm exec "$id" -- sh -c 'cd work/app && bun install'
```

Finish with `cmux notify --title "Cloud dev server up" --body "<url>"` so the user can leave and return.

## 2. Repo with history (private repos, no credentials on the machine)

`push` skips `.git` by default. To work with real history without putting the user's tokens on the machine, ship a bundle:

```bash
git bundle create /tmp/repo.bundle --all
cmux vm push <id> /tmp/repo.bundle work/repo.bundle
cmux vm exec <id> -- sh -c 'cd work && git clone repo.bundle app && cd app && git checkout main'
```

Public repos can just clone on the machine: `cmux vm exec <id> -- git clone https://github.com/org/repo work/repo`. Never copy the user's `gh`/git credentials onto a machine unless they explicitly ask.

## 3. Builds and tests in the cloud instead of the local Mac

```bash
# run-scoped paths: a reused machine may hold an older run's log and status
run=test-$(date +%s)
cmux vm exec <id> -- sh -c "cd work/app && rm -f /tmp/$run.log /tmp/$run.status && nohup sh -c 'make test > /tmp/$run.log 2>&1; echo \$? > /tmp/$run.status.tmp && mv /tmp/$run.status.tmp /tmp/$run.status' >/dev/null 2>&1 &"
# poll instead of holding a long exec open: the status file appears (atomically) only
# when this run finishes and holds its exit code, so pass/fail is never ambiguous
cmux vm exec <id> -- sh -c "cat /tmp/$run.status 2>/dev/null || echo running"
cmux vm exec <id> -- tail -n 30 /tmp/$run.log
# bring artifacts home
cmux vm pull <id> work/app/dist ./dist-from-cloud
```

Report the real outcome from the log — a finished poll is not a passed test.

## 4. Parallel experiments with checkpoints and forks

Never experiment on the user's machine state directly:

```bash
cmux vm snapshot <id> --name pre-experiment          # restore point
fork_a=$(cmux vm fork <id> --name try-approach-a --detach --json | jq -r '.id')
fork_b=$(cmux vm fork <id> --name try-approach-b --detach --json | jq -r '.id')
# ...run a different approach on each fork with vm exec...
cmux vm rm "$fork_a"                                  # remove only the forks you created
cmux vm rm "$fork_b"
```

Keep the original machine untouched; summarize what each fork showed before deleting anything.

## 5. Showing the human

The user cannot see exec output. When the work is ready:

```bash
cmux vm shell <id>          # attach a terminal pane in their cmux window
cmux vm desktop <id>        # desktop boxes: stream the machine's screen
cmux vm open <id> 3000      # open the app they should look at as a browser split
cmux vm handoff <id>        # print an attach block another human/agent can follow
```

Pair with `cmux notify` so they know why a pane appeared. Prefer `--print`/`--detach` variants until the moment you intend the user to look.

## 6. Cleanup etiquette

- Machines sleep on their own — idle machines cost nothing while asleep, so leaving a machine for the user to inspect is fine (say so in your handoff).
- Delete forks and scratch machines you created once their purpose is served.
- Never `vm rm` or `vm base reset` a machine you didn't create without explicit user confirmation — both discard data permanently (reset retains the old VM, but treat it as destructive).

# Cloud agent primitives — nightly dogfood checklist

Run this against a nightly (or tagged) build that carries the `freestyle-vm-primitives` +
`freestyle-vm-agent-primitives` stack. Each step names the command, what a pass looks like,
and where to look when it does not. Work top to bottom: later steps assume earlier ones.
Record the build tag, the machine name, and the step number of the first failure.

Conventions: `<m>` is a machine id or name from `cmux vm ls`; `<ws>` a remote workspace id
from `cmux vm tree <m>`; `<t>` a remote terminal id. Everything below also accepts `--json`.
Set `CMUX_TAG` and use `scripts/cmux-debug-cli.sh` when driving a tagged Debug app instead of
the user's main app.

## 0. Preconditions (2 min)

| # | Command | Pass |
|---|---|---|
| 0.1 | `cmux auth status` | signed in; the account that owns the test machines |
| 0.2 | `cmux vpn status` | `up` for this build's enrollment (else `cmux vpn up`) |
| 0.3 | `cmux vm ls` | at least one `running` machine; note its name as `<m>` |
| 0.4 | `cmux vm tree <m> --refresh` | link state `connected`; Workspaces / Terminals sections present |

If 0.4 shows `stale` or the shim predates a verb (`unknown env command`, `unknown resource scope`),
the machine's shim is older than the server: `cmux vm tree <m> --refresh` reinstalls it on reconnect.

## 1. Workspaces and layouts (the sidebar click is the layout)

| # | Command | Pass |
|---|---|---|
| 1.1 | `cmux vm workspace new <m> --name dogfood --no-open` | prints the new `<ws>`; nothing opens locally; sidebar shows the row |
| 1.2 | `cmux vm workspace new <m> --name dogfood --reuse --no-open` | same `<ws>` again with `(existing)`; no second row |
| 1.3 | `cmux vm layout apply <m> --name dogfood-layout - <<'EOF2'`<br>`{"layout":{"direction":"horizontal","split":0.35,"children":[{"pane":{"surfaces":[{"type":"terminal","name":"left","command":"htop"}]}},{"pane":{"surfaces":[{"type":"terminal","name":"shell","focus":true},{"type":"browser","url":"https://example.com"}]}}]}}`<br>`EOF2` | `OK`; two panes reported; use this result's workspace id as `<ws>` below. `--no-open` keeps a starter shell, so the layout needs its own workspace. |
| 1.4 | `cmux vm layout export <m> <ws>` | the same document back: `horizontal`, split ≈ `0.35`, `htop` in the left pane, a browser tab on the right |
| 1.5 | click the `dogfood-layout` row in the Cloud sidebar | a new local workspace with the SAME geometry: narrow left pane (about a third), wide right pane, browser as the second tab, focus in `shell` |
| 1.6 | `cmux vm workspace open <m> <ws>` | identical result to 1.5 (one shared open path) |
| 1.7 | `cmux vm layout apply <m> --name dogfood-2 --open <file>` with the 1.3 document saved to a file | creates and opens with geometry in one step |
| 1.8 | `cmux vm workspace rename <m> <ws> dogfood-renamed` / `cmux vm tab rename <m> <tab-id> <name>` where a tab exists | the sidebar row and tab title change live |
| 1.9 | `cmux vm workspace rm <m> <ws2>` for the 1.7 workspace | row gone; its terminals gone from the Terminals pool |

Failure pointers: geometry ignored → `CloudWorkspaceLayoutTranslator` / `SurfaceProjectionLayout`;
export shape wrong → the shim's `layout export` (`web/services/vms/guestCli.ts`).

## 2. Environment, never through exec

| # | Command | Pass |
|---|---|---|
| 2.1 | `cmux vm env set <m> DOGFOOD_TOKEN=s3cret-$(date +%s) DOGFOOD_URL=https://x.test` | `OK 2 keys → ~/.config/cmux/env` |
| 2.2 | `cmux vm env ls <m>` | both keys, values masked; `--show` reveals |
| 2.3 | `cmux vm exec <m> -- sh -lc 'echo $DOGFOOD_URL'` | `https://x.test` (login shell sourced the file) |
| 2.4 | `cmux vm terminal read <m> <t>` for every terminal in the machine, and `cmux vm terminal output <m> <t>` | the secret value appears NOWHERE in any screen or scrollback |
| 2.5 | `cmux vm exec <m> -- stat -c %a ~/.config/cmux/env` | `600` |
| 2.6 | `cmux vm env rm <m> DOGFOOD_TOKEN` then `env ls` | only `DOGFOOD_URL` remains |
| 2.7 | `cmux vm env set <m> --from-file .env` with a 200-line file | `OK <n> keys`; delivery completes in well under 10 s |
| 2.8 | inside `<m>`: `cmux env set PEER_ONLY=1` then `cmux env ls` | works against the machine's own file |

Failure pointers: a value in scrollback = a regression in `CloudEnvDelivery` (`stty -echo` before READY);
`did not report ready` = an old shim (see 0.4) or the daemon's `--on-exit keep` missing.

## 3. Identity and discovery from inside a machine

Run these in a terminal ON the machine (`cmux vm workspace open <m> <ws>`, or `cmux vm exec <m> -- …`).

| # | Command | Pass |
|---|---|---|
| 3.1 | `cmux self` | `<name>\t<id>\trunning\t(this machine)`, `team`, `owner`, `plan` lines |
| 3.2 | `cmux whoami` and `cmux reflect` | byte-identical to 3.1 |
| 3.3 | `cmux self --json` | includes `schema`, `machine`, `team`, `machines`, `owner`, `urls.reflection`, `paths` |
| 3.4 | `cmux self peers` | every OTHER live machine of the owner with `route: ws://[…]:1337/v1/link` and `reachable: true` |
| 3.5 | `cmux self integrations` | `coderouter`, `claude`, `notify`, `machines`, `env`, `layout`, `reflection`; `display:1` only on desktop images |
| 3.6 | `cmux self owner` / `cmux self machine` | email or user id; size, network ipv4/ipv6, image |
| 3.7 | `cmux self nope` | exit 1 with the `paths` list |
| 3.8 | `curl -sSL https://coderouter.cmux.internal/api/vm/reflection` and `curl -sSL https://reflection.cmux.internal/` | same JSON as 3.3 (the second only on machines provisioned after the alias rule shipped) |
| 3.9 | `cmux vm ls` | the owner's machines, this one marked `*`, peers `reachable` / `linked` / `connected` |
| 3.10 | from the Mac: `cmux vm self <m>` / `cmux vm self <m> peers` | the same reflection payloads through the user session |

Failure pointers: 401 = the edge did not inject the route token (machine predates the model plane);
`reflection unreachable` = the alias host is not routed; peers empty = the other machines have no
recorded ipv6/ipv4 in `providerMetadata`.

## 4. Agent-to-agent (two machines)

Have two running machines `<a>` and `<b>`. Inside `<a>`:

| # | Command | Pass |
|---|---|---|
| 4.1 | `cmux vm exec <b> -- hostname` | `<b>`'s hostname (the link is discovered from `cmux self peers`, no invite) |
| 4.2 | `cmux vm terminal send <b> <t> "echo from-a" --keys enter` then `cmux vm terminal read <b> <t>` | `from-a` on `<b>`'s screen |
| 4.3 | `cmux vm terminal wait <b> <t> --pattern from-a --timeout 5` | exit 0 |
| 4.4 | `cmux vm env set <b> FROM_A=1` then on `<b>`: `cmux env ls` | delivered over the link (check 2.4 there too) |
| 4.5 | `cmux vm push <b> ./secret.pem ~/secret.pem --mode 600` (single file, link only) | `CMUX-FILE-OK`; `stat -c %a` on `<b>` is `600`; bytes identical |
| 4.6 | `cmux vm layout apply <b> --name from-a --open …` is NOT expected to open anything on the Mac | it creates the layout on `<b>` only; the human opens it from the sidebar |
| 4.7 | `cmux notify --title "dogfood" --body "from <a>"` | the Mac shows the notification |

## 5. Running work until done

| # | Command | Pass |
|---|---|---|
| 5.1 | `cmux vm exec --timeout 3 <m> -- sleep 10` | times out at ~3 s with a clear message; `--timeout 20` succeeds |
| 5.2 | `cmux vm terminal wait-exit <m> <t> --timeout 2` on a live shell | `pending`, exit 1 |
| 5.3 | `cmux vm exec <m> -- sh -c 'exit 7'` | exit code 7 propagated |
| 5.4 | `cmux surface new-terminal --machine <m> --no-open -- sh -c 'echo hi; exit 3'` then `cmux vm terminal wait-exit <m> <t>` using the returned terminal id | `exited code=3` |
| 5.5 | `cmux vm terminal output <m> <t>` and again with `--after <next_offset>` | full scrollback, then only the new bytes; `complete: true` |
| 5.6 | `cmux vm agent <m> --agent claude "print the word done and exit" --wait --output --timeout 300` | the agent's output streams back; exit 0; the workspace shows the agent terminal |
| 5.7 | `cmux vm run <m> --wait --output -- sh -c 'echo streamed; exit 0'` | prints `streamed`, exit 0 |
| 5.8 | inside `<m>`: `cmux agent claude --timeout 120 "say ok"` and, from `<a>`: `cmux vm agent <b> --agent claude --wait --output -- "say ok"` | the local form runs in the terminal until it exits; the peer form blocks and prints the output; both pass the exit code through |

## 6. Files

| # | Command | Pass |
|---|---|---|
| 6.1 | `cmux vm push <m> ./proj ~/proj` | file count; `--exclude` and default excludes (`node_modules`, `.git`) honoured |
| 6.2 | `cmux vm push <m> ./proj ~/proj --watch` then edit a file locally | `synced 1 files at HH:MM:SS` within ~1.5 s; Ctrl-C exits 0 |
| 6.3 | `cmux vm push --secret <m> ./id_ed25519 ~/.ssh/id_ed25519` | `delivered over the link`; mode `600`; not visible in any terminal screen; `--secret` with a directory is refused |
| 6.4 | `cmux vm pull <m> ~/proj/out ./out` | bytes identical |

## 7. `cmux vm dev` (folder → running dev layout)

In a folder with a `package.json` whose `dev` script starts a server on a known port:

| # | Command | Pass |
|---|---|---|
| 7.0 | `cmux vm dev <m> --dry-run` | the plan and the exact layout document; no workspace is created (check `cmux vm tree <m>`) |
| 7.1 | `cmux vm dev <m>` | lines: `route ok`, `synced n files → <remote>`, `dev: <pm> run dev (port <n>)`, `workspace <name> (new)`, `layout applied`, `opened locally`, `next: …` |
| 7.2 | look at the opened local workspace | left pane runs the dev command, right pane is a shell, browser tab at `http://localhost:<port>` |
| 7.3 | `cmux vm dev <m>` again | `workspace <name> (existing)`; no duplicate workspace |
| 7.4 | `cmux vm dev <m> --command "make serve" --port 8081 --no-open` | override respected; nothing opens |
| 7.5 | in an empty folder: `cmux vm dev <m>` | shell-only layout and a line saying no dev command was detected |
| 7.6 | `cmux vm open <m> <port> --print` then `cmux vm open <m> <port>` | the private tokened URL prints, then opens as a browser pane |

## 8. Lifecycle

| # | Command | Pass |
|---|---|---|
| 8.1 | `cmux vm pause <m>` | `paused` in `cmux vm ls`; a second `pause` is still 200 |
| 8.2 | `cmux vm resume <m>` | `running`; `cmux vm tree <m> --refresh` reconnects; terminals from §5 still listed |
| 8.3 | `cmux vm snapshot <m> --name dogfood` | snapshot id |
| 8.4 | `cmux vm snapshot ls <m>` then `cmux vm snapshot rm <m> <id>` then `ls` again | the 8.3 snapshot listed with its name, then gone; `cmux vm restore <id>` of the deleted one answers not found |
| 8.5 | `cmux vm fork <m>` and `cmux vm env ls <fork>` | the fork inherits `~/.config/cmux/env` |
| 8.6 | `cmux vm resize <m> --disk 64` | `Unknown vm command` (disk growth is not possible today); the machine's sidebar context menu has no "Increase Disk" item |

## 9. Help and grammar

| # | Command | Pass |
|---|---|---|
| 9.1 | `cmux vm help` | every verb above listed once; no `resize` |
| 9.2 | `cmux vm layout --help`, `cmux vm env --help`, `cmux vm terminal --help`, `cmux vm agent --help`, `cmux vm dev --help` | per-verb usage |
| 9.3 | inside a machine: `cmux --help` | sections THIS MACHINE / WHO AM I / OTHER MACHINES / REACH THE HUMAN / MODELS AND AGENTS / AUTH |
| 9.4 | `cmux vm <verb> --json` for ls, tree, self, terminal output, layout export | valid JSON on stdout only |

## Concurrent preparation and interrupted deletion

Two clients creating the same named workspace use the daemon revision to choose one
creator. `vm dev` also checks the revision before creating the first pane in an empty
workspace. A losing preparation reports a retry error; retrying uses the current
workspace instead of creating another one. `--no-open` still creates a starter shell.

Snapshot deletion records a durable intent before touching the provider. If deletion
or ledger finalization fails, retry `vm snapshot rm`; pending intents block restore.
`vm snapshot ls` repairs finalization for pending snapshots absent from the provider.
A failed deletion that still exists at the provider remains pending until retried.

## Reporting

Paste the table rows that failed with the exact output, the build tag, and the machine's
`cmux self --json` (redact nothing: it contains no secrets). Anything in §2.4 or §6.3 that leaks
a value is a release blocker; everything else is a bug.

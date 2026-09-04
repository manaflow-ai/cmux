# The cloud primitives an agent needs

Status: roadmap. Companion to docs/cloud-project-environments.md (`vm dev`) and
docs/vm-identity-edge-auth.md (machine identity). Maps the product goals to
primitives, marking what already exists on this branch vs. what's next.

The CLI's job: let a **local agent** (Claude Code, Codex, anything with a shell)
manage cloud workspaces as directly as it manages local files — and let the work
keep running when the laptop closes.

## Goal 1 — port work into the cloud

| Primitive | State |
| --- | --- |
| `vm route` / sticky per-directory binding | shipped |
| `vm push` / `vm pull` (chunked, hashed, excludes) | shipped |
| `vm run --sync -- <cmd>` | shipped |
| `vm exec`, `vm terminal send/read/wait` (drive anything headlessly) | shipped |
| `vm dev` (detect/record/replay environment, named workspace) | designed (cloud-project-environments.md) |
| `vm push --watch` (fs-event incremental sync) | next |
| `vm repo clone <url>` (clone *in* the cloud — big repos never transit the Mac; gh auth via edge-injected credentials, never a token in the guest) | next |

## Goal 2 — agents that outlive the laptop

Detached cmux-tui terminals already survive disconnects: `vm agent` starts a
coding agent in the machine's session and it keeps running with the Mac closed.
What completes the story:

- **Notify without a Mac attached** — the notification relay (this branch)
  bubbles in-VM `cmux notify` into the daemon's durable ledger; the Mac drains
  it on reconnect. Next: the control plane forwards ledger events to push
  (iOS/APNs) so "agent finished" reaches a closed laptop.
- **`vm agent --until-done`** — a supervisor terminal that watches the agent's
  exit receipt (`--on-exit keep` receipts are durable) and runs a follow-up
  (notify, push a branch, open a PR) with no Mac in the loop.
- **Scale-out** — `vm run`/`vm agent` already provision pool machines per task;
  `vm fork` clones a warm environment for parallel experiments. Next:
  `vm agent --fan-out N -- <prompt>` = fork × N + one agent each + a summary
  workspace collecting the results.

## Goal 3 — layouts as data

The daemon already treats layout as a resource: `workspace <sel> layout apply`
takes a `LayoutDocument`, and `screen layout export` reads one back. Missing is
only the `cmux vm` plumbing and the projection contract:

```bash
cmux vm layout export <machine> <ws>            # LayoutDocument JSON to stdout
cmux vm layout apply  <machine> <ws> [file|-]   # build panes/splits/tabs from JSON
cmux vm layout apply  <machine> <ws> --preset agent-triage   # named presets
```

- **Author without opening**: an agent composes a LayoutDocument (editor pane
  left, agent terminal right, test-watcher tab, log tail bottom), applies it to
  a cloud workspace, and never projects a pane anywhere.
- **Monitor without opening**: `vm tree --json` / `session snapshot` already
  carry the full topology; `layout export` adds the exact geometry. An agent
  can assert "the test watcher is still in tab 2" headlessly.
- **Click-to-materialize**: `vm workspace open` already builds local panes from
  the machine workspace; it should honor the stored geometry (splits and
  ratios), not just pane-per-terminal — so the layout an agent arranged in the
  cloud is the layout that appears on the Mac. Geometry travels machine→Mac as
  data; nothing in a LayoutDocument can name a Mac surface or socket (same
  boundary the notification relay enforces).

## Goal 4 — everything an agent needs to set up a working environment

The checklist an agent runs through, each item a primitive (not a doc):

1. **Machine**: `vm route`/`vm new --size` (per-size snapshots) — shipped.
2. **Code**: `vm push` (shipped) / `vm repo clone` (next).
3. **Toolchain + deps**: `vm dev` detect→record→replay; devcontainer.json
   honored — designed.
4. **Secrets**: `vm env set` per (user, project), materialized at setup,
   edge-resident later — designed.
5. **Services**: recipe `services` (postgres/redis via the baked docker) with
   health gates — next, part of `vm dev` P2.
6. **Workspace + layout**: named workspace (designed) + `vm layout apply` —
   this doc.
7. **Verification**: recipe `checks` in a durable terminal; the exit receipt is
   the proof the environment works — designed.
8. **Handoff**: `vm handoff` (shipped), `cmux notify` from inside (this
   branch), peer links for multi-machine pipelines (`vm link`, shipped).

## Sequencing

1. `vm layout export/apply` — smallest lift (daemon ops exist), unlocks goal 3.
2. `vm dev` P1 (route+sync+detect+named workspace) — unlocks goal 4 end to end.
3. `vm push --watch`, `vm repo clone`, recipe `services`.
4. Push-notification forwarding for the ledger; `vm agent --until-done`,
   `--fan-out`.

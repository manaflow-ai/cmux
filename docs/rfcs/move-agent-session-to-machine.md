# Move agent session to machine

Status: Draft

One action in the Mac app takes a Claude or Codex session, with its data, from
machine A to machine B and resumes it there. A and B are any of: this Mac,
another Mac, a BYO Linux host, a cmux Cloud VM. The workspace stays in the Mac
sidebar and keeps driving the session.

Context: [cmuxterm-hq#748](https://github.com/manaflow-ai/cmuxterm-hq/issues/748)
(runtime pieces) and
[Leo's comment on it](https://github.com/manaflow-ai/cmuxterm-hq/issues/748#issuecomment-5847022336)
(what running Claude on a user-owned host from the Mac needs).
[#13305](https://github.com/manaflow-ai/cmux/issues/13305) makes a runtime
durable above its machine; [#13321](https://github.com/manaflow-ai/cmux/issues/13321)
is the elastic worker plane. This RFC is the concrete cross-machine case of
Phase 4 in [agent-runtime-handoff-and-routing.md](agent-runtime-handoff-and-routing.md).

## Prototype

`~/.local/bin/big-red-claude move|back <session-id>` moves Leo's `sr claude
proxy` sessions between Air Blue (Mac) and big-red (Linux) and resumes them in
cmux. It works today. In order:

1. **Stop at a turn boundary, single writer.** Refuse if the session process
   is still alive on either side. The user `/exit`s first.
2. **Carry code state** of the cwd's git checkout:
   - push HEAD to `refs/agent-move/<id>` on the destination over a direct
     SSH link;
   - check out the same branch name there, or detached if the branch is
     missing;
   - rsync modified and untracked (non-ignored) files, then apply deletions;
   - refuse if the destination has its own uncommitted work on another commit,
     or its branch has commits not in the source HEAD;
   - if the destination has no checkout at that path but has the repo, add a
     worktree.
3. **Carry session data:**
   - `~/.claude/projects/<slug>/<id>.jsonl` (transcript);
   - `<slug>/<id>/` (subagents, tool results);
   - `~/.claude/file-history/<id>` (rewind snapshots);
   - `<slug>/memory/`, merged both ways, newest wins, nothing deleted.
4. **Resume with the recorded launcher** (`sr claude proxy --account X
   --resume <id>`) in a persistent tmux session via
   `cmux mosh-tmux <host> --session cc-<name> --command ...`, so the agent
   outlives the Mac link and cmux reattaches on reconnect.

### Identical absolute paths

big-red bind-mounts `/home/leo` at `/Users/leoli`. With identical absolute
paths on both machines, nothing is rewritten:

- the transcript slug is unchanged (`-Users-leoli-Projects-cmux`);
- the recorded `cwd` in the jsonl is valid;
- the auto-memory dir, keyed by the same slug, is found;
- absolute paths inside tool calls and tool results still resolve.

A symlink does not work. Claude resolves the cwd with realpath, so
`/Users/leoli -> /home/leo` yields the slug `-home-leo-...` and a different
memory dir. A bind mount keeps the path real. Without the mount the prototype
rewrites the home prefix and re-slugs; that path works but leaves stale
absolute paths in the transcript that the model then repeats.

## Design

### Machine field per workspace

No new model. The Mac already has `SurfaceMachineID` (`.local`, `.cloud(id)`,
`.ssh(hash)`, `.device(instance)`), and Hive already has
`cloud_runtimes.machine_id` + `placement_generation`
(`web/services/vms/runtimeRegistry.ts`).

- **Mac.** A workspace gets a persisted `agentMachine: SurfaceMachineID`.
  Today placement exists only as `.ssh(hash)` derived from SSH arguments.
  BYO hosts need a stable registered id rather than an argv hash, so
  `.ssh` becomes a lookup key for a registered machine record (host, user,
  transport, home path).
- **Hive.** The workspace's agent is a runtime row. A move is a placement
  change: `machine_id` set to B, `placement_generation` incremented. Today
  `machine_id` references `cloud_vms` only; it widens to a machines table
  where Cloud VM, BYO host, and Mac are kinds.
- **Session record.** Per workspace, cmux stores
  `{machine, cwd, launcher argv, provider, session id}`. The launcher is the
  argv that exec'd the agent (`sr claude proxy --account X`, `cr`, `claude`).
  `AgentResumeArgv.launcherResolution` knows only `claude-teams`, `omo`,
  `omx`, `omc` today, and remote workspaces skip argv restore. Both change so
  resume replays the recorded launcher on the recorded machine.

### Placement default

One setting: "new agent workspaces run on `<machine>`". Resolution order:

1. per-workspace override;
2. per project;
3. per user;
4. team default;
5. `local`.

The Cmd+N and sidebar "new workspace here" paths read it. Cloud onboarding uses
the same setting to choose between local, BYO host, and Cloud VM.

### The move action

Driven from the Mac (sidebar context menu, `cmux session move <id> --to
<machine>`):

1. **Quiesce.** Wait for the agent's Stop hook (turn complete), then end the
   process on A. If the agent is mid-turn, the action waits; it never
   snapshots a live writer.
2. **Fence.** Take the write lease for the session at generation N+1 (below).
   A's copy becomes read-only.
3. **Carry code.** As in the prototype. A refusal aborts the move before any
   session data changes, and A keeps the lease.
4. **Carry session data.** Replicate the transcript tail, sidecar dir,
   file-history, and memory dir to B.
5. **Resume.** Start the recorded launcher with `--resume <id>` (Claude) or
   `codex resume <id>` in a persistent tmux on B, attached to the same
   workspace.
6. **Commit.** On the agent's first hook event from B, the workspace's
   `agentMachine` becomes B. If B fails to start, the lease returns to A at
   N+2 and the workspace resumes there.

Step 1 and step 6 need hook events from remote agents. `cmux ssh` has no hook
channel today and the remote CLI has no `claude-hook` verb (Leo's comment,
first gap). That hook path is a prerequisite, and the same one serves Cloud
VM agent status.

### Paths on every machine

Every machine an agent can land on exposes the user's home at the same absolute
path as the user's Mac: bind mount on Linux (BYO and Cloud VM image), the real
path on a Mac. The Cloud VM image does this at boot from the user's registered
home path. Re-slugging stays as the fallback for hosts where the mount is not
possible; the UI marks those moves as "paths rewritten".

### Transcript replication

Claude transcripts and Codex rollouts
(`~/.codex/sessions/YYYY/MM/DD/rollout-*-<id>.jsonl`) are append-only jsonl.
That shape decides the design:

- **Read everywhere.** Each machine tails its transcripts and ships appended
  bytes by `(session id, byte offset, hash of the prefix)` to the other
  machines of the same user, through `vault/` (cmux-vault, currently a stub)
  or directly over the machine link. Every machine then holds a copy of every
  session for search, sidebar history, and fast moves: a move only ships the
  tail since the last replication.
- **Write in one place.** Resume and append require the lease. The lease is
  the runtime's `placement_generation`. A machine without the current
  generation refuses to start `--resume` on that session. A replica whose
  prefix hash diverges from the lease holder's is a fork and is kept under a
  new session id, never merged.

Why not iCloud Drive, Google Drive, Dropbox, or a shared network filesystem for
the live files:

- they sync whole files and resolve concurrent edits by last writer or by
  conflict copies, so two appenders produce a lost tail or a forked file;
- iCloud and Drive evict files to placeholders, so a resume can read a
  dataless file;
- NFS and SMB have no fencing the agent respects. Claude does not lock the
  jsonl, and a network round trip on every append slows every turn;
- none of them carries a generation, so a stale machine can resume and
  append after the move.

They are fine for cold archives. They are wrong for the file a live agent
appends to.

### Code state

Code moves as in the prototype, via git over the machine link:

- `refs/agent-move/<id>` for commits;
- the file list from `git diff --name-only HEAD` plus
  `git ls-files -o --exclude-standard` for working changes;
- explicit deletions;
- refuse on dirty or diverged destinations.

Ignored files (build output, `node_modules`) do not move; B rebuilds them. A
cwd that is not a git checkout moves no files, and the action says so. The ref
is kept after the move, so `back` can fetch it and nothing is lost if B's
checkout is later reset.

### Model and credential route follow placement

The prototype tunnels big-red's model traffic back through the Mac
(`ssh -R 31415` to the Mac's subrouter). That breaks when the Mac sleeps and
puts the Mac on the data path. Instead, the route is resolved for the
placement at resume time:

- **BYO host and Mac:** subrouter team mode. The host leases a short-lived
  access token (`docs/local-egress.md` in manaflow-ai/subrouter) and sends
  from its own IP. No tunnel, no pool host on the path.
- **Cloud VM:** coderouter with a `crk_` key, as today.

The recorded launcher carries the account, not the transport, so the same
`sr claude proxy --account X` resolves to the right route on each machine.
Launchers strip `*_API_KEY` from the environment so a subscription agent
cannot silently fall back to API billing.

### Cloud VM is just another machine

A Cloud VM is a machine record of kind `cloud` with:

- the same home path mount;
- the same tmux persistence;
- the same hook channel;
- a coderouter route.

"Move to Cloud" is the move action with provisioning (or waking a paused VM)
before step 3. Nothing else differs. A Cloud VM that is paused keeps its
replicated transcripts; waking it is a resume, not a restore.

## Not in scope

- Moving a session mid-turn or live-migrating the process.
- Two machines appending to one session. Branching from one is a fork with a
  new id.
- Carrying ignored build state or caches.
- Choosing the machine link transport for BYO hosts (cmuxterm-hq#748 §4 item
  4). This RFC needs SSH-reachable hosts plus the hook channel, whichever link
  wins.

# Subagents run in the cloud (a242, 2026-10-20)

Ask (user, Oct 20): "why is there a 40 limit? also is cloud done yet? we need to
scale infinitely". The cap existed because about 188 subagents on the laptop
drove its load to about 67 (a230: each runs git fetch/rebase/push, the pre-push
gate and bun/go tests locally). The goal: a subagent does not run on the
laptop, so its number is limited by VMs, not by the Mac.

## Decision: a cloud subagent is an acpmux peer session

acpmux already runs sessions on other machines: `acpmux host add NAME URL`
adds a peer, and `session/new` with `_meta.acpmux.peer = NAME` creates the
session there (the CLI's `acpmux new --host`). The local daemon relays the
peer's session, so everything the Chief host does with a session (prompt,
events, tell/steer, cancel, the chat tab in its cmux workspace) works without
new protocol. A second transport (SSH exec, the Freestyle exec API, a hub
queue) would duplicate that relay.

So:

| Piece | Where |
|---|---|
| Placement | `OPTCHAT_SUBAGENT_PEER=<peer>` on the Chief host. Set: every new subagent session is created on that peer. Unset: local, as before. |
| Remote folder | `OPTCHAT_SUBAGENT_PEER_DIR` (default `/home/agent/work`). Each subagent makes its own worktree under it from the VM's clones (`~/src/<repo>`); its first message says how. A Mac path in `spawn(cwd)` is mapped to its repo name. |
| Harness | `OPTCHAT_SUBAGENT_PEER_HARNESS` (default `claude`): the peer's own profile. The VM's Claude Code goes through sr2 (`ANTHROPIC_BASE_URL`), no personal login. |
| Instructions | Local presets do not exist on the peer, so the subagent system text goes in front of its first message. |
| Cap | `OPTCHAT_MAX_LIVE_SUBAGENTS` and `control cap` count local subagents only. A cloud subagent never queues and never takes a local slot. |
| Record | `SubRecord.peer` keeps where it runs (state.json), so the count holds across a host restart. |
| Workspace | Same as local: a cmux workspace whose tab is its chat (the local acpmux relays the peer session). |
| Mac builds | The VM is on `tag:agent-cloud`, which reaches the fleet controller (`cmux-ci`) and sr2 only. |
| Push | The VM pushes to GitHub with its own credential (see "Credentials"). |

## VM pool (cmuxterm-hq `tools/cloud-subagents`)

`deploy.sh up` makes one Freestyle VM `chief-subagents-N` on the HQ Freestyle
key (infrastructure, like `cloud-chief`; tenant workloads use the cmux Cloud VM
API instead, see `plans/freestyle-tenant-DESIGN.md`):

- tailnet node on `tag:agent-cloud` (one single-use key from tsadmin): reaches
  sr2 :4016 and the controller :18765. lawbook0 reaches every port of the tag
  already, so no ACL change.
- user `agent` (no sudo): Claude Code on sr2, Linux acpmux and cmux-tui from
  the same feat-cmux-next build as Cloud Chief, `acpmux daemon run`
  (systemd `chief-subagents-acpmux`).
- blobless clones of cmux and cmuxterm-hq in `~/src`, worktrees in `~/work`.
- the Mac adds it as a peer over Tailscale SSH: `acpmux host add cloud1
  ssh://agent@chief-subagents-1` (acpmux opens the tunnel and reads the token
  from the remote config).

Scale-out is more VMs and more peers. One 4 vCPU / 8 GiB VM holds several
Claude Code sessions (they wait on the model, not the CPU); tests go to the
fleet, not the VM. The Chief host picks the peer per spawn today from one
variable; a list with least-loaded choice is the next step (below).

## Cost

Freestyle's smallest persistent size is 4 vCPU / 8 GiB at about 0.26 USD per
running hour (a161's hub bill, 193 USD/month). Shared by N subagents, one
agent-hour costs about 0.26/N USD of VM time plus its model tokens (sr2). A
paused VM bills storage only; `deploy.sh pause` pauses a pool VM with no live
session.

## Credentials

The VM must push to `manaflow-ai/cmux` (and open PRs on cmuxterm-hq). The
right credential is a repo-scoped one held only by the VM (a deploy key with
write access made on the VM, or a GitHub App installation token). Making one is
a credential step: the Chief asks the user. Until then the proof pushes the
subagent's commit through the Mac (`deploy.sh land`: `git bundle` on the VM,
read over the Freestyle API, `git push` from the Mac), which uses no new
credential.

## Sandbox keys (2026-10-21)

Each cloud subagent can start and clean up its own throwaway VMs without a team
credential. When `~/.config/cmux/agent-issuer.json` (mode 0600: `key`, a cmux VM API
key with `vm:write`; `apiUrl`; optional `teamId`, `ttlSeconds`, `maxVms`,
`maxUsdPerHour`) exists, the Chief host (`agent_keys.rs`) issues every cloud subagent
an agent key (`POST /v1/agent-keys`, workers/cmux-vm README "Agent keys and client
sessions"): it reaches only VMs labelled `cmux.agent=<key id>`, has a VM count, a USD/h
budget and a TTL. The pool tool (`deploy.sh agent-key NAME ID`, key on stdin) writes it
to `/home/agent/.config/cmux/agents/<id>.json` (0600) and installs `cmux-sandbox`; the
subagent's task names the file (`CMUX_AGENT_CONFIG`), never the key. The Chief revokes
the key once the subagent has been done for 30 minutes (`REVOKE_AFTER_DONE`), and
the service deletes the agent's VMs; an expired key is reaped by the service's
5-minute cron. A key the pool tool cannot place is revoked at once and the subagent
starts without one. acpmux passes no env to peer sessions, so `CMUX_AGENT_KEY` is not
set there; the file is the delivery. Subagents that share one pool VM share one Unix
user, so they can read each other's key files: the label confinement holds against
other agents' API calls, not against a co-tenant on the same VM.

## Not in this change

- More than one peer and least-loaded choice; auto-create a VM when all are
  full; auto-pause idle VMs.
- Subagent `zoom`/`date` tools on the VM (the optchat MCP server is local).
- Tenant (non-HQ) placement through the cmux Cloud VM API, which needs acpmux
  in the devbox image (tenant design gap 1).

## Tests

- `tests/cloud_subagents.rs`: with a peer set and the cap at 1, a spawn of two
  starts both on the peer (no queue), with no local preset, in the peer folder,
  with the system text and the worktree note in the first message; a local
  spawn after them still starts (cloud ones take no local slot).
- `acpmux.rs` unit test: `session_meta` carries `peer` and no preset for a
  peer spec.

## Blockers to "subagents run in the cloud" (end-to-end owner, 2026-10-20 01:50 PDT)

Goal: a Chief `spawn` runs a subagent on a cloud VM (Freestyle first) in its
own repo worktree; it reports back like a local one, and its workspace and chat
show in cmux-next. a242 built and proved the core path (above): one real Claude
session on `chief-subagents-1` committed 2bd6fc35df2. The user still sees no
cloud subagents, for these reasons.

| # | Blocker | Owner | Shortest path |
|---|---|---|---|
| B1 | The live Chief host does not have the code. The installed NIGHTLY is built from ddcd2dc (06:15Z Oct 20); a242's 82a981959a4 landed 10 minutes later. | a176 (nightly cadence) | Next feat-cmux-next nightly, then the host restart that the update does. Nothing else to do here. |
| B2 | Off by default, and the only switch is `OPTCHAT_SUBAGENT_PEER` in the environment of the host that the app starts. Nobody can set it without changing how the app launches the host, and it moves every subagent or none. UI and computer-use tasks must stay on the Mac. | this task | `spawn(place: "cloud"\|"local")` per call, plus `control cloud PEER\|off` saved in state.json (as `control cap`): no restart, no env. |
| B3 | No GitHub credential on the VM. The subagent commits; `deploy.sh land` must push from the Mac by hand. | user decision (credential) | Default now: the Chief lands through the Mac (`deploy.sh land NAME ~/work/aN feat-cmux-next`). Later: a deploy key or GitHub App token held only by the VM. |
| B4 | One VM, no pool. No least-loaded choice, no auto-create, no auto-pause. The VM bills while it runs (about 0.26 USD/h). | this task (after B2) | A peer list in the same saved setting; pick the peer with the fewest live sessions; `deploy.sh pause` from the host when no cloud subagent lives. |
| B5 | `zoom` and `date` (the Chief's memory) are not on the VM; the optchat MCP server is a local socket. | this task (later) | The view goes in the first message today. Next: serve the tool socket over the acpmux peer tunnel. |
| B6 | Peer acpmux build is older than the Mac's (`acpmux host ls`: outdated). | a242 tooling | `deploy.sh up` (or `acpmux host update chief-subagents-1`) after each nightly. |
| B7 | Cloud Chief (the Chief itself on a VM) loses its app tools on redeploy. | a235 | Done 2026-10-20: cmuxterm-hq [#2620](https://github.com/manaflow-ai/cmuxterm-hq/pull/2620) makes `deploy.sh up` write the relay unit and `CMUX_CHIEF_APP_SOCKET`. A real redeploy of 222a8d4f41f kept 491 app tools. Not needed for cloud subagents of the Mac Chief. |
| B8 | Moving a whole Chief between hosts. | a284 | Separate: a moved Chief keeps `control cloud` because it lives in state.json. |
| B9 | Tenant (non-HQ) VMs through the cmux Cloud VM API need acpmux in the devbox image. | a205 | After B2: same `place: "cloud"` with a tenant peer. |
| B11 | The pool VM has a 32 GB disk with about 7 GB free. A full `cargo test` of optchat-chief filled it (2026-10-20). The fleet queue is also slow: two optchat-chief steps waited over 30 min without a worker. | this task / build-fleet owners | Cloud subagents send Rust and Swift tests to the fleet (as their first message says); the next `deploy.sh up` makes the disk 64 GB; a shared sccache is later. |
| B10 | A browser for cloud subagents. | a302 | The streamed browser is the remote browser of a cloud subagent; no work here until a302 has a prototype. |

Why it was slow: each piece had its own owner (a184, a196, a235, a205, a242,
a284), and nobody owned the end-to-end switch-on. a242's last step ("set
`OPTCHAT_SUBAGENT_PEER` after the nightly") was not possible without an app
change, and its credential question (B3) had no default.

### Smallest working slice (this change)

1. `spawn` takes `place: "cloud" | "local"`. `cloud` with no peer set up fails
   with how to set one up. With no `place`, the saved default applies, else
   the env (as before), else local.
2. `control cloud PEER` saves the peer (and makes cloud the default);
   `control cloud off` turns it off; `control cloud` (no peer) shows it.
3. Failing-first tests in `tests/cloud_subagents.rs`: placement per spawn, and
   the saved setting survives a host restart.
4. Status (2026-10-20): red 667c8558434 fails the 2 new tests on the VM;
   fix 1ccfbdce15f passes all 5 in `cloud_subagents` on the VM (Linux).
   Full crate, clippy and fmt on macOS: fleet step `cloudsub-green2-1ccfbdc`.
5. Proof: after the nightly, `control cloud chief-subagents-1` and one real
   spawn that reports back.

### B4 and B11 slice (2026-10-20)

- `control cloud cloud1,cloud2` lists peers. Each new cloud subagent goes to
  the peer with the fewest live (starting or running) cloud subagents,
  counting the ones of the same spawn; ties go to the first listed.
- `CloudVms` (optchat-chief `cloud_vms.rs`): before a cloud subagent starts,
  the host resumes its peer's VM (a no-op when it runs). The host's minute
  tick pauses a peer's VM once after 10 minutes with no live cloud subagent
  on it; a `tell` to a finished subagent on a paused VM resumes it first.
- The command is cmuxterm-hq `tools/cloud-subagents/deploy.sh`, named in
  `~/.config/cloud-subagents/vm-cmd`, which `deploy.sh up` writes. No file:
  the host leaves VMs alone. Everything stays behind the same opt-in: with
  `control cloud` off and no `OPTCHAT_SUBAGENT_PEER`, subagents run local.
- B11: `deploy.sh up` grows the VM disk to 64 GB (Freestyle resize is
  grow-only, needs a running VM) and grows the guest file system.
- Tests: two new tests in `tests/cloud_subagents.rs` (least busy peer and
  resume; idle pause once, then resume).

### Aggressive auto-pause (2026-10-20)

User: "For subagents in the cloud we need to have aggressive auto-pausing
behavior."

- `cloud.autoPause` (Chief settings, default false): the host pauses cloud
  VMs on its own only when this is true. Leo, 2026-10-30: "we're saying no
  auto pausing of the freestyle vms for now"; so by default no pool VM, own
  VM at its final report, or idle VM at host shutdown is paused by the host
  (`optchat-chief settings set cloud.autoPause true` opts in). Pausing by
  hand (`deploy.sh pause`) is unchanged. The rules below hold when it is on.
- `cloud.autoPauseIdleSeconds` (Chief settings, default 60; `optchat-chief
  settings set cloud.autoPauseIdleSeconds N`): a VM pauses this long after its
  last cloud subagent stops being live. Live = starting or running: a turn, a
  tool, a permission prompt or a held tell. The host checks every 5 s, so a
  VM pauses 60-65 s after it went idle.
- The pool tool also guards: `deploy.sh pause` exits 3 (busy) while a
  session on the VM is running or at a prompt, or an agent's background
  process runs; the host tries again later (`CloudPauseFailed`). So a turn
  is never frozen, even when the host's view is stale.
- The host stopping (SIGTERM, update) pauses its idle VMs at once. A VM with
  a subagent mid-turn keeps running; its report waits in acpmux. A host that
  crashes pauses idle VMs within 65 s of its next start. A VM-side watchdog
  for a Chief that never comes back is not built (it needs a Freestyle key
  on the VM).
- Wake: spawn and tell resume the VM first; the host logs each resume time.

Measured on a temporary 4 vCPU / 8 GiB Freestyle VM with 2 GiB of memory
in use, 3 runs (Freestyle API): pause 258-549 ms, resume until a command
runs 209-241 ms. `deploy.sh pause` with its busy check took 1.2 s on
chief-subagents-1. The acpmux peer reconnect after a resume is not measured.

Idle cost per VM (about 0.26 USD per running hour): before, a VM ran 10-11
minutes after its last subagent (about 0.045 USD per idle period), and never
paused when its host was gone. After: 60-65 s (about 0.0045 USD), 10 times
less; a host that stops pauses its idle VMs at once. The paused price is
storage only (64 GB); Freestyle's storage price was not checked.

## One VM per subagent (a464, 2026-10-22)

Ask (user, Oct 21-22): every Chief subagent in its own Freestyle VM, local
only when it needs the Mac GUI; right-sized; disk efficient; idle VMs
paused; a VM deleted after its work is pushed; ask before more than 20 USD/day.

What a242 left unwired (why 33 subagents still ran on the Mac): the saved
`control cloud` was empty, the only pool peer `chief-subagents-1` was gone
from `acpmux host ls`, and `~/.config/cloud-subagents/vm-cmd` named a
`deploy.sh` in a deleted clone, so every resume was a silent no-op.

### Placement

`control cloud freestyle` (`subagents::PER_AGENT`). Each new subagent `aN`
gets the peer `chief-sub-aN`: the Spawner asks the pool tool to
`provision` it (`deploy.sh resume chief-sub-aN --size S`), which makes the VM
the first time. Everything after start is the a242 peer path (relay, tells,
pause after `cloud.autoPauseIdleSeconds` = 60 s with no live subagent,
resume before a tell, never mid-turn).

- Mac tasks stay here: `needs_mac(task)` (screenshots, computer use,
  reload.sh/--launch, tagged app, simulator, Xcode, sign-in, passkey,
  dogfood). `place: "cloud"` overrides; `place: "local"` forces here.
- A VM that cannot be made (over budget, provider down) does not lose the
  subagent: it starts here, and the spawn answer says why.

### Sizes

| Size | vCPU / GiB / disk | USD per running h | For |
|---|---|---|---|
| small (default) | 2 / 4 / 16 GB | 0.13 | design, docs, review, edits |
| medium | 4 / 8 / 32 GB | 0.26 | bun/node/go tests, type checks (`size_for`) |
| large | 8 / 16 / 64 GB | 0.52 | only `place: "cloud:large"` |

Swift, Rust and app builds go to the Mac-mini fleet (`cmux-ci`), never to a
big VM. `small` is the base snapshot's own size (`freestyle/ubuntu-sm`);
bigger sizes grow from it (Freestyle resize is grow-only).

### Disk

- One shared base snapshot (`deploy.sh base`): git, tailscale (not joined),
  Claude Code on sr2, Linux acpmux and cmux-tui, bun, and a depth-1,
  single-branch, blobless clone of cmux feat-cmux-next. No Rust, no
  credential, no tailnet identity. Caches dropped and TRIMmed before the
  snapshot.
- Each VM is a copy-on-write fork of it: its own bytes are only what its
  subagent writes. `vm/fork.sh` does no installs: tailnet join, acpmux
  start, a depth-1 fetch of feat-cmux-next.
- Delete: 30 min (`REAP_AFTER_DONE`) after its subagent is done, the Chief
  host runs `deploy.sh destroy`; it refuses (and pauses the VM) while a
  worktree there has commits not on origin or uncommitted edits, and is
  tried again later. A tell after the delete says so. Freestyle's
  `autoDeleteSeconds` (7 days not running) is the leak guard.
- `deploy.sh disk NAME` reports used, own (above the base) and work GB.

### Cost guard

`deploy.sh` keeps a ledger of running intervals per VM
(`~/.config/cloud-subagents/ledger.json`). A new VM is refused (exit 4, the
subagent runs here) when today's spend plus one more hour of everything
running would pass `CLOUD_SUBAGENTS_BUDGET_USD_DAY` (20). `deploy.sh cost`
prints today's spend, the running rate and the size table.

### Credentials

Unchanged from a242: no GitHub credential on the VM. A subagent commits;
`deploy.sh land NAME DIR BRANCH` pushes through the Mac (plain push). The
delete waits for that push.

### Tests

- cmux `tests/cloud_subagents.rs`: own VM per subagent at the guessed or
  asked size, Mac tasks local; a VM that cannot be made starts the subagent
  here; a finished subagent's VM is deleted once, after a refusal; a tell
  after it is refused.
- cmuxterm-hq `tools/cloud-subagents/deploy.test.ts`: names, sizes and
  grow-only resize, spend from the ledger, the budget guard, the unpushed check.

### Proof (2026-10-22)

- Base snapshot `sh-dd4deeb66bdd4d25be4f1473ad29195a`: 7.44 GB used of 16 GB
  (cmux feat-cmux-next fe14026207, Claude Code 2.1.308).
- `deploy.sh resume chief-sub-a9464 --size small`: VM up, on the tailnet and an
  acpmux peer of the Mac in 7.1 s.
- A real Claude Code session on that peer (`acpmux run --host chief-sub-a9464`)
  made a worktree and committed; `deploy.sh land` pushed it plain to
  feat-cmux-next as c54e51c9c1d (that file clashed in case with
  cloud-subagents-PROOF.md and was removed again; its text is this section).
- `deploy.sh disk`: 8.49 GB used, 1.05 GB its own (0.93 GB the worktree).
- `deploy.sh destroy`: first refused (the VM's origin refs did not have the
  Mac's push yet: the check now fetches first), then deleted the VM, the
  peer and the tailnet device. Cost of the whole proof: 0.0077 USD.
- Tests: red run 39725656487 (fails), green run 39725658965 (passes).

## v2: every subagent in its own VM, by default (a489, 2026-10-22)

Ask (user, Oct 22, through the Chief): every Chief subagent runs in its own
new Freestyle VM and the VM pauses when its task is done. Replaces a242;
builds on the one-VM-per-subagent slice above (a466) and on the Worker VM
verbs (a475). Seven parts; for each, what exists and what is still to do.

| # | Ask | Now (feat-cmux-next 328330284cc, hq main) | To do |
|---|---|---|---|
| 1 | One base image: cmux and cmuxterm-hq, toolchains, build caches, acpmux, Claude Code; each VM starts from it | `deploy.sh base`: cmux clone (no checkout, hq #2989), acpmux, cmux-tui, Claude Code, bun. No cmuxterm-hq, no Rust/Go/Node, no `cmux-ci`, no caches. | V2-1 |
| 2 | Cloud by default; the Mac only for the app window, screenshots, the user's machine | Off until `control cloud freestyle`; `needs_mac` keeps GUI tasks here. | V2-2 |
| 3 | Swift/macOS builds go to the Mac minis through `cmux-ci` over Tailscale, with a short-lived tailnet key limited to what the VM needs | Fork joins with a 1 h, single-use, preauthorized `tag:agent-cloud` key. ACL lets the tag reach the controller :18765 and sr2 :4016, and also mini/macbuilder SSH and VNC (Lawrence, Oct 22). `cmux-ci` is not on the VM. | V2-1 (client), V2-3 (key) |
| 4 | Auth through client sessions only: the team key stays on the Worker; Claude through the sr2 gateway; a short-lived scoped git token | The Mac runs `deploy.sh` with the HQ Freestyle key in `~/.secrets`. Claude goes through sr2 already. No git credential on the VM: `deploy.sh land` pushes through the Mac. | V2-4, V2-5 |
| 5 | Pause on the final report; resume on a tell; pause while waiting on fleet jobs and wake on the result; remove after N days paused | Pause 60 s after the last live subagent; resume before a tell; delete 30 min after done (once pushed). No fleet wait. | V2-2 |
| 6 | The app shows cloud agents like local ones: link, chat, terminal | Link and chat: the cmux workspace's chat tab relays the peer session. No terminal on the VM. | V2-6 |
| 7 | Cost per hour at 1, 50 and 200 agents | Below. | - |

### Auth: what each side holds

No long-lived secret is on a subagent VM, and the Freestyle team key is only
on the cmux VM Worker (`vm.cmux.dev`, `workers/cmux-vm`).

| Who | Holds | For |
|---|---|---|
| cmux VM Worker | the Freestyle team key | every provider call |
| Chief host (Mac) | a cmux VM API key (`cmuxvm_sk_`, `vm:read vm:write vm:exec`, labels `role=chief-sub`), in `~/.config/cloud-subagents/cmux-vm.json` (0600) | create from the base snapshot, pause, resume, resize, delete, exec, client sessions, of its own labelled VMs only |
| Chief host | `tsadmin` (Tailscale API) | one tailnet auth key per VM join |
| Chief host | a GitHub App private key (path in `~/.config/cloud-subagents/git.json`) | one installation token per VM, 1 h |
| Subagent VM | a client session (one VM, Linux user `agent`, revoked at delete) only when the Mac needs SSH without the tailnet; a tailnet node identity (tag `agent-cloud`); a git token file that expires in 1 h | its own work |
| Subagent VM, sandboxes | an agent key (sandbox keys above), labels `cmux.agent=<id>` | throwaway VMs it starts itself |

- Claude Code: `ANTHROPIC_BASE_URL` = sr2 on the tailnet (the gateway's
  tailnet-auth mode; the token in settings is a dummy). No Anthropic key.
- Git: the host mints an installation token for `manaflow-ai/cmux` and
  `manaflow-ai/cmuxterm-hq` only, `contents: write` and `pull_requests:
  write` only, and writes it on resume and every 45 min while the VM runs
  (`~/.config/git/cmux-token`, 0600; a credential helper reads it). A paused
  VM's token expires on its own. Until the user picks the App (a credential
  step), the host writes no token and the subagent lands with `deploy.sh
  land` through the Mac, as today.
- Freestyle through the Worker (V2-4): `deploy.ts` gets a backend switch.
  `CLOUD_SUBAGENTS_BACKEND=cmux-vm` makes every call through the Worker
  (`POST /v1/vms {snapshotId, resources, labels, autoDeleteSeconds}`, `/pause`,
  `/resume`, `/resize`, `DELETE`, `/exec`, `/snapshots`); `freestyle` (the
  default until the Worker path is proved on staging and production) keeps
  the direct calls. The base snapshot is made through the Worker too, so it is
  the tenant's `snap_` and carries the `role=chief-sub` label.

### Tailnet key (V2-3)

Per join: `reusable: false`, `preauthorized: true`, `ephemeral: false` (a
paused VM is offline for days and must come back as the same node),
`tags: ["tag:agent-cloud"]`, `expirySeconds: 600` (was 3600; a join takes
under 10 s). The key goes to the VM as a file through the Worker's file write
(never in an exec argument, which the audit log keeps) and the fork script
deletes it after `tailscale up --auth-key=file:`. Delete removes the device.
What the tag reaches is the ACL above; narrowing it to the controller and
sr2 only would undo Lawrence's Oct 22 grant, so it stays, and the report says
so.

### Lifecycle (V2-2)

| Event | Host action |
|---|---|
| spawn (cloud placement) | create or resume `chief-sub-aN` from the base snapshot, join, start the session |
| final report (the subagent's turn ends with its report and nothing of it runs) | pause at once (was: after `cloud.autoPauseIdleSeconds`, which still covers a VM whose report was not seen) |
| tell | resume, then send |
| `cmux-ci wait` on the VM | the wrapper (`~/.local/bin/cmux-ci`) does not block: it records the job id in `~/.cmux-park/JOB` and tells the subagent to end its turn. The host reads the park file before it pauses, pauses the VM, polls the controller (`GET /jobs/ID`) every 30 s, and on a final state resumes the VM and sends the subagent `fleet job ID finished: STATE` with the job's receipt URL. |
| paused N days (`cloud.deleteAfterPausedDays`, default 7) | delete (the unpushed-work check still refuses and the VM stays paused; a refusal is logged and retried daily). Freestyle `autoDeleteSeconds` = N + 1 days is the leak guard. Replaces the 30 min `REAP_AFTER_DONE`. |
| host stops | pause idle VMs (unchanged) |

The fleet wait wakes on the result, not on a timer: a subagent that waits on a
40 min build costs 0 USD of VM time during the wait.

### Placement (V2-2)

With no saved `control cloud` (never set) and a pool tool configured, the
default is `freestyle` (one VM per subagent). `control cloud off` is
remembered and wins. `needs_mac` and `place: "local"` keep a subagent here.
No pool tool: local, as before.

### App (V2-6)

A cloud subagent's workspace gets a second tab: a terminal that runs
`ssh agent@chief-sub-aN` (Tailscale SSH) into its worktree, opened
when the VM is up. Opening it resumes a paused VM. The sidebar row shows a
cloud badge and the VM state (running, paused, deleted).

### Slices

| Slice | Repo | What | Tests first |
|---|---|---|---|
| V2-1 | hq | base image: cmuxterm-hq clone (no checkout), Node 22 + pnpm, Go, Rust stable (minimal) with a fetched cargo registry for `optchat-chief`, `cmux-ci` client, bun and cargo caches warmed; `disk` report | `deploy.test.ts`: base script names every part; fork does no install |
| V2-2 | cmux | cloud default; pause on final report; delete after N days paused; fleet park and wake | `tests/cloud_subagents.rs` |
| V2-3 | hq | 600 s single-use key, key as a file, deleted after join | `deploy.test.ts` |
| V2-4 | hq | Worker backend for `deploy.ts`, proved on `vm-staging.cmux.dev` | `deploy.test.ts` against a fake Worker |
| V2-5 | cmux + hq | git token: host mints, writes, refreshes; credential helper on the VM | unit tests; live only after the user picks the App |
| V2-6 | cmux | terminal tab and cloud badge | optchat-chief workspace test |

### Cost (V2, 2026-10-22)

Freestyle VM time, priced as the Worker's budget check does (0.05 USD per
vCPU-hour + 0.0075 USD per GiB-hour): small (2 vCPU / 4 GiB) 0.13 USD per
running hour, medium (4 / 8) 0.26. Mix: 70% small, 30% medium (`size_for`
gives medium to test and type-check tasks), 0.169 USD per agent-hour running.

| Agents | All running, all small | All running, mix | 50% running (rest paused on fleet waits and between tells), mix |
|---|---|---|---|
| 1 | 0.13 USD/h | 0.17 USD/h | 0.08 USD/h |
| 50 | 6.50 USD/h | 8.45 USD/h | 4.23 USD/h |
| 200 | 26.00 USD/h | 33.80 USD/h | 16.90 USD/h |

Not in the table: model tokens through sr2 (the largest cost; a444 measures
it per agent), paused storage (about 1 GB own bytes per VM above the shared
base; Freestyle's storage price is not checked), and the fleet minis (owned).
Limits to check before 200: the `deploy.sh` daily budget guard is 20 USD/day,
which 50 running agents use in about 2.4 h (then new subagents run on the
Mac); Freestyle's concurrent-VM limit on the Pro plan; Tailscale's device
count for 200 more nodes. Raising any of them is a money decision for the user.

### Base without a working tree (2026-10-22, cmuxterm-hq #2989)

The base clone is now `--no-checkout` (depth 1, one branch, HEAD blobs kept
in the pack, no `--filter`): subagents use their own worktrees, so the
checkout in `~/src/cmux` was unused bytes. Base snapshot
`sh-494cda79998f4c5e809f5180060690ec`: 6.42 GB used (was 7.44 GB). Fork test
`chief-sub-a9465`: up in 8.7 s, `worktree add` in 8 s with no blob download
(32,137 files), 7.48 GB used in total (was 8.49 GB), 1.06 GB its own; then
deleted. The old base snapshot is deleted.

### Base image v2 measured (2026-10-22)

hq [#2993](https://github.com/manaflow-ai/cmuxterm-hq/pull/2993): base snapshot
`sh-274a385d8c944d9895a8d3adc179119c`, 9.09 GB used (was 6.42 GB): cmux
feat-cmux-next and cmuxterm-hq main (depth 1, no checkout), Node 22 + pnpm,
Go 1.27.3, Rust 1.95.0, `cmux-ci`, cargo and Go module caches, Claude Code
2.1.308. A small fork (`chief-sub-a9489`): up in 9.8 s; cmux worktree 10 s,
hq worktree 4 s; `cargo fetch --offline` for cmux-tui 1 s; `cmux-ci status`
answers from the VM over the tailnet; 1.56 GB own bytes; then deleted.

### rift for per-agent workspaces (user idea, 2026-10-22)

[rift](https://github.com/anomalyco/rift) v0.0.13 makes copy-on-write copies of
a folder (APFS `clonefile` on the Mac, btrfs or `FICLONE` reflinks on Linux).
Timed on a scratch clone of cmux (32,141 files, 958 MB) on this Mac (APFS), 3
runs each:

| How | Time | Notes |
|---|---|---|
| `git worktree add` | 9.5-12.3 s | shares the object store; `git status` in it 1.35 s |
| `rift create` (filtered) | 8.1-9.4 s | walks the tree to drop `target`, `node_modules`, `dist`... |
| `rift create --copy-all` | 0.64-0.82 s | one `clonefile` of the whole folder, `.git` too; `git status` 0.34 s |

- In the VMs: no use. The VM disk is ext4 without reflink (`base.sh` logs
  `fs=ext2/ext3 reflink=no`), so rift cannot copy on write there, and a
  Freestyle fork already copies on write at the block level: one subagent per
  VM needs one worktree, made in 10 s from the base clone. Pairing rift with
  Freestyle fork adds nothing until a VM holds several agents.
- On the Mac: `--copy-all` is about 13 times faster than `git worktree add`
  and its `git status` is 4 times faster (its own index, no linked worktree).
  Limits: it refuses a linked worktree as the source; it copies the source's
  working state, so the source must be a clean seed clone, never the shared
  main checkout (the user's edits would leak in); each copy is its own repo,
  so its commits reach the branch only by push. Not adopted in this change:
  local subagents are now only the Mac-only tasks. Next step when local
  workspace time matters: one clean seed clone per repo, updated on each
  spawn, `rift create --copy-all` from it.

## Pool box chief-subagents-2 and VM pushes (2026-10-23)

Ask (Lawrence, Oct 23): a 64 GB RAM Freestyle box with the most CPU and a 200 GB
disk, as the acpmux cloud peer for Chief subagents.

- `deploy.sh resume chief-subagents-2 --size xl` (cmuxterm-hq
  `tools/cloud-subagents`): 32 vCPU / 64 GiB / 200 GB, made from the base
  snapshot. 32 vCPU is the most Freestyle gives at 64 GiB
  (`freestyle/ubuntu-2xl`, the largest size any plan can create). 2.08 USD per
  running hour (0.05 per vCPU-hour + 0.0075 per GiB-hour), about 1,520 USD a
  month if it never pauses. A pool VM has no 7-day auto-delete. The Chief host
  pauses it 60 s after its last live cloud subagent, never mid-turn.
- acpmux on the box is built there from the NIGHTLY's sha (e80d1f65e), the same
  build as the Mac. Claude Code goes through sr2, Codex (0.164.0) through the
  cmux-lawrence subrouter (the tag:agent-cloud ACL now grants 100.89.225.106:31415).

### Why new peers failed with ssh exit 255

1. Host key race: the one `ssh-keyscan` after the tailnet join could time out,
   so nothing reached known_hosts, and acpmux's BatchMode ssh failed with
   "Host key verification failed" (255). The scan now repeats for up to a minute
   and fails loudly.
2. Stale tailscaled in forks: a fork resumes the base VM's memory, and its
   days-old tailscaled lost the WireGuard data path minutes after the join
   (disco ping answered, TCP and TSMP did not). The peer dropped with 255, which
   is how a600's run on chief-sub-a600 failed after 2 minutes. `fork.sh` now
   restarts tailscaled, `provision` uploads the checkout's `fork.sh` (the copy
   in the snapshot was old), and `base.sh` leaves no tailscaled state in the image.

### Pushes from a VM

The VM's GitHub App token (contents and pull requests write) pushes to a branch
that exists, such as feat-cmux-next. It cannot create a branch: GitHub's workflow
check times out on a new ref and asks for the `workflows` permission. So a
subagent lands on feat-cmux-next itself (rebase, plain push). For a new branch,
it sets `git config cmux.land BRANCH`, and the Mac creates the branch with its
own credential when it lands.

### Proof

A Claude Code session on chief-subagents-2, started from the Mac through acpmux,
made a worktree of cmux, wrote this section, and pushed this commit to
feat-cmux-next itself with the VM's App token. Nothing was pushed through the Mac.

### Open: a tailnet VM does not stay paused (2026-10-23)

`deploy.sh pause chief-subagents-2` returns `paused`, but Freestyle shows the VM
`running` again 2-60 s later. It woke with tailscaled stopped and also with the
Mac's acpmux peer removed (that held it about 5 s longer). A fresh VM off the
tailnet stayed paused for 20 s. So inbound tailnet traffic probably wakes it.
Until this is fixed, auto-pause saves nothing on tailnet VMs, and the ledger
(which marks a pause as a stop) undercounts the daily budget. chief-subagents-2
bills 2.08 USD/h while idle, about 50 USD/day.

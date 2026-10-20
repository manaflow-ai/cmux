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
| B7 | Cloud Chief (the Chief itself on a VM) loses its app tools on redeploy. | a235 | Separate path: not needed for cloud subagents of the Mac Chief. |
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

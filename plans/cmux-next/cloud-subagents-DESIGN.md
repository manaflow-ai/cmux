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

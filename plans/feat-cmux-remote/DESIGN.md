# cmux remote — workspace handoff

Status: prototype and resume-fidelity lab validated on 2026-08-12; production
implementation is not in this change.
Branch: `feat-cmux-remote`.

Goal: make a running local agent workspace portable to a cloud persistent slot
and back, with an explicit loss model, one writer, and empirically validated
resume semantics.

Founder intent, verbatim: “close the laptop, agents keep running in the cloud,
resume locally later; same workspace tab, same conversation, same branch/diff
state; transfer must be trustworthy — no token scraping, no force-pushed real
branches, nothing silently lossy.”

This document calls the product **cmux remote** and the mechanism a **workspace
handoff**. It is a design for a logical state transfer, not a promise that a
local operating-system process can be suspended and moved to another kernel.

## 1. Product vision and invariants

The user starts with a local cmux workspace containing one or more terminal
surfaces and an agent conversation. `cmux workspace offload` parks that local
workspace, places a durable copy on a managed Cloud VM, and retargets the
existing tab to the remote runtime. `cmux workspace recall` reverses the path.

The user-visible promise is continuity, not identical pixels. Git HEAD,
staged changes, unstaged changes, untracked files, selected explicitly ignored
files, workspace layout, agent transcript, and resume identity are carried.
PTY processes, ephemeral relay credentials, shell process state, and terminal
scrollback are recreated or called out as lost. Every lossy boundary is named
before confirmation.

The trust invariants are:

- The local repository is never mutated while constructing a bundle. Temporary
  Git indexes and a temporary ref are disposable implementation details.
- Real branches are never force-pushed. A future optimization may use a hidden
  `refs/cmux/handoff/<id>` ref with a TTL, never a user branch.
- Agent credentials and local keychain material never enter a bundle.
- A handoff has one authoritative writer at a time. The parked local copy is
  advisory read-only and recall detects any divergence.
- A bundle has an explicit schema version and an immutable handoff id. Upload,
  restore, and ledger transitions are idempotent by that id.

## 2. Today / the gap

### What exists

`cmuxd-remote` already has persistent PTY sessions. The WebSocket replay buffer
is capped at 1 MiB and retains the last size (`daemon/remote/cmd/cmuxd-remote/ws_pty.go:103-114`).
Slot state is stored under the daemon version and slot name with an auth token,
log, and lock (the slot setup is in `daemon/remote/cmd/cmuxd-remote/main.go:600-623`).
This is the correct substrate for an agent that survives terminal detach.

The daemon currently advertises `session.*`, `proxy.*`, `pty.*`, and
`cli.response` capabilities (`daemon/remote/cmd/cmuxd-remote/main.go:1769-1836`).
There is no `state.*`, `workspace.*`, snapshot, or handoff RPC on main. New
namespaced verbs must be listed by `hello`, rather than inferred from an
unknown-method response.

Remote workspace configuration is already durable enough to reopen a workspace.
It carries destination, transport, terminal transport, relay port/id/token,
managed Cloud VM id, persistent daemon slot, and bootstrap policy. The
configuration forces `persistentDaemonSlot` to nil unless SSH plus preservation
is active (`Packages/macOS/CmuxCore/Sources/CmuxCore/Remote/WorkspaceRemoteConfiguration.swift:99-115`).
Cloud VM snapshots use the managed VM, skip daemon bootstrap, and the fixed
`cmux-default-freestyle-sshd-v1` slot
(`Packages/macOS/CmuxCore/Sources/CmuxCore/Remote/WorkspaceRemoteConfiguration.swift:408-429`).

`SessionWorkspaceSnapshot` persists title/provenance, current directory, layout,
canvas panes, panels, status, Git branch, remote configuration, environment,
checklist, and dock state (`Sources/SessionPersistence.swift:1798-1843`). A local
terminal snapshot caps scrollback at 4,000 lines or 400,000 characters
(`Sources/SessionPersistence.swift:34-35`). These are useful seeds, but not yet
a portable handoff contract.

Surface resume bindings already contain command, cwd, checkpoint/session id,
launch argv, approval information, and an execution flavor
(`Sources/SessionPersistence.swift:265-287`). The flavor seam is explicitly
`.local` or `.persistentSSH` with a remote context
(`Sources/SurfaceResumeLaunchFlavor.swift:3-25`). Native resume argv is
`claude --resume <id>` (`Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch/AgentResumeArgv.swift:425-430`)
and Codex uses `codex resume <id>` (`.../AgentResumeArgv.swift:339-351`).

Hooks write per-agent session records. The documented store contains agent and
session ids, workspace/surface ids, cwd, transcript path, launch command,
runtime state, and prompt-turn fields (`docs/agent-hooks.md:46-54`; the Claude
record fields are visible at `CLI/cmux.swift:130-179`). This is sufficient to
distinguish idle at a turn boundary from an in-flight prompt; it is not a
portable filesystem bundle by itself.

The Cloud VM control plane already has create/exec/snapshot/restore/fork and
attach workflows (`web/services/vms/workflows.ts:190,564,596,634,1385,1430-1537`). The database has
`cloud_vm_sessions`, keyed by `(vmId, providerSessionId)`, with attachment,
size, status, and metadata fields (`web/db/schema.ts:232-264`). That ledger is
VM-scoped, WebSocket-path-only, and has no workspace or handoff identity.
The devices registry is rendezvous, not authority; account authorization and
leases remain control-plane decisions.

### What is missing

There is no migration verb, bundle protocol, account-level workspace ledger,
single-writer park marker, second-device discovery, or landed runtime-state
layer. Existing remote workspaces are born remote through
`workspace.remote.configure` (`CLI/cmux.swift:9744-9745`); no path re-hosts an
already-running local workspace. `cmux vm handoff` only prints VM status and an
attach hint (`CLI/cmux.swift:4442-4458`).

The stalled `origin/feat-remote-runtime-persistent-sessions` branch supplies a
useful Go runtime-state substrate, but its app integration conflicts with main.
Its whole-snapshot payload and exact `schema_version == 1` gate are not a
portable migration contract. The handoff bundle defined below is the authority.

## 3. Architecture: no live process migration

Workspace handoff is state teleportation:

1. Wait for an agent turn boundary, or explicitly interrupt.
2. Park the local workspace and become the single writer.
3. Snapshot Git state, approved files, agent sessions, and workspace metadata.
4. Transfer a content-addressed bundle through the control plane.
5. Restore the bundle on a VM under a persistent daemon slot.
6. Resume or reattach the agent, then attach the same cmux tab to the remote
   workspace.

Claude and Codex expose durable conversation selectors (`claude --resume` and
`codex resume`), so the conversation is the portable checkpoint rather than a
CPU register image. The local PTY cannot be the migration boundary: freeing a
Ghostty surface tears down its renderer and PTY (#5497). A process tied to a
local kernel, filesystem namespace, and keychain cannot safely be serialized by
cmux.

CRIU-style checkpoint/restore is rejected for v1. It would require a compatible
Linux kernel and libc on every VM, would still not preserve macOS Ghostty state,
would capture credentials and sockets we explicitly do not want to copy, and
would turn agent version skew into an opaque restore failure. A turn-boundary
conversation checkpoint is observable, retryable, and auditable.

## 4. Exact state model

The portable state model has three explicit sets. A field is never silently
promoted from LOST to MOVES.

### MOVES

| Category | Fields and rule |
|---|---|
| Git identity | HEAD SHA, branch name or detached marker, index/staged tree, worktree tree, untracked tree and sorted untracked paths. |
| Git history | A self-contained `git bundle` commit chain whose parent is the original HEAD. No real branch update. |
| Submodules | Each top-level path, URL, index-pinned SHA, and dirty flag. Dirty submodules refuse by default. Nested submodules are recorded only through the parent pin in v1. |
| Agent sessions | Only explicitly selected Claude JSONL/todos and Codex rollout files. The manifest records original cwd and relative source paths. |
| Workspace metadata | Title and provenance, pane layout and canvas frames, pane types, browser URLs, cwd mapping, Git branch display, todos/checklist, dock/status metadata. |
| Ignored files | Only explicit-consent paths, copied byte-for-byte with recorded mode. No wildcard `.env` capture. |

The three Git trees preserve the meaningful split: staged content is written
from a copy of the real index; worktree content is an index copy after
`git add -u`; untracked content is built from an empty temporary index. Empty
directories are unrepresentable in Git and are documented as such.

### RECREATED

| Item | Restore behavior |
|---|---|
| PTY and shell | Start a fresh PTY in the persistent daemon slot. Reattach a live persistent PTY; otherwise launch the approved resume argv once. |
| Relay identity | Mint a fresh relay id and token per attach. `relayID` and `relayToken` are intentionally not in `SessionRemoteWorkspaceSnapshot`; attach code creates them (`CLI/cmux.swift:10734-10743`). |
| VM auth | Establish the VM's agent login through device-code flow or a short-lived brokered credential. Never copy local keychain state. |
| Browser process | Recreate a browser panel from its URL and profile policy; do not serialize a WebKit process. |

### LOST-v1

| Item | Reason and future seed |
|---|---|
| Terminal scrollback | Local snapshots cap at 4,000 lines/400,000 chars (`Sources/SessionPersistence.swift:34-35`). The daemon's 1 MiB replay buffer (`ws_pty.go:107`) is a later scrollback carry optimization, not a v1 guarantee. |
| Running non-agent processes | A handoff resumes the agent, not arbitrary servers, shell jobs, or GUI processes. Persist `listeningPorts` later as restart hints. |
| Local keychain, shell rc, and tokens | Security invariant; require explicit, separate enrollment. |
| OS-specific terminal rendering | The remote surface renders fresh output. |

### Portable bundle format

The bundle directory contains:

```text
manifest.json
repo.bundle
agent-sessions/
  claude/<session>.jsonl
  claude/todos/<session>-*.json
  codex/sessions/<date>/rollout-*.jsonl
ignored-files/<explicit-relative-paths>
```

`manifest.json` is a bundle document, not a Swift runtime snapshot. Its
required schema is:

```json
{
  "bundle_schema_version": 1,
  "tool_version": "cmux-workspace-handoff 1.0",
  "workspace_basename": "name",
  "original_abspath": "/Users/me/name",
  "branch": "main",
  "detached": false,
  "head_sha": "...",
  "staged_tree": "...",
  "worktree_tree": "...",
  "untracked_tree": "...",
  "staged_commit": "...",
  "worktree_commit": "...",
  "untracked_commit": "...",
  "ref": "refs/cmux/handoff-tmp/<uuid>",
  "origin_url": "informational-only, credentials stripped",
  "submodules": [{"path":"vendor/x","url":"...","pinned_sha":"...","dirty":false}],
  "untracked_paths": ["new.txt"],
  "ignored_allowlist": [{"path":".env","mode":384}],
  "agent_sessions": [{"kind":"claude","session_id":"...","original_cwd":"...","relpaths":[],"bundle_paths":[],"cli_version":"..."}],
  "created_at": "SOURCE_DATE_EPOCH or UTC now"
}
```

The bundle schema version and the runtime-state document version share a
versioning policy: additive fields are optional, incompatible changes increment
the version, and a consumer refuses an unknown major shape instead of silently
decoding a different snapshot.

## 5. End-to-end protocol

### Offload

**Preflight.** Confirm the workspace is a Git repository; enumerate dirty
submodules; verify all configured agent sessions have a transcript; inspect hook
runtime status and active prompt-turn fields. A nonzero active prompt depth is
“in flight”, not idle (`CLI/cmux.swift:151-156`). Confirm the user understands
ignored-file consent and scrollback loss. Default behavior waits for a Stop or
turn-boundary hook.

**Park.** Write `.git/cmux/handoff.json` with handoff id, source HEAD/index and
worktree digests, and state `parked-local`. The app marks the workspace cloud
and read-only. The park operation is one coordinator action, not a second
optimistic copy in each UI entry point.

**Snapshot and transfer.** Build the portable bundle with temporary indexes,
delete the temporary ref in a `finally` path, and upload atomically. The ledger
advances only after durable upload acknowledgement.

**Restore and resume.** Create or select the managed VM, place the repository at
`~/workspace/<name>`, fetch the bundle into a new local ref, reconstruct staged
and worktree state, initialize pinned submodules, and start the agent through
the persistent daemon slot (tmux/agent-launch path). A live PTY is reattached;
an absent PTY runs the approved resume command exactly once.

**Attach.** Use the existing `workspace.remote.configure` path and
`managedCloudVMID` machinery. The workspace remains the same tab and stable id;
its binding changes from `.local` to `.persistentSSH` with the new workspace,
surface, and persistent PTY context. Relay credentials are minted afresh.

### Bring-back

1. Wait for a VM turn boundary or require explicit interrupt.
2. Pause the persistent slot and snapshot the VM workspace.
3. Transfer the bundle back through the control plane.
4. Recompare the parked local marker with its pre-park digests.
5. If unchanged, restore in place and resume locally; if changed, enter the
   explicit discard/abort/fork choice described in single-writer enforcement.
6. Remove the park marker only after local verification and unpark the tab.

### State machine

```text
LOCAL_WRITABLE
      | preflight + wait boundary
      v
PARKING_LOCAL --snapshot error--> LOCAL_WRITABLE
      | durable upload
      v
TRANSFERRING --network retry--> TRANSFERRING
      | restore error
      v
REMOTE_RESTORE_FAILED --> VM inspection / fresh VM retry
      |
      v
REMOTE_WRITABLE --VM death--> LEDGER_REMOTE + bundle durable
      | recall at boundary
      v
RECALLING --local divergence--> PARKED_CONFLICT
      | verified restore
      v
LOCAL_WRITABLE
```

Mid-turn behavior is deliberately narrow in v1: wait for a boundary by default
or offer an explicit interrupt. Interrupting may lose at most the in-flight
turn; transcripts append per message, so the last completed message remains in
the bundle and the interrupted turn is visible as an incomplete attempt.

## 6. Transfer transport

### v1: control-plane portable bundle

Upload the bundle using the Cloud VM control plane's `execVm`/file channel. The
VM needs no Git credential and no shared origin. This is also the fallback when
the repository has no usable shared remote. `git bundle` is self-contained and
can be verified before restore.

The control plane records content hashes, byte size, handoff id, and an atomic
upload state. A retry of the same handoff id either resumes an incomplete
upload or reuses the durable object; it never creates a second logical handoff.

### v2: hidden ref optimization

The local machine may push a temporary ref
`refs/cmux/handoff/<handoff-id>` using the user's existing Git auth. The VM
fetches it with a backend-brokered short-lived read credential. This avoids
re-uploading reachable objects and is faster for large repositories.

The tradeoff is a new Git-auth surface and a server-side cleanup obligation.
The hidden ref is never a real branch, has a short TTL, is deleted after a
verified restore, and is garbage-collected after an abandoned handoff. The
portable bundle remains the no-shared-remote fallback in both eras.

## 7. Path strategy — prototype evidence

The experiment asks whether the agent's project/rollout directory is keyed by
project slug, whether resume works from another cwd, where appended turns are
written, and whether cwd fields need rewriting.

### Experiment matrix

| Agent | Create | Capture | Restore | Resume questions |
|---|---|---|---|---|
| Claude 2.1.229 | `claude -p --session-id <uuid> --model claude-haiku-4-5-20251001 ...` from `src.dot_under` | `snapshot --claude-session <uuid> --claude-home ~/.claude` | `restore --claude-cwd-mode verbatim` into `dst.dot_under`; then `cd dst.dot_under && claude -p --resume <uuid> ...` | codeword, reported cwd, source/destination JSONL sizes, and actual slug |
| Codex 0.147.0 | `codex exec --json -c model_reasoning_effort=low --sandbox read-only ...` from `src` | `snapshot --codex-session <id> --codex-home ~/.codex` | placement-only scratch restore; Arm A real HOME; Arm B move-aside plus real-home restore | session lookup, cwd, rollout growth, file-set sufficiency, and exit status |

The complete shell commands and trimmed outputs are retained in the Claude run
`/tmp/cmux-remote-lab/run-1786592839/findings.md` and the Codex run
`/tmp/cmux-remote-lab/run-1786593798/findings.md`; the former is the
dotted/underscore Claude leg and the latter contains both Codex resume arms.
The runbook uses `env -i` with only HOME, PATH, USER, SHELL, TMPDIR, TERM, and
LANG, so no CMUX/CODEX nested-session variables are inherited.

### Decision

The default is a canonical different path on the VM, for example
`~/workspace/<name>`. Identical absolute paths are not required by either
resume experiment. The portable bundle therefore records the original cwd and
restores under a new path.

### Normative Claude recipe

Claude Code stores the session at
`~/.claude/projects/<slug>/<session-id>.jsonl`. The definitive run created the
source `/private/tmp/cmux-remote-lab/run-1786592839/src.dot_under` and observed
`-private-tmp-cmux-remote-lab-run-1786592839-src-dot-under`. The experiment
confirmed that path separators, dots, and underscores each become `-`. The
implementation uses `re.sub(r"[^A-Za-z0-9]", "-", path)`; the lab and fake-home
test are the evidence for the three characters that matter to handoff paths.
Restore computes the destination slug, refuses an existing same-id file, and
copies the JSONL there.

The verbatim arm worked: Claude recalled `cobalt` and reported
`/private/tmp/cmux-remote-lab/run-1786592839/dst.dot_under`. The resumed message
was appended to the destination-slug JSONL (source stayed 17,714 bytes while
the destination reached 22,738 bytes). Cwd-bearing fields do not need rewriting
for resume. `--claude-cwd-mode rewrite` remains an explicit repair mode that
rewrites only JSON keys `cwd`, `current_cwd`, `current_working_directory`,
`working_directory`, `project_path`, and `projectPath`, preserving line count.

### Normative Codex recipe

Codex rollouts are discovered under `~/.codex/sessions/**/rollout-*<id>*.jsonl`
and restored under the same dated relative path. The definitive run emitted
thread id `019ff949-f082-7e01-8376-b00fd1598a28` and rollout
`sessions/2026/08/12/rollout-2026-08-12T21-03-20-019ff949-f082-7e01-8376-b00fd1598a28.jsonl`.
The scratch-home restore was placement-only. Arm A resumed from a different cwd
with the real scrubbed HOME, recalled `amber-1786593798`, reported the new cwd,
and grew the original rollout from 33,404 to 40,357 bytes. Arm B moved that
run's original rollout to
`/tmp/cmux-remote-lab/run-1786593798/moved-aside/sessions/2026/08/12/`, asserted
the source was absent, restored the bundle into the real `~/.codex`, and
resumed again from the same different cwd; the restored rollout grew from
33,404 to 40,485 bytes. Therefore the rollout JSONL alone at its dated relative
path sufficed in this environment. No Codex cwd rewrite is implemented.

## 8. Auth model (“non sus”)

### Agent authentication

Option A (recommended v1) is a one-time device-code or setup-token OAuth flow
performed by the user on the VM (`claude login`/setup-token and `codex login`).
The resulting agent cache remains on that VM and is never placed in the bundle.
It is auditable, revocable by the provider, and does not make cmux a bearer-token
broker.

Option B is a backend-brokered, short-lived agent credential minted just before
restore and erased after enrollment. It improves unattended restore but makes
the control plane security-sensitive and provider-specific.

Option C is a team secret/API-key input. It is operationally simple but has the
worst rotation and blast-radius properties; it is a later enterprise escape
hatch, not a default.

### Git and GitHub authentication

v1 needs no Git auth on the VM because the control plane transfers a bundle.
For hidden-ref v2, weigh a brokered short-lived read credential against a
GitHub App installation token (repository-scoped, server-minted) and a per-VM
deploy key (simple but difficult to rotate). The user's long-lived PAT is not a
valid design.

**Never copy local keychain/OAuth tokens, shell-rc secrets, auth.json files, or
environment secrets.** The existing VM lease schema stores `tokenHash` and an
expiry (`web/db/schema.ts:202-228`), while the daemon slot keeps a local
`auth.token` and lock (`daemon/remote/cmd/cmuxd-remote/main.go:615-623`). New
handoff leases remain hashed server-side, are short-TTL, and are single-use
where possible. The cmux-tui enrollment prior art (invite URI plus
device approval) and hq's capability-token model (control plane sole minter,
short TTL) are the direction for explicit VM enrollment.

Ignored-file consent is per-file, explicit, and visible in the confirmation UI.
Restored files preserve the recorded mode, with 0600 as the safe default for
new secret files. Before GA, control-plane transit needs client-side encryption;
one concrete candidate is age-style sealing to a VM-held public key, with the
private key created during device-code enrollment and never returned to the
control plane.

## 9. Single-writer enforcement

Parking writes `.git/cmux/handoff.json` containing handoff id, source HEAD,
index digest, worktree digest, and state. The app renders a cloud badge and
surfaces read-only while parked. Recall clears the marker only after verified
restore.

Local enforcement is advisory because another editor can still write the
filesystem. Divergence is therefore detected, not assumed impossible. The
snapshot records post-park worktree and index digests. Recall recomputes both;
on mismatch it refuses to merge silently and offers:

1. discard local edits and accept the remote bundle;
2. abort recall and keep both copies;
3. fork a new lineage with an explicit new handoff id.

While parked, the only supported writer is the VM. The app must disable normal
surface editing and show a legible cloud/connection state. Reconnection does
not change writer ownership.

## 10. Discovery: the second-device gap

Add an account-level `workspace_handoffs` ledger rather than overloading the
VM-session table:

```text
workspace_handoffs
  id                 uuid primary key
  team_id            text nullable
  user_id            text not null
  vm_id              uuid not null
  slot               text not null
  workspace_stable_id uuid not null
  state              offloading | remote | recalling | parked-conflict
  bundle_ref         text nullable
  handoff_ref_id     text nullable
  created_by_device_id text not null
  revision           integer not null
  created_at         timestamptz not null
  updated_at         timestamptz not null
  completed_at       timestamptz nullable
```

API verbs are `POST /api/workspace-handoffs`, `GET /api/workspace-handoffs`,
`GET /api/workspace-handoffs/:id`, `POST .../:id/recall`, `POST .../:id/adopt`,
and an idempotent upload-complete transition. Every mutation carries the
expected revision.

A second Mac lists rows for its Stack user/team, shows the workspace name,
branch, VM, state, and last update, then adopts a row. Adoption mints a new
lease and relay auth for that device; relay id/token are never persisted in the
ledger or bundle. This is the missing RS-007 “second Mac discovers/selects a
slot” acceptance item in #8116. RS-008 (a baked VM daemon advertises the
capability) is likewise still TODO.

`cloud_vm_sessions` is the precedent for status/attachment accounting but is
VM-scoped, keyed by provider session id, WebSocket-path-only, and lacks stable
workspace identity (`web/db/schema.ts:232-264`). The devices registry is
explicitly best-effort rendezvous, not pairing authority
(`web/db/schema.ts:810-822`; `web/app/api/devices/route.ts:1-11`). Hive M2/M3
needs this ledger to make workspace mobility account-visible.

## 11. Position on feat-remote-runtime-persistent-sessions (#8116)

**Adopt the Go daemon layer and Swift transport files; re-apply them onto main.
Redo the app-target integration and payload contract.**

The branch's Go runtime-state layer is self-contained: durable per-slot state,
fsync+rename, revision-conflict handling, and coalesced subscribers are the
right substrate. The transport changes merge cleanly. The app integration does
not: main has substantial `Workspace.swift` and `RemoteSessionCoordinator`
churn, and the conflict surface is plumbing rather than new state logic.

The branch's whole `SessionWorkspaceSnapshot` payload, hard-gated on exact
`schema_version == 1`, is wrong for handoff. The struct can add fields while
publishing silently different blobs under the same version, and there is no
migration path. Replace it with an explicit versioned handoff/workspace-state
document. The bundle manifest and runtime-state blob share the same schema
version family, but each has a documented envelope and migration policy.

Land in this sequence:

1. Go runtime-state and transport, with capability advertisement and CLI relay
   tests, as a small substrate PR.
2. Define and test the bundle/runtime-state document and conflict semantics.
3. Re-implement app integration against the current Workspace and coordinator
   APIs, then connect offload/recall to one action path.
4. Re-litigate the branch's 256 KiB→4 MiB stdout buffer bump separately; it is
   unrelated risk and must not sneak into handoff approval.

## 12. CLI and naming decision

`cmux remote` stays the device-registry command because it is already an alias
of `cmux remotes` (`CLI/cmux.swift:4488-4489`). Reusing it for migration would
break scripts and make “remote device” ambiguous.

`cmux vm handoff` is an existing informational VM-status printer
(`CLI/cmux.swift:4442-4458`). Fold or rename that informational verb during the
CLI implementation, with a compatibility note; it must not compete with a
workspace handoff.

The new verbs live in the existing workspace family:

```text
cmux workspace offload [--vm <id> | --new-vm]
cmux workspace recall
cmux workspace handoffs list
cmux workspace handoffs status <id>
```

UI copy is “Move to Cloud” and “Bring Back”. Socket methods are
`workspace.offload`, `workspace.recall`, and `workspace.handoff.status`.
The coordinator follows `docs/cli-contract.md` and
`skills/cmux-socket-policy`: resolve one target, validate on the app's serial
mutation path, and return the authoritative result. Keyboard shortcut, command
palette, context menu, CLI, and (later) iOS all call that same action path, as
required by the shared-behavior policy.

The Go relay needs a hand-written namespaced case in `cli.go`. Its generic table
does not cover namespaced families; today `workspace` relay supports only
`group` (`daemon/remote/cmd/cmuxd-remote/cli.go:190-202`). The new capability
string must be in `hello` alongside the existing list
(`daemon/remote/cmd/cmuxd-remote/main.go:1770-1793`).

## 13. UX flows

Explicit actions ship first: context menu, command palette, and CLI all invoke
the shared offload/recall action. The confirmation shows branch, dirty split,
ignored-file list, agent state, VM destination, and scrollback loss.

The sidebar shows a cloud badge and a distinct connection state. A frozen input
surface must never look connected; #8382's remote-tmux lesson applies. During a
turn-boundary wait, show “Waiting for agent turn to finish” with an explicit
interrupt choice and the possible loss.

Completion notifications use the existing hook→gate→push pipeline documented
for agent hooks (`docs/agent-hooks.md:46-54`). Routing is by Stack user id and
is host-agnostic, so iOS can receive “Moved to Cloud” or “Brought Back” without
inventing a second notification protocol.

Auto-offload on lid close is later and trust-gated. The seam is
`prepareRemoteSessionForSystemSleep` (`Sources/AppDelegate+RemoteSessionPower.swift:6`
and `Sources/Workspace+PersistentRemotePTYReattach.swift:4`); it should call
the same coordinator only after the user enables the policy. Auto-recall on
open is an option, never an implicit transfer.

## 14. Failure modes

| Failure | v1 behavior |
|---|---|
| Agent is mid-turn | Wait for Stop/turn boundary by default. Explicit interrupt records that at most the in-flight turn may be lost. |
| Dirty or unpushed submodule | Refuse by default. `--allow-dirty-submodules` records path, index SHA, worktree SHA, and a lossy warning. |
| VM dies while remote | Bundle and ledger row survive. Offer restore onto a fresh VM and leave the old row inspectable. |
| Network loss during transfer | Upload is atomic; ledger changes only after durable object commit. Retry by handoff id. |
| User edits parked local copy | Recompute index/worktree digests at recall; enter parked-conflict and offer discard, abort, or fork. |
| Resume command fails on VM | Workspace status and notification show the exact failure; leave the PTY alive for inspection. |
| Ignored-file consent/encryption fails | Abort before upload; do not leave a partial secret payload as a successful row. |
| Agent/OS clock or version skew | Record Claude/Codex versions in manifest; warn or require explicit override for incompatible versions. |
| Submodule object unavailable | Restore fails loudly with the pinned SHA and URL; the bundle does not pretend to contain submodule objects. |

## 15. Composition with adjacent work

### Hive #8000, M3a #8081, and M5

This is the workspace-mobility pillar of hive #8000. M3a #8081 describes the
same detach-to-remote primitive. H0/H1 ship snapshot/restore and an account
ledger; M5's runtime-backed-local later makes offload a pure retarget because
the runtime already owns the durable session. The bundle remains the recovery
and cross-device transport contract.

### Remote tmux #8382

Remote tmux mirrors a foreign tmux process and is a separate product. It does
not restore app state after relaunch. Both features use persistent daemon PTYs,
but only workspace handoff owns the cmux workspace ledger and agent bindings.

### VM snapshot/fork/restore

`cmux vm snapshot/fork/restore` is disk-level VM lifecycle state; handoff is
logical workspace state with Git/agent semantics. A VM snapshot may later carry
scrollback, environment caches, and package indexes as an optimization, but it
cannot replace bundle verification or single-writer reconciliation.

### Surface resume

The `.local`/`.persistentSSH` flavors from #8441 extend with handoff context.
The #10049 synthesized directory-scoped fallback (`claude --continue ||
claude`, `codex resume --last || codex`) is a later tier for hookless agents,
only after a confirmed-dead PTY. #6434 forbids re-deriving identity through
process sniffing; hooks and explicit bindings remain authoritative.

### Render suspend #5497

Render suspend reduces the laptop-as-single-point-of-failure for local work;
handoff removes it by moving logical state. They are orthogonal local and cloud
tiers, not competing migrations.

### BYO VPS #8003

The later BYO VPS path can use the same daemon protocol and portable bundle
transport without the Cloud VM control plane. Its auth/enrollment and billing
are intentionally not designed in this document.

### Remote-origin constraint #9657

Offloading a workspace that was already remote must be addressed after v1. The
current remote-session path cannot spawn Cloud-VM workspaces (#9657). The ledger
must preserve origin and require an explicit retarget policy before allowing a
remote→Cloud handoff.

## 16. Resume-fidelity findings (D3)

The lab was run with:

```text
env -i HOME="$HOME" PATH="$PATH" USER="$USER" SHELL="$SHELL" TMPDIR="${TMPDIR:-/tmp}" TERM=xterm-256color LANG=en_US.UTF-8 claude ...
env -i HOME="$HOME" PATH="$PATH" USER="$USER" SHELL="$SHELL" TMPDIR="${TMPDIR:-/tmp}" TERM=xterm-256color LANG=en_US.UTF-8 codex ...
```

The run created only fresh ids. The Claude transcript is from
`/tmp/cmux-remote-lab/run-1786592839/`; the Codex transcript and two-arm result
are from `/tmp/cmux-remote-lab/run-1786593798/`. Their `findings.md` and `logs/`
contain the commands and trimmed outputs below. No credential file was read or
printed.

### Claude command transcript

Create (Claude 2.1.229):

```text
cd /tmp/cmux-remote-lab/run-1786592839/src.dot_under
claude -p --session-id 068bf963-cf47-4ceb-8307-11d833e3ec10 \
  --model claude-haiku-4-5-20251001 \
  "For this lab, the codeword is cobalt. Reply with exactly OK."
stdout: OK
```

The transcript directory was
`~/.claude/projects/-private-tmp-cmux-remote-lab-run-1786592839-src-dot-under/`.
The observed transform replaced `/`, `.`, and `_` with `-`.
Snapshot and restore were:

```text
python3 /Users/cmux/manaflow/term/cmux201/scripts/cmux-workspace-handoff.py snapshot \
  --workspace /tmp/cmux-remote-lab/run-1786592839/src.dot_under \
  --out /tmp/cmux-remote-lab/run-1786592839/claude-bundle \
  --claude-session 068bf963-cf47-4ceb-8307-11d833e3ec10 --claude-home /Users/cmux/.claude
python3 /Users/cmux/manaflow/term/cmux201/scripts/cmux-workspace-handoff.py restore \
  --bundle /tmp/cmux-remote-lab/run-1786592839/claude-bundle \
  --dest /tmp/cmux-remote-lab/run-1786592839/dst.dot_under \
  --claude-home /Users/cmux/.claude --claude-cwd-mode verbatim
```

Resume:

```text
cd /private/tmp/cmux-remote-lab/run-1786592839/dst.dot_under
claude -p --resume 068bf963-cf47-4ceb-8307-11d833e3ec10 --model haiku \
  "What codeword did I give you, and what is the absolute path of your current working directory?"
The codeword you gave me is cobalt.
The absolute path of my current working directory is
/private/tmp/cmux-remote-lab/run-1786592839/dst.dot_under.
```

The destination slug was
`-private-tmp-cmux-remote-lab-run-1786592839-dst-dot-under`, and the destination
JSONL received the resumed turn. Verbatim restore was sufficient: no cwd-bearing
JSONL rewrite is required for resume.

### Codex command transcript and two-arm result

Create (Codex CLI 0.147.0):

```text
cd /tmp/cmux-remote-lab/run-1786593798/src
codex exec --json -c model_reasoning_effort=low --sandbox read-only \
  "Remember this codeword and nothing else: amber-1786593798. Reply OK."
{"type":"thread.started","thread_id":"019ff949-f082-7e01-8376-b00fd1598a28"}
{"type":"item.completed","item":{"type":"agent_message","text":"OK"}}
rollout: ~/.codex/sessions/2026/08/12/rollout-2026-08-12T21-03-20-019ff949-f082-7e01-8376-b00fd1598a28.jsonl
```

The first restore was placement-only in a scratch Codex home and was not
resumed. Arm A then ran from a different cwd with the real scrubbed environment
(HOME remained the authenticated store; no `CODEX_HOME` override):

```text
cd /tmp/cmux-remote-lab/run-1786593798/codex-dst
codex exec resume 019ff949-f082-7e01-8376-b00fd1598a28 --json \
  -c model_reasoning_effort=low \
  "What codeword did I give you, and what is the absolute path of your current working directory?"
{"type":"item.completed","item":{"type":"agent_message","text":"amber-1786593798; /private/tmp/cmux-remote-lab/run-1786593798/codex-dst"}}
exit: 0
rollout grew: 33404 → 40357 bytes (the original rollout)
```

Arm B answered the new-machine file-set question. The run moved the original
rollout to
`/tmp/cmux-remote-lab/run-1786593798/moved-aside/sessions/2026/08/12/rollout-2026-08-12T21-03-20-019ff949-f082-7e01-8376-b00fd1598a28.jsonl`, asserted the original was absent, restored the bundle into the real
`~/.codex` dated path, and ran the same resume from `codex-dst`:

```text
python3 /Users/cmux/manaflow/term/cmux201/scripts/cmux-workspace-handoff.py restore \
  --bundle /tmp/cmux-remote-lab/run-1786593798/codex-bundle \
  --dest /tmp/cmux-remote-lab/run-1786593798/codex-dst \
  --codex-home /Users/cmux/.codex
codex exec resume 019ff949-f082-7e01-8376-b00fd1598a28 --json \
  -c model_reasoning_effort=low \
  "What codeword did I give you, and what is the absolute path of your current working directory?"
{"type":"item.completed","item":{"type":"agent_message","text":"amber-1786593798; /private/tmp/cmux-remote-lab/run-1786593798/codex-dst"}}
exit: 0
restored rollout grew: 33404 → 40485 bytes
```

Arm A proves resume from a different cwd. Arm B proves that, in this
environment, the rollout JSONL alone at its dated relative path sufficed; no
additional Codex history/index file was needed. The restored copy remains in
the real Codex store and the moved-aside original remains under the run dir.

### Evidence table

| File/dir/field | Resume required? | Rewrite needed? | Evidence |
|---|---:|---:|---|
| Claude project slug directory | Yes, for lookup | Yes, destination slug placement | Dotted/underscore source proved `/`, `.`, and `_` all become `-`; destination-slug JSONL resumed successfully. |
| Claude session id | Yes | No | `--resume 068bf963-...` recalled `cobalt`. |
| Claude `cwd` fields | No for lookup | No in v1 | Verbatim arm reported the actual dotted destination cwd and appended to destination slug. |
| Claude todos | Not exercised by the one-turn leg | Copy unchanged | Prototype captures matching todo files; fake-home test verifies placement. |
| Codex rollout JSONL | Yes | No | Arm A resumed with real HOME; Arm B restored only this rollout at its dated path and resumed successfully. |
| Codex dated directory | Yes for lookup | Preserve relative path | Actual dated rollout path was preserved in both placement and real-home restore. |
| Codex cwd fields | No | None | Both arms reported `/private/tmp/cmux-remote-lab/run-1786593798/codex-dst`. |
| Relay id/token | No | Always mint fresh | Attach code generates them (`CLI/cmux.swift:10734-10743`); they are not in snapshots. |

Each leg is intentionally one short create turn and one short resume turn. The
lab is manual and token-spending because fake JSONL would not answer the
load-bearing lookup question; CI remains hermetic.

## 17. Prototype shipped in this PR

`scripts/cmux-workspace-handoff.py` is stdlib-only and has `snapshot`, `restore`,
and `verify` subcommands. Every subcommand accepts `--json`.

Minimal invocation:

```bash
python3 scripts/cmux-workspace-handoff.py snapshot \
  --workspace /path/to/repo --out /tmp/handoff-bundle
python3 scripts/cmux-workspace-handoff.py restore \
  --bundle /tmp/handoff-bundle --dest /tmp/restored-repo
python3 scripts/cmux-workspace-handoff.py verify \
  --source /path/to/repo --restored /tmp/restored-repo
```

The manual experiment is deliberately separate:

```bash
scripts/cmux-workspace-handoff-lab.sh --keep
# or --claude-only / --codex-only while debugging one authenticated CLI
```

Snapshot never mutates the source index, worktree, refs, stash, or config. It
uses temporary `GIT_INDEX_FILE` copies, deterministic commit identity/date,
and a temporary `refs/cmux/handoff-tmp/<uuid>` deleted before exit. It refuses
dirty submodules unless explicitly allowed, copies only consented ignored files,
and captures only the session ids supplied on the command line.

Restore requires an absent or empty destination, fetches the self-contained
bundle, recreates branch/detached HEAD, writes the worktree tree, deletes
tracked deletions before extracting untracked paths, restores the real index,
initializes and verifies submodule pins, and refuses to overwrite an existing
same-id agent file. It prints suggested Claude and Codex resume commands.

Verify compares branch/HEAD, binary-safe raw staged and worktree diffs, sorted
untracked content hashes, and submodule SHAs. It exits nonzero with JSON detail
on mismatch.

`scripts/cmux-workspace-handoff-lab.sh` is headed “manual runbook — spends
agent tokens; NOT run in CI”. It creates the scratch Git repository, non-tip
local bare submodule, split edits, ignored file, dotted/underscore Claude
repository, logs, findings, and both Codex arms under
`/tmp/cmux-remote-lab/run-<epoch>/`. It never targets this clone and never
prints credential contents. Arm A resumes with the real scrubbed HOME; Arm B
moves this run's original rollout aside, restores into the real dated path, and
leaves the restored copy plus moved-aside original for inspection.

The automated tests are hermetic `unittest` subprocess tests. They use only
temporary repos and fake agent homes, cover all prototype invariants, and do
not spend agent tokens. Agent-resume validation remains manual because it needs
authenticated CLIs and provider state; pretending a fake JSONL is a resume
would validate the wrong load-bearing unknown. The definitive lab demonstrates
Claude codeword recall after dotted/underscore restore and Codex success in both
different-cwd and rollout-only arms.

## 18. Phased milestones

### H0 — this PR: design, prototype, findings

- The design names MOVES, RECREATED, and LOST-v1 fields and a versioned bundle.
- Snapshot/restore/verify pass the hermetic test cases, including dangling
  symlink verification and absent-agent-binary handling.
- The lab passes Git fixture verification and shows Claude codeword recall from
  a dotted/underscore different directory; Codex succeeds in both real-home
  resume arms.
- No app, daemon, web, Swift, changelog, or release files change.

### H1 — production transfer primitive

- `workspace offload|recall` works on Linux Cloud VM with atomic bundle upload.
- Ledger v0, park marker, single-writer state, dirty-submodule policy, and
  explicit ignored-file consent are persisted and retryable.
- Persistent daemon slot reattaches or launches one approved resume command.
- Completion/failure notifications use the existing hook→gate→push route.

### H2 — seamless UX and discovery

- Sidebar cloud badge and connection-state copy are legible during reconnect.
- Context menu, palette, CLI, and second-device adoption use one coordinator.
- Turn-boundary wait and bring-back divergence choices are dogfood-tested.
- Account-level handoff listing mints a new lease/relay auth on adoption.

### H3 — automatic lifecycle and scrollback

- Lid-close auto-offload is opt-in, trust-gated, and uses the sleep seam.
- Auto-recall on open is an explicit setting with a visible progress state.
- Daemon scrollback is carried when available and clearly labeled best-effort.
- `listeningPorts` becomes a restart hint for selected non-agent processes.

### H4 — BYO VPS and hive convergence

- Bundle transport works through a proxyless SSH daemon without Cloud VM APIs.
- Remote-origin offload has an explicit retarget policy (#9657).
- Hive M5 runtime-backed-local can turn handoff into a runtime retarget without
  changing the user-facing ledger or conflict semantics.
- Git hidden-ref optimization has TTL cleanup and short-lived read credentials.

## 19. Non-goals and open questions

### Non-goals

- Live process migration or CRIU-style kernel checkpointing.
- Multi-writer collaborative editing or conflict-free replicated workspaces.
- Non-Git workspaces in v1.
- Windows support.
- Copying keychain, OAuth, API-key, shell-rc, or arbitrary environment secrets.
- Restoring arbitrary running non-agent processes or promising terminal pixels.

### Open questions

- Which age-style client-side encryption envelope should seal consented ignored
  files, and how is the VM-held key rotated after VM replacement?
- Should hidden-ref Git reads use a brokered credential or GitHub App token, and
  what is the exact TTL/garbage-collection SLA?
- What Claude/Codex version skew is safe, and when should restore require an
  explicit user override rather than warn?
- Which Codex history/index files are required beyond a rollout JSONL?
- Should a multi-repo workspace be one manifest with several bundles or a
  higher-level atomic handoff containing multiple repository manifests?
- How should an unpushed submodule be transferred without silently changing
  its provenance?
- Does a remote-origin workspace recall to local before it may offload to a
  different VM, or can the runtime retarget directly?
- How long should parked-local conflict rows remain discoverable on a second
  device, and who may adopt a team-owned row?

Localization audit: not applicable. This PR adds only a contributor design
document and developer tooling; no user-facing app string or localization
catalog is changed.

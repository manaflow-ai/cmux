# Repository checkpoints and rewind

Status: slice 2 approved sequence, 2026-10-02. Explicit capture first, reviewed restore with Undo second, then automatic snapshots at handoff and before agent turns that can edit files. The existing session-host Git owner handles snapshots; this workstream owns the UI. Operation names are agreed with the Git owner; payload details are pinned before implementation. This plan does not change the handoff v1 contract.

## Recommendation

Start with an explicit **Create checkpoint** action that captures repository file state without changing HEAD, the user's index or their worktree. Store immutable content under local `refs/cmux/checkpoints/` refs. Show eligible untracked files as a preselected inline list in Changes; the Create action approves the checked list and visible omissions without a separate selection step or sheet. Use the resulting ref in the existing handoff review, with its explicit attestation unchanged.

Add **Restore checkpoint…** after capture has proven exact round trips and crash recovery. Restore is a reviewed, scoped file operation with a fresh safety checkpoint and one-click Undo. It never rewinds conversation, changes branches, restarts a harness or claims to reverse commands, network calls or external effects. Automatic captures at handoff and later at reliable turn boundaries follow these two slices.

The value is independent of the harness: a Claude Code, Codex or terminal-only session can preserve the same index/worktree state. The cost is repository correctness and disk retention, rather than eight harness-specific implementations. A checkpoint records bytes, file type, executable bit and staged state within its stated scope. It is not a filesystem backup, a sandbox or a guarantee that unrelated processes cannot write files.

## Current foundations and overlap

Inspected `origin/feat-cmux-next` at `994f80b2128` and GitHub on 2026-10-02. Open PR state can change; refresh it before implementation.

| Foundation | Verified evidence | Reuse or gap |
| --- | --- | --- |
| Harness-agnostic plan | [harness-agnostic.md](harness-agnostic.md), merged [#16892](https://github.com/manaflow-ai/cmux/pull/16892) | Names checkpoints as high-value cmux ownership; manual checkpoints precede automation. |
| Cross-harness handoff | [#16905](https://github.com/manaflow-ai/cmux/pull/16905), open at `690e4ff87d3`; agreed daemon contract is owned by the acpmux parity workstream | Review already accepts a checkpoint `{ref, attest:true}` and approved memory references. The UI is hidden until all five handoff operations are advertised. Snapshot capture can supply the ref without bypassing review. |
| Repository reads | [#16766](https://github.com/manaflow-ai/cmux/pull/16766), merged at `c055bc1`, targeting `feat-cmux-next-acpmux` | `git.status` and `git.diff` run on the repository's session host. Reuse target resolution, path validation, sanitized Git environment, output bounds and deadlines. These are stateless reads, not a snapshot store or serialized mutation owner. |
| Changes pane | [model.ts](../../webviews/src/agent-session/acpmux/changes/model.ts), [useScopeChanges.ts](../../webviews/src/agent-session/acpmux/changes/useScopeChanges.ts), [FileMenu.tsx](../../webviews/src/agent-session/acpmux/changes/FileMenu.tsx) | Existing staged/unstaged/uncommitted scopes and bounded diff rendering can show capture and restore previews. Current source still names `git.scope.diff`; #16766 names `git.diff`. Follow the integration owner's migration rather than adding another adapter. |
| Session checkpoints | [journal_checkpoint.rs](../../cmux-tui/crates/cmux-tui-core/src/journal_checkpoint.rs) | Captures terminal replay/public session state. It does not preserve repository files and must not be repurposed as a git rewind record. |
| Ownership/catalog | [OWNERSHIP-PRINCIPLES.md](OWNERSHIP-PRINCIPLES.md), [ownership.md](ownership.md), [actions.md](actions.md) | Typed intents, persistent retry keys, owner-side destructive policy, no offline queue, generated surfaces and user-only focus. |

The inspected open PR search for snapshot/checkpoint/rewind/git found no separate repository snapshot writer. This does not reserve another team's Git owner. Coordinate with the acpmux parity and store owners before adding one.

The existing `git_ops/run.rs` is read-only: it drops inherited `GIT_*`, uses `GIT_OPTIONAL_LOCKS=0`, forces fsmonitor off/literal paths, bounds output and kills the process group after 20 seconds. Keep it unchanged. A sibling write runner permits only explicitly supplied temporary `GIT_INDEX_FILE` state, uses real Git locks, sanitizes inherited environment/configuration and reconciles uncertain writes at safe boundaries. Explicitly disable hooks with an owner-controlled empty hooks directory: update-ref can run `reference-transaction` hooks. `git.diff` may cap untracked reads and report `untracked_skipped`; checkpoint capture must instead refuse with the count or return reviewed omissions, never silently cap.

Git's [update-ref transactions](https://git-scm.com/docs/git-update-ref), [alternate index support](https://git-scm.com/docs/git), [raw blob storage](https://git-scm.com/docs/git-hash-object), [tree writing](https://git-scm.com/docs/git-write-tree) and [worktree administrative directories](https://git-scm.com/docs/git-worktree) are the underlying primitives. [Git attributes](https://git-scm.com/docs/gitattributes) explain why ordinary add/checkout can run filters or transform bytes. [Git GC](https://git-scm.com/docs/git-gc) explains why removing a ref does not immediately reclaim its objects. [Push mirror behavior](https://git-scm.com/docs/git-push) means a local ref namespace is not a confidentiality boundary.

## Ownership and durable record

Approved owner: the existing session-host Git resource owner, `OperationOwner::Git`, dispatching through `git_ops::dispatch`. Extend that owner with a serialized repository mutation service, rather than introducing another Git owner. Reuse `target.rs` resolution and the `Repository` wrapper (`root`, `base_branch`): a repository path or workspace/pane/tab/terminal selector resolves on that host; explicit paths must be absolute. The workspace store keeps only checkpoint IDs referenced by tabs or handoffs; clients render owner records and send intents. The handoff owner continues to own capsule revisions, attestations and prompt delivery.

Identify the repository by canonical common Git directory plus a daemon-minted repository ID, and the worktree by canonical per-worktree Git directory plus a stable worktree ID. Do not key by a display path, cwd substring, branch name or session ID. Resolve the cwd to its repository root once at the owner. Worktrees share the object database, but have distinct indexes, paths and checkpoint histories. A repository moved or replaced must be rebound explicitly, never inferred from matching HEAD alone.

A checkpoint record includes:

- `checkpointId`, `repositoryId`, `worktreeId`, local ref, immutable object ID, record version and sequence.
- Base HEAD object ID or unborn marker, branch/detached identity, and observed index fingerprint. These are context, not instructions to move HEAD.
- Separate index, tracked-worktree and approved-untracked trees, plus included-path/tombstone manifests and omission records. An absent path differs from an empty file.
- Scope/policy revision, source session/turn when verified, capture reason and timestamp, caller identity, logical bytes and estimated newly stored bytes.
- Coverage by item: included, omitted or unavailable, with a reason. Only mark a scope complete when every eligible path is represented. Never label file capture as native-policy enforcement or host isolation.
- Pin reasons, expiry eligibility and restore receipts. Create returns an explicit `skipped[]` list and `complete:false` whenever a considered file is over the untracked limit or otherwise skipped; no silent caps or complete labels with omissions. A non-discarded handoff reference or active restore journal pins its checkpoint until the owner releases that reference.

Put the three content trees and a metadata blob into a synthetic root tree referenced by an immutable synthetic commit. This makes Git GC trace every stored object without relying on JSON object IDs as reachability edges. Do not attach the synthetic commit to a branch, `refs/stash` or HEAD. Record the base HEAD in metadata; a snapshot does not need to retain the whole base history through a commit parent.

Namespace proposal: `refs/cmux/checkpoints/<worktree-id>/<checkpoint-id>`. Create refs with an expected nonexistent old value; deletion uses the expected object ID. Ref publication is atomic, but the ref and the owner's database are not one filesystem transaction. Journal the intended ref/object/ledger result first, publish the ref, then commit the ready record and reply. Startup reconciles a published-but-unacknowledged ref to the original request key. An unpublished capture is not usable. Never return a ready checkpoint before both reachability and its record are durable.

"Private" means locally owned and absent from ordinary branch/tag pushes. Explicit refspecs, `git push --mirror`, repository copies and backups can include it. Do not change user remote configuration to hide refs or claim encryption. Keep raw file contents and personal memory out of logs, telemetry, cloud sync, PR evidence and exported capsule text. Store the owner ledger/journals with user-only permissions. Purging refs cannot promise secure erasure from Git objects or backups.

## Scope and file fidelity

| Case | Capture and restore rule |
| --- | --- |
| Tracked stage-0 files | Default eligible scope, minus explicit exclusions. Capture the index object/mode independently of raw worktree bytes, including deletions and different staged/unstaged versions of the same path. Restore both representations. |
| Untracked files | Explicit selection in the inline Create action, nonignored files strictly below 10 MB; only eligible selected paths are owned by that checkpoint. New untracked files after capture remain untouched unless specifically included in the restore review. Never run `git clean`. |
| Ignored files | Omitted by default, including ignored files beneath selected directories. No automatic ignored-file opt-in in the smallest slice. Show count/reason. Already tracked files still need the tracked-file exclusion policy. |
| Secret paths | User-configured exclusions and initial common credential patterns apply to tracked and untracked files before new blob storage. Gitignore and name patterns cannot prove absence of secrets. Show exclusions, preserve excluded index/worktree paths, and explain that existing tracked objects may already contain those bytes. Explicit later overrides require review, never a silent agent override. |
| Symlinks | Record the link's literal target and Git symlink mode; never follow a leaf link during capture. Restore a link itself, not its target. Every parent component must be a directory without symlink traversal; parent substitution is a conflict. |
| Binary/large files | Raw blobs round-trip bytes. Preflight per-file and total budgets; reject or explicitly omit before publication. Never quietly truncate a checkpoint. A tracked omission makes scope coverage partial. |
| Filters, EOL and LFS | Store raw worktree bytes with filters off. The index tree retains staged Git objects, which may be LFS pointers. Never fetch LFS data or run clean/smudge/process filters; an unavailable raw payload is unavailable coverage. Restore raw captured bytes rather than a checkout transformation. |
| Submodules | Preserve gitlink entries only; do not descend. Dirty/uninitialized submodules or changed gitlinks make recursive coverage unavailable. The smallest restore slice refuses changed submodule paths and dirty submodules rather than imply nested files are recoverable. |
| Nested repositories | Do not descend into an untracked nested Git repository. Mark unavailable; separate repository checkpoints are a future composition. |
| Sparse/split index, unresolved stages, intent-to-add, assume-unchanged/skip-worktree | First slice refuses these index modes with a typed reason. Later support needs explicit flag/extension round trips, not a flattened stage-0 tree advertised as exact. |
| Unborn/detached HEAD | Capture is supported with a nullable base HEAD and explicit identity. Restore still requires the same base identity; it does not create a commit or reattach a branch. |
| Names and metadata | NUL-delimited Git output and byte-preserving relative paths. Escape display names; support spaces/newlines/non-UTF-8 names without shell interpolation. Preflight case/normalization and file/directory collisions on the host filesystem. Git modes preserve executable bits, not ownership, ACLs, xattrs, resource forks, timestamps or empty directories. |

A full index tree containing excluded entries would retain their content and weaken the exclusion policy. Construct a scoped index tree instead, with an explicit eligible path set; restore merges only those entries into the current index. Do not archive the user's raw index as the permanent checkpoint representation. Temporary recovery copies stay local and protected and are removed only after the journal is settled.

## Capture protocol

1. Resolve the repository/worktree and validate the scope, settings, supported index format, path types, budgets and advertised capability. A caller supplies a stable `idempotency_key`; the ledger binds it to the arguments. A reused key with different arguments is an error.
2. Acquire the repository owner's common-directory mutation lease, then the worktree capture fence. All cmux Git writes, ref changes, captures and restores use this path. Ordinary read ops remain bounded and return a snapshot/freshness token. Git's index/ref locks remain mandatory in addition to the actor.
3. Refuse an active or queued source for explicit handoff capture; do not implicitly cancel a turn. A verified idle barrier is useful; it is not a filesystem lock. Ask the user to pause other repository writers. External editors, terminals, hooks and other daemons can still change files; cmux does not claim to serialize their effects.
4. Read index/HEAD identity and an eligible-path manifest. Use an alternate temporary index for tree construction, sanitized `GIT_*` state and explicit Git configuration. Disable fsmonitor, hooks, external diff, textconv and all configured filters. Use literal pathspecs and direct argv, never shell commands from repository content.
5. Open regular files without following links or blocking on devices/FIFOs. Hash/store raw bytes and symlink targets. Verify the complete included path set, file type/content fingerprints, index and HEAD again before publishing. A changed observation is `repository_changed`, not a successful mixed checkpoint. This is validated observation of a quiet repository, not an atomic filesystem snapshot.
6. Durably publish the synthetic object/ref and ledger result as described above. Reply with an immutable record and coverage. Failure leaves HEAD/index/worktree unchanged; orphaned unpublished objects can become ordinary Git garbage.

Duplicate capture clicks and retries after an uncertain reply return the original checkpoint. Reconnect reads `get` by ID/key before repeating any sent mutation. Offline requests are refused, never queued. Bound read/hash preparation by deadlines and bytes; apply cancellation only at safe mutation boundaries. An uncertain write is reconciled from its journal/ref state before retry. Never apply the read runner's process-group deadline kill in the middle of update-ref, read-tree or checkout-index. No capture polling loop or idle work is introduced.

## Restore, freshness and Undo

The smallest restore applies the whole captured eligible scope, not selected hunks or a merge. Keep branch and HEAD fixed. A mismatch with the checkpoint's recorded base identity is `base_changed`; show the difference and let the user return to that base or use a future explicit transplant flow. Do not silently checkout, reset, rebase or run stash pop.

**Preview** is read-only. The owner returns staged and worktree replacements/deletions, selected untracked effects, omissions, conflict reasons, logical bytes, and an opaque `preview_token` bound to the checkpoint, worktree, scope, index, HEAD, affected paths and policy revision. The Changes pane shows this inline with Restore and Cancel. No extra modal is needed. A palette/menu invocation reveals that review only for its user-origin client; CLI/MCP receive the same bounded structured preview without taking focus.

Any untracked collision, excluded/ignored occupant, symlink parent, unsupported path type, changed submodule, unsupported index mode, dirty busy session, budget failure or recovery-needed journal refuses apply. Paths newly staged since the checkpoint appear explicitly as removals in the preview if they belong to its eligible scope. New unselected untracked files remain untouched and visible as an omission. Never delete an entire directory containing uncaptured children.

**Apply** requires a stable `idempotency_key`, the current `preview_token` and explicit approval of its exact affected scope. Before the first file write, revalidate the token under the lease and capture a pinned safety checkpoint of every path/index entry the operation will change, including absent paths. If excluded data would be touched, refuse rather than bypass the exclusion to make Undo possible. A stale review fails `preview_stale` and requires a new preview; it does not auto-approve changed contents.

Write a durable ordered restore journal containing pre/post fingerprints and steps before changing files. Stage output to protected temporary files on the destination filesystem, validate parent directories without symlink traversal, then acquire and retain the worktree's `index.lock` before the first destructive file write. While that lock is held, revalidate HEAD, the index fingerprint, the preview token and every affected path; a change releases the lock and returns `preview_stale`. Replace leaf paths using descriptor-relative operations, revalidating each path immediately before its step, then construct the desired index and install it while the same lock is held. Git locks do not stop editors or external writers, so fingerprints and the recovery journal remain required. Do not promise atomic visibility across files and index: the journal is the recovery protocol.

After verifying the complete intended result, durably commit the applied receipt, safety checkpoint ID and ledger result, then publish events/reply. Replaying `idempotency_key` returns the original receipt and never reapplies over newer user edits. Other clients observe owner events, not inferred success from a diff.

**Undo** previews and restores the safety checkpoint through the same pipeline. It receives a new key/token and creates its own safety record. If a user edits after the original restore, Undo is stale until reviewed again; it never silently overwrites those edits. Retain the safety checkpoint while its Undo receipt is live.

A failed or interrupted restore is not reported as atomic rollback. With no unexpected writers, the owner can finish or roll back journaled steps by comparing pre/post fingerprints. After restart, get/inspect reports `recovery_required`, the observed partial state and safe choices. Unexpected path/index changes refuse automatic recovery and preserve backups. Block further cmux Git mutations until this journal is resolved. Never erase a user's index lock, guess that an external writer exited, or silently complete a destructive restore on reconnect.

Model the states as `preparing -> ready` for capture and `previewed -> applying -> applied`, with `recovery_required` as a blocking, recoverable restore state and `rolled_back` or `cancelled` as terminal outcomes. While recovery is required, no other cmux Git mutation is accepted; an explicit recovery action must inspect the journal and fingerprints before finishing or rolling back. Test crashes before/after every durable write, ref publication, file replacement and index install. Ref transactions cannot make worktree writes transactional.

## Proposed operations and surfaces

Names agreed with the Git owner follow the existing catalog: core `git.checkpoint.create/list/get/restore`, read `git.checkpoint.restore.preview`, paired pin/unpin, delete and later recovery.get/recovery.apply. Use catalog `idempotency_key` and `preview_token` fields. Repository operations belong in the session-host resource catalog beside `git.diff`/`git.status`; they are not handoff-specific `_acpmux/handoff_*` methods. Avoid inventing a second CLI snapshot implementation inside acpmux.

| Proposed owner op | Kind and repeat key | CLI/MCP and native placement |
| --- | --- | --- |
| `git.checkpoint.create` | mutation, `idempotency_key` | `cmux git checkpoint create --json`; MCP/tool catalog; palette Create checkpoint; Changes scope menu/header action. |
| `git.checkpoint.get` / `git.checkpoint.list` | bounded reads, cursor/barrier | `cmux git checkpoint show|list --json`; MCP/tools; inline history in Changes. |
| `git.checkpoint.restore.preview` | read returning expiring token | `cmux git checkpoint restore --preview --json`; MCP/tools; Restore checkpoint… opens inline Changes review. |
| `git.checkpoint.restore` | mutation, `idempotency_key` + preview token | Same restore verb with explicit apply/token; same UI action path after review. |
| `git.checkpoint.recovery.get` / `git.checkpoint.recovery.apply` | read / mutation, `idempotency_key` | `cmux git checkpoint recover --json`; MCP/tools; inline interrupted-operation action. |
| `git.checkpoint.pin` / `git.checkpoint.unpin` / `git.checkpoint.delete` | mutation, key + expected revision | CLI/MCP; history item menu. Deletion refuses active handoff/Undo/journal pins. |

The first slice exposes only create, get, list, pin and unpin. Restore, recovery and deletion follow in later slices; retention proposals below do not enable automatic pruning in the capture-only slice.

Undo uses the existing preview/restore operations against a safety checkpoint, not a second mutation engine. TUI and app/extension API receive the same generated catalog operations with repository scope. Code mode consumes those tools through its existing owner. Shortcut labels/tooltips use the live `useShortcut(id)` / `withShortcut(label, keys)` bindings, never hardcoded key text. No default shortcut is needed; record that exemption and allow a configurable shortcut through the shortcut registry if introduced. No arbitrary local path or command is added to a remote relay allowlist: target ownership and the relay policy need a separate review before remote exposure.

A later compare-with-checkpoint view can extend `git.diff` with a checkpoint base and reuse its staged/unstaged/untracked scopes. Do not add another diff reader in the capture-only slice.

Advertise a versioned `git-checkpoints-v1` capability and supported operation list, bounds and file/index modes. Unsupported owners hide the native actions and return `unsupported_capability` to automation. Handoff availability remains governed by its five-method negotiation. Common errors use stable codes: `repository_changed`, `base_changed`, `preview_stale`, `path_conflict`, `unsupported_index`, `capture_incomplete`, `budget_exceeded`, `repository_busy`, `recovery_required`, `pinned` and `key_conflict`. Align the final error envelope with #16766 rather than copying its names blindly.

## Handoff integration without weaker review

First, a user runs Create checkpoint while the source is idle, approving the preselected inline untracked list. Existing v1 `CheckpointInput.ref` remains a free string; the snapshot ref can be manually reviewed without changing that contract. In v2, a `checkpoint:<id>` reference can be resolved and validated by the handoff daemon. Automatic non-discarded-handoff retention applies to owner-recognized references/pins. Until that resolution lands, a snapshot used through a free-form manual v1 ref requires an explicit persistent Git-owner pin; the UI must label its retention as user-managed rather than imply automatic handoff recognition. Checkpoint coverage must use create's explicit skipped list and `complete` field. The target chat's existing review displays the stable ref, the checkpoint scope/omissions, base identity and capture time. The user reviews it and explicitly attests; only the handoff daemon stamps `attestedBy`/`attestedAt`. Approved memory references remain a separate explicit selection. A checkpoint ref never grants permission or silently imports memory.

Then offer an automatic capture on **Continue in…**, within the same prepare pipeline and idle barrier. The proposal needs a versioned contract extension: the handoff owner requests the repository owner to capture with a key derived from `handoffId`; records its ID/ref; pins it; and projects typed coverage. Do not mutate the existing v1 shape without agreement. No extra sheet: the capture result is reviewed in the target's first message. Failed or partial capture must be shown and resolved there; it cannot be attested by the UI on the user's behalf.

An immutable successful capture proves which state was recorded, not that the repository stayed unchanged while the capsule was edited. Before start, compare the current repository fingerprint to that checkpoint. If it changed, show stale checkpoint and require a recapture plus fresh review/attestation, or an explicit acknowledgment of the mismatch if that behavior is agreed in the next contract. Never reinterpret an old `attest:true` as acceptance of newly captured bytes. The smallest integration refuses stale state. Leave source session and source files intact on prepare/discard; discard releases only the handoff's pin.

Per-session native-policy/isolation labels stay unchanged. File coverage and checkpoint freshness are distinct from harness context fidelity, enforcement and turn cancellation. A manual archive reference remains available when capture is unsupported, with its existing explicit attestation and clearly manual/unverified scope.

## Retention, budgets and settings

The coordinator approved these trigger, retention and untracked defaults. They ship with the corresponding slices; budgets remain proposals:

| Setting | Proposed default | Rule |
| --- | --- | --- |
| Checkpoint triggers | on demand first; automatically before every handoff and every agent turn that can edit files when automation lands | Integrate with owner-side prompt admission before execution. Without a reliable pre-turn barrier or on capture failure, block protected start by default; only explicit user continuation may proceed with unavailable coverage. No keystroke/tool-event capture. |
| Untracked selection | explicitly approved, not ignored, each file strictly below 10 MB (10,000,000 bytes) | Saved project selection requires user choice. Ignore/exclusion rules and size are rechecked each capture. No silent count cap. |
| Unpinned retention | 50 checkpoints per repository, 7 days | Either bound makes old records eligible across its worktrees; pinned records and every non-discarded handoff reference are never pruned. |
| Repository logical snapshot budget | 512 MiB | Fail capture if projected usage exceeds policy after eligible pruning. Pinned records can prevent pruning. |
| Per capture / per file | 128 MiB / 32 MiB | Bytes checked before storage and during reads. No truncated success. |
| Minimum host free space | 1 GiB plus estimated capture/recovery staging need | Report `budget_exceeded`; do not steal another workload's space. |

Every production default belongs in Settings and `cmux.json`, with docs/default tests. Debug tunables cover deadlines, preview expiry and bounded batch sizes. Automatic pruning is owner-side and event-triggered after capture/delete/pin changes or at startup, not a periodic idle loop. Preview shows what pruning will remove before a user-triggered capture if it changes their history.

Logical bytes are conservative policy accounting; deduplicated Git objects make actual size different. Track newly written objects and filesystem free space too. Git can write loose objects before publication; rejected captures may still consume space until normal garbage collection. Deleting a checkpoint removes only owned refs/metadata using compare-and-swap, never branches, stash entries or another worktree's refs. Do not run aggressive `git gc`, prune shared objects or advertise immediate space recovery. Report actual disk pressure and cooperate with the repository's ordinary Git maintenance. Keep a tombstone/result for deleted IDs long enough to reconcile retries.

## Ordered implementation and validation

1. **Capture owner and explicit UI.** Agree owner/catalog/contract first; real-repository integration tests prove no mutation and stage/worktree/untracked fidelity, exclusions, bounds and idempotent crash recovery. No restore and no automatic trigger in this PR. Show a checkpoint receipt/coverage inline and allow it in manual handoff review.
2. **Reviewed restore and Undo.** Journaled restore on unchanged HEAD, one scope, preflight conflicts, freshness tokens and pinned safety capture. Ship only after fault injection covers every destructive step and a bounded state model verifies no acknowledged replay is applied twice, no unexpected path is overwritten and unresolved journals block new writes.
3. **Automatic handoff capture.** Versioned handoff extension, owner-to-owner keys/pins, fresh review and attestation. Dogfood Claude Code to Codex and back, using the same dirty-repository fixture as the first slice. Capture replaces the manual archive's ref, not the user's review.
4. **Pre-edit-turn capture and richer modes.** Capture before owner-admitted turns that can edit files, using a capability-backed barrier and a stable prompt-derived capture key. Capture failure blocks that automatic protected start until resolved or explicitly continued with unavailable coverage. Reliable turn-boundary receipts, automatic retention, sparse/conflicted index support, multi-repository composition and cross-base transplant after separate designs. No promise of conversation rewind.

Tests use real temporary repositories and the same catalog dispatcher as CLI/MCP. Cases: staged and unstaged versions of one file; staged deletion and unstaged resurrection; approved/unapproved untracked files; excluded tracked secrets; ignored occupants; binaries; executable bits; symlink leaves and parent substitution; filters that would touch a marker; spaces/newlines/non-UTF-8 paths; case collisions; linked worktrees; unborn/detached HEAD; changed branch/HEAD; dirty submodules/nested repositories; unsupported index flags; changed scope/policy; capture/restore bounds; duplicate requests; lost acknowledgements; owner restart; two clients; concurrent external write during capture and review; unexpected changes during recovery; disk full; GC and pinned deletion refusal.

Portable assertions compare raw bytes/types/modes and included index entries before and after, not just `git diff` output. Reducer property tests cover keys, pins, scope and transitions. A small TLA+/exhaustive protocol model covers crashes and repeated replies. Git fixture tests check no hooks/filters execute. Separate runtime tests check every catalog entrypoint and automation focus. Localization/surface/god-file gates run for UI/help additions. Native builds and UI capture use the managed fleet; docs-only planning needs no native build.

Dogfood on a tagged build: create a repository with staged, unstaged and selected untracked notes plus ignored credentials; capture; inspect staged/unstaged Changes; edit again; preview; invalidate preview with a user edit and see refusal; review again; restore; verify the index and bytes; Undo; verify all prior dirty state returns; restart/reconnect during a journaled fault and recover; retry an uncertain restore and see no second application. Preserve the source chat in both handoff directions. Record commands, structured receipts and scrubbed screenshots, with no secret content in evidence.

## Decisions before runtime work

- Confirm the common-directory mutation lease implementation inside the approved session-host Git owner with the store/acpmux owners.
- Pin the agreed catalog payloads, capabilities, error envelope and repository targeting; do not reuse handoff RPC names for filesystem mutations.
- Implement the approved trigger, retention and untracked defaults; agree exclusion patterns and remaining byte/free-space budgets above.
- Approve the inline Changes preview/Undo placement; prototype UI options through the feature workflow before choosing a restore layout.
- Agree the versioned handoff extension and the stale-checkpoint rule before automatic capture starts.

The smallest next PR is explicit capture (create/get/list/pin/unpin) plus a reviewed ref in handoff. Restore, automatic handoff capture and automatic per-turn checkpoints are separate reviewable slices.

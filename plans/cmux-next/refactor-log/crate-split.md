# Lane refactor-crate-split: cmux-tui-core domain crates (2026-10-09)

Append-only log of this lane (refactor brief 2026-10-09). One line per landing under "Landings": date, SHA, what moved where, old -> new lines, gate minutes, measured build change.

Goal: split `cmux-tui/crates/cmux-tui-core` (about 295k lines, 1 crate) into
domain crates. Each step moves one domain into its own crate under
`cmux-tui/crates/`; cmux-tui-core re-exports it at the old path
(`pub use <crate> as <module>;`) so no caller and no `crate::<module>::...`
path changes in the same step. mux.rs and server.rs belong to their own
refactor lanes; this lane never edits them.

## Module graph (feat-cmux-next 2dba648cdbde)

Edges are `crate::<module>` references (root re-exports resolved to their
module). "Closure" is the transitive set of crate-local modules a module needs.

- The crate is one strongly connected tangle: every module that reaches
  `mux` or `server` reaches all 73 others (resource -> request_origin ->
  state -> mux -> server -> ...). So only modules whose closure avoids
  mux/server can move as they are.
- Movable now (closure has no mux/server), by size: cloud_conversations
  3063 (no crate-local deps), fs_ops 2778 (none, unix), platform 2298
  (+windows_processes 451), unix_process_scope 1689 (none), terminal_backend
  1610 (platform, terminal_end, terminal_host_protocol),
  terminal_host_protocol 1311 (none), terminal_host 967
  (terminal_host_protocol), sizing_policy 776, process_resources 648
  (host_exe, windows_processes), image_paste* 1368 (unix), host_exe 489
  (platform), terminal_loss_log 386 + terminal_loss_cause 157 +
  process_identity 123, user_settings 301 (platform), pairing 300,
  terminal_end 270, stream_interrupt 262, remote_relay_state 226,
  conversation_drafts 181, pty_write 169, debug_spans 115, backoff 113,
  terminal_respawn_text 86, conversation_search 77, short_id 65,
  machine_name 35.
- The brief's first candidates all reach mux today through thin edges:
  - terminal_host_runtime (15.8k with its folder): server only for
    `encode/decode_terminal_host_clear_history`, surface only for
    `VT_REPLAY_MAX_BYTES`, plus shell_integration, terminal_metadata and
    program_status (which reach mux). Moving those 2 functions and 1 const
    down (to terminal_host_protocol) and the shell/metadata pieces it uses
    makes it movable.
  - browser (12k): `Weak<Mux>` and the `Surface` enum are threaded through
    the frame/navigation loops (emit_browser_status/dirty/failure, connect,
    open). Needs a small host seam (a trait the mux implements) before a
    move; that is a design step, not move-only, so it comes after the leaf
    crates.
  - surface (14.4k), workspace_registry (39.8k), apps (9.8k), scripts (0.6k),
    git_ops (6k): depend on Mux, resource_router and workspace_registry in
    both directions. They need seams (traits or id-only APIs) first.
  - diagnostics (0.7k): depends on journal_ingress (-> mux).

## Crate order

1. cmux-tui-cloud-conversations: cloud_conversations (3063). No deps.
2. cmux-tui-fs-ops: fs_ops (2778, unix). No deps.
3. cmux-tui-platform: platform, windows_processes, host_exe,
   process_identity, process_resources, unix_process_scope (about 5.7k).
   Prerequisite for 4 and 6 (15 modules use platform).
4. cmux-tui-terminal-host-protocol: terminal_host_protocol, terminal_end,
   terminal_host, terminal_loss_cause, terminal_loss_log, terminal_backend,
   pty_write (about 4.9k).
5. Small leaf utilities that 1-4 or later crates need (backoff,
   stream_interrupt, debug_spans, short_id, machine_name, sizing_policy) go
   with the first crate that needs them, or into cmux-tui-util if two do.
6. cmux-tui-terminal-host-runtime: terminal_host_runtime and its folder,
   after the thin edges above move down (about 16k).
7. cmux-tui-browser: browser, browser/*, browser_provider after the host
   seam (about 12.3k).
8. Later (need seams): surface, workspace_registry, apps + scripts, git_ops,
   journal_*.

godfile-baseline.tsv keys are file paths: moving a baselined file
(platform.rs, unix_process_scope.rs, terminal_host_runtime.rs, browser.rs)
changes its key, so that step also edits the baseline (WINDOW-LITE token).
cmux-tui/scripts/*.py hold 33 hard-coded cmux-tui-core source paths; each
step updates the ones it moves.

## Build-time rule (measured at step 1)

A change in a crate below cmux-tui-core still recompiles cmux-tui-core and
cmux-tui (cargo rebuilds every dependent of a changed path crate). So a leaf
extraction makes only the leaf's own `cargo test -p` fast (12.2 s -> 0.2 s);
`cargo build -p cmux-tui` stays about 14 s, the fixed incremental cost of
cmux-tui-core (295k lines). The build win comes from two moves only:
(a) shrink cmux-tui-core's own compile, so the biggest movable code first;
(b) move code that only cmux-tui uses ABOVE cmux-tui-core (a crate that
depends on core, or into cmux-tui), so edits there never rebuild core.
Order after step 1 follows that: the platform + terminal-host families
(about 10.6k together) and terminal_host_runtime (15.8k) before small leaves;
fs_ops (2.8k) goes next only because it is ready and has no dependents in
core except server/fs_wire.

## Candidates from the mux.rs lane (2026-10-09)

mux/signaled_mutex.rs (std + diagnostics::LockStats + JournalContention),
mux/deadline_fanout.rs (std only) and later mux/provider_authority.rs (std +
zeroize) sit at the bottom of the tangle. They are a few hundred lines, so by
the build-time rule they do not shrink cmux-tui-core's compile in a
measurable way. Decision: not now. They go into a small cmux-tui-sync leaf
crate only when a crate extracted below core needs them (for example the
terminal-host runtime), with LockStats and JournalContention moved with
them. Crate boundary agreed through the chief with the mux.rs lane first.

## Order that shrinks cmux-tui-core's own compile (chief, 2026-10-09)

Priority is by lines removed from cmux-tui-core, biggest first, among
domains that can leave without a design step: platform family 5.7k (step 2),
terminal-host protocol family about 4.9k with the surface consts and
server/protocol_key.rs, terminal_host_runtime 15.8k (after now_ms and
NotificationLevel reach a leaf module), browser 12.3k (after a host seam),
then the seam-gated domains (surface, workspace_registry, apps). Leaves under
1k lines go along with a larger step, never alone. fs_ops (2.8k, ready on
local branch refactor-crate-split-step2) fills a gap only.

## Landings

- 2026-10-09 90f75c91fc9c (code 98fdbdfc9fe7) step 1: cmux-tui-core/src/cloud_conversations/ (8 files) -> crates/cmux-tui-cloud-conversations; cmux-tui-core 295,439 -> 292,376 lines; Testbox gate 8 min; post-land cmux-tui.yml focused run 37892029995 green. Build (32 vCPU, warm, edit in moved code): `cargo test -p <domain> --no-run` 12.2 s -> 0.2 s; `cargo build -p cmux-tui` 14.1 -> 13.6 s (no real change).
- 2026-10-09 75d9ecbb99bf (code f8e3500ec0df) step 2: cmux-tui-core platform, host_exe, process_identity, process_resources, unix_process_scope, windows_processes -> crates/cmux-tui-platform (5,712 lines); cmux-tui-core 292,376 -> 288,158 lines; godfile rows renamed, crash baseline transferred (core unwrap 1643->1626, expect 287->286; platform 17/1; totals unchanged); unix_process_scope test seams behind feature test-support (core dev-dependency only); Testbox gate 9 min; post-land run 37911896855. Build: `cargo build -p cmux-tui` after a core edit about 14.8 s, unchanged.
- 2026-10-09 f8940112fe7b (code 58d36e4504c2) cx-ko2e A1: terminal_host_runtime mod unix snapshot/resize/kitty codecs, hex helpers, PayloadDecoder, put_* (521 lines) -> terminal_host_runtime/shared/codec.rs; pty_size, kitty_graphics_limits_within -> shared/host_state.rs; terminal_host_runtime.rs 9976 -> 9436; Testbox gate 8 min.
- 2026-10-09 41686fae4f6d (code e237adb3a54d) cx-ko2e A2: HostLaunch codec, default-colors codec, clear-history ack, host_launch_failure -> shared/codec.rs; 9436 -> 9155; gate 7.5 min.
- 2026-10-09 ddc4e576947b (code d7b2b36ea79d) cx-ko2e A3: host consts, input_request_is_supported, persist_and_claim_host_exit_after_drain, ViewerSizes, mutate_viewer_sizes -> shared/host_state.rs; 9155 -> 9059; gate 7.5 min. Rest of table A waits for table B seams (HostStream first).

## Lane 2 claims (crate-split lane 2, hq-11, 2026-10-09)

A second crate-split lane takes the movable leaves that steps 1-4 above do
not name. It does not reorder or take any open step of lane 1 (platform,
terminal-host protocol family, terminal_host_runtime, browser, fs_ops stay
lane 1's). Each step is move-only: a new crate under `cmux-tui/crates/`,
re-exported by cmux-tui-core at the old path, one LOCK slot per step.
Lane 2 landing lines carry the prefix "lane 2" in the Landings list.

1. cmux-tui-image-paste: image_paste, image_paste_file, image_paste_ownership,
   image_paste_recovery, image_paste_storage and their tests (1,368 lines,
   unix). The image paste spool: storage dir, owned files, crash recovery.
2. cmux-tui-util: backoff, stream_interrupt, debug_spans, short_id,
   machine_name, terminal_respawn_text, user_settings (1,027 lines). Small
   daemon primitives without daemon state. This is the cmux-tui-util of
   step 5: terminal_host_runtime (lane 1, step 6) uses debug_spans, so a
   crate below core must own it before that move.
3. cmux-tui-remote-access: pairing, remote_relay_state (526 lines). Device
   pairing challenges and the relay peer, pairing record and revocation
   state. Lands in the same slot as 2 (leaves under 1k never go alone).

Not claimed, and why: sizing_policy is already a 7-line re-export of
cmux-terminal-sizing. conversation_drafts and conversation_search (258
lines) belong with conversation_store, which needs
`workspace_registry::{open_registry_database, unix_epoch_ms, new_uuid_v4}`
to move down first; they move with conversation_store, not alone.

Expected build effect (by the build-time rule above): about 2.9k lines leave
core (1%); an edit inside a moved module still rebuilds core and cmux-tui.
Each landing line records the measured `cargo build -p cmux-tui-core` time
after an edit in a moved function, before and after the move.
- 2026-10-09 70bb57f3e77c (code c6e9f47415c6) cx-ko2e B1: seam terminal_host_runtime/sys.rs HostStream (std UnixStream on Unix, uds_windows::UnixStream on Windows); HostTap, SmartStream group, ParserCommand/ParserBudget, enqueue_parser_output -> shared/host_state.rs; terminal_host_runtime.rs 9059 -> 8689; gate 8 min.
- 2026-10-09 5175437db410 (code 8ec38cd5e3f3) cx-ko2e B2a: clipboard-read broker -> shared/clipboard_read.rs (Unix-bound impls stay in unix/clipboard_read.rs); gate 8 min.
- 2026-10-09 bcb887e23aa5 (code 6eb04a08db9e) cx-ko2e B2b: unix/control_responses.rs -> shared/control_responses.rs over HostStream; InputAckReceipt -> shared/attachment.rs; 8689 -> 8629; gate 5 min.
- 2026-10-09 (B3) cx-ko2e B3: HostAttachment (+impl, Drop), send_host_frame, SpawnedHostProcess, connect_record* -> shared/attachment.rs (+ attachment/connect.rs, attachment/terminate.rs) over HostStream; unix/renderer_grant.rs -> shared/renderer_grant.rs (test beside it); read_required_frame -> shared/codec.rs; sys seams connect_with_retry, PtyCustody, record writers (Windows: fail-closed stubs); terminal_host_runtime.rs 8629 -> 7456; cmux-tui-core tests 2681 passed + 10 ignored (#[test] 2690 before and after); gate 5.3 min.
- 2026-10-09 (B4) cx-ko2e B4: records group (validate/liveness/load/stale removal/exit sidecars/exit diagnostic/write_json_record, RECORD_TEMP_SEQUENCE) -> shared/records.rs over new sys seams (FileOwner, file_owner, is_private_file, has_single_link, canonical_endpoint, is_endpoint_file, open_private+PrivateOpen, probe_lease+LeaseProbe, process_definitely_gone, remove_released_pty_lock, remove_terminal_loss_signals, sync_dir, barrier_sync[_dir]); rename_no_replace, prepare_private_dir, prepare_endpoint_dir, connect_with_retry -> sys/unix.rs; Windows: fail-closed stubs in sys.rs; terminal_host_runtime.rs 7456 -> 6864.
- 2026-10-09 (B5) cx-ko2e B5: impl HostAttachment clipboard hooks (clipboard_replier + 4 test hooks) and ClipboardReplier (writer: Weak<Mutex<HostStream>>) -> shared/clipboard_read.rs; unix/clipboard_read.rs keeps only the HostShared-bound timer and reply path.
- 2026-10-09 (B6) cx-ko2e B6: Lease seam, Unix side: HostLivenessLease, TerminalHostResetLock, TerminalHostPublicationLock and the publication-lock functions -> sys/unix/lease.rs; unix/barrier_sync.rs -> sys/unix/barrier_sync.rs; terminal_host_runtime.rs ->     6703 lines.
- 2026-10-09 (B7) cx-ko2e B7: Waker and PtyReadiness seams, Unix side: AcceptWaker -> sys/unix/waker.rs, wait_for_pty_readable_or_forced_drain -> sys/unix/pty_readiness.rs; terminal_host_runtime.rs ->     6605 lines.

# cmux-tui technical-debt board

Last updated: 2026-08-23.
Audit base: `origin/main` at `17466308a52cb53e417e07085f108800efedd267`.
Integration branch: `aggregate-final`.
Current integration code tip before this documentation commit: `6076269feb8d8dd32d9205a0b3a510f2290a3f83` (`require absolute or home relative pty cwd`).
Exact worktree HEAD: run `git rev-parse HEAD` (documentation commits change this value).
The branch is pushed to `https://github.com/manaflow-ai/cmux/tree/feat-tui-tech-debt-wave1-clean`.
The current integration sequence includes the hosted formatter and verification
fixes through `66e83c808f`, the replay preflight correction `c867048c1d`, the
safe scoped-attach series through `dfa4ef3b6a`, manifest and socket-contract
hardening, Unix/Admin task ownership, browser guard coverage, and localization
through `638e536f03`. Localization recovery is recorded in `01c4a2de8d`,
`638e536f03`, and `f04c5409a0`. The aggregate tail adds legacy hashed-socket
fallbacks for Python, TypeScript, Rust, Java, Zig, Go, and C++, bounded Unix JSON
readers, wire-identity preflight, independent config-section recovery,
localization recovery, and systemd quoting fixes through the current code tip
`6076269feb`. The final tail also includes
Go fallback-state minimization and joined fallback errors, C++ attachment errno
handling, path-bound Rust errors and tests, trailing-whitespace cleanup, and
literal-percent escaping for systemd paths.

Subagent ledger: at least 180 substantive agent turns are complete in this
run. The count includes code audits, web research, session mining, fixes,
reviews, and merge gates. It excludes empty or duplicate turns. The requested
10,000-session target is not reached. I will not create empty sessions to
inflate the count. New turns must have a named deliverable.

## Current state

The latest code tail is `6076269feb`. It is a compatibility, lifecycle, and
documentation update. The issues below remain open.

### Open issue inventory

| Issue | Evidence and acceptance |
| --- | --- |
| [#10395](https://github.com/manaflow-ai/cmux/issues/10395) | `eprintln!` can corrupt TUI frames. Route diagnostics through the client log and prove raw-terminal bytes stay unchanged during attach, resize, and close. |
| [#10431](https://github.com/manaflow-ai/cmux/issues/10431) | OSC-11 heredoc smoke input can drop bytes. Reproduce under parallel load and prove byte-for-byte paste delivery with bounded writes. |
| [#10384](https://github.com/manaflow-ai/cmux/issues/10384) | SSH timeout kill/reap flakes in full suites. Prove process-group kill, reap, and no-child-leak behavior repeatedly. |
| [#10426](https://github.com/manaflow-ai/cmux/issues/10426) | Paint-before-pointer flakes on cold parallel runs. Make ordering deterministic without hiding a rendering race. |
| [#7126](https://github.com/manaflow-ai/cmux/issues/7126) | Cmd-V can send one character. Prove complete Unicode paste in bracketed and non-bracketed modes. |
| [#8346](https://github.com/manaflow-ai/cmux/issues/8346) | Open-file-in-editor feature request. Define launch, focus, save/close, and reconnect behavior first. |
| [#10034](https://github.com/manaflow-ai/cmux/issues/10034) | `preferredEditor` can leak editor and Node children. Prove process-group cleanup on success, cancel, crash, and app exit. |
| [#4890](https://github.com/manaflow-ai/cmux/issues/4890), [#4733](https://github.com/manaflow-ai/cmux/issues/4733) | SSH loss/reconnect can leak mouse, focus, or Kitty bytes. Prove protocol-state reset on both paths. |
| [#8285](https://github.com/manaflow-ai/cmux/issues/8285) | Width shrinks but may not widen. Prove bidirectional resize through daemon, PTY, and TUI under rapid changes. |
| [#2688](https://github.com/manaflow-ai/cmux/issues/2688) | Crossterm startup can block on DSR. Define timeout/cancellation and prove startup without a reply. |
| [#1059](https://github.com/manaflow-ai/cmux/issues/1059) | OSC-11 is not passed through. Prove request/reply forwarding and missing-color behavior. |
| [#5490](https://github.com/manaflow-ai/cmux/issues/5490) | CSI 996/997/2031 theme protocol is missing. Add protocol behavior tests before claiming support. |
| [#2396](https://github.com/manaflow-ai/cmux/issues/2396) | Large `cmux send` can freeze. Bound admission and prove completion under backpressure and bracketed paste. |
| [#3051](https://github.com/manaflow-ai/cmux/issues/3051) | Scrollbar changes can oscillate PTY size. Prove resize coalescing and stable dimensions. |
| [#2588](https://github.com/manaflow-ai/cmux/issues/2588) | Child PTYs may miss terminal size. Prove `TIOCSWINSZ` at spawn and after resize. |
| [#5138](https://github.com/manaflow-ai/cmux/issues/5138) | Large multiline paste can lose its middle. Prove complete bounded buffering or surfaced rejection. |

The exact current tip is always available with `git rev-parse HEAD` in the
worktree. The shared primary checkout was dirty before this run. One
pre-existing primary-checkout smoke-script commit (`9a23d9a4f1`) was preserved
and cherry-picked as `b2f1d149fd`; no primary changes were discarded. Current
integration work is isolated in this worktree.

The branch contains browser lookup and pending-enrollment bounds, runtime and
relay error hardening, a `SessionPort` projection boundary, resize coalescing,
pipe framing and PTY short-write fixes, Kitty and graphics flake tests, relay
task ownership and shutdown joins, reconnect cancellation, socket path
validation and digest fallback across SDKs, journal decompression preallocation,
and documentation cleanup. Rust verification remains hosted-only under
`AGENTS.md`.

The socket contract extraction initially removed the live `client-focus` and
`report-focus` commands. The integration branch restores both commands and
keeps the contract changes. Go, schema, resource-boundary, spec-inventory, and
publish-workflow checks pass after that repair.

## Architecture decision

Use Ghostty manual-IO for daemon-backed surfaces. The app will own one direct
byte pump (daemon replay, live output, raw input, resize, and close status)
instead of spawning `cmux-tui attach` inside a nested PTY. Keep the daemon as
the durable owner of terminal and layout state. Migrate in this order:
`--pipe-io` proof, pump-owned resize/close, native `cmux.protocol/2` client,
then removal of the exec-attach bridge. This records the user request from
round 9B; no manual-IO proof exists yet.

## Completed request chains

| Request | Evidence | Status |
| --- | --- | --- |
| Tier-A daemon attach and quit/reopen survival | [PR 10408](https://github.com/manaflow-ai/cmux/pull/10408) | First pass complete. Known cuts: launchd supervision, first-tab/split coverage, cwd/env, orphan cleanup. |
| Journal topology survives terminal exit | [PR 10413](https://github.com/manaflow-ai/cmux/pull/10413) | Complete for exit preservation. Checkpoints and agent launch specs remain open. |
| Scoped attach mouse/cursor correctness | [PR 10428](https://github.com/manaflow-ai/cmux/pull/10428) | Safe host-state and cursor fixes are integrated here. The PR's diagnostic PTY tap remains excluded because its writes can block under backpressure. |
| Checkpoint capture race | [PR 10501](https://github.com/manaflow-ai/cmux/pull/10501) | Complete for bounded, non-destructive capture. Journal growth/GC is still open. |
| Terminal close and liveness reporting | [PR 10513](https://github.com/manaflow-ai/cmux/pull/10513) | Complete for tested host loss and daemon loss paths. Exact round-7 trigger remains unproven. |
| Spec-only plan | [PR 10388](https://github.com/manaflow-ai/cmux/pull/10388) | Closed by direction. Specs must land with implementation. |

## Open requests and acceptance work

| Request | Acceptance gap | State |
| --- | --- | --- |
| Manual-IO transport | `--pipe-io` PoC must render live output, accept typing/mouse, replay on relaunch, and prove one reply authority. | Next implementation slice. |
| Daemon lifecycle | launchd user supervision and detached update handoff with host version compatibility. | Open. |
| Durable restore | Full journal restore, terminal checkpoints, reboot scrollback, agent `--resume` and hibernation. | Open or partial. |
| State ownership | Daemon window resources, dock/panel resource types, WebKit placeholders, typed frontend projections. | Open or partial. |
| Cloud TUI | Build/auth/create/resume/enroll/attach, machine rail, provider-neutral status, lifecycle operations, reconnect, packaging, version rollback, accessibility. | Checklist remains unchecked in `plans/cmux-devboxes.md` (not copied into this worktree). Add secure SSH-host add/edit, remote cmux-tui attach, per-machine/per-window focus ownership, and host-key/credential boundary tests. |
| Backpressure | Bound journal/WAL work and terminal-output admission so a multi-second stall cannot wedge btop. | Open blocker. |

## Change log and revert guidance

### Wave-1 commits

| Commit | Change | Proof / residual risk | Revert |
| --- | --- | --- | --- |
| `352c3a2ebb` | Index browser sources once per refreshed remote tree; preserve pre-refresh browser lookup. | `git diff --check`; hosted Rust test still required. | Revert this commit only; the old tree scan returns, with the prior scale cost. |
| `bedc018adb` | Add path context to Chrome profile setup errors and decode OS hostnames lossily. | Behavior test is in `ab674165c8`; hosted Rust test still required. | Revert both runtime commits together to restore the old error behavior. |
| `ab674165c8` | Add invalid-UTF-8 and empty-hostname behavior coverage. | Test is deterministic and platform-gated; hosted Rust test required. | Revert with `bedc018adb`. |
| `0e8a47209f` | Make `server start/status/stop/attach` canonical and remove obsolete browser/profile setup steps. | `git diff --check`; docs-only. | Revert this commit; no runtime state changes. |
| `aab58dd6d7` | Make CI read the pinned `rust-toolchain.toml` instead of workflow-specific Rust versions. | Workflow/static guard checks; hosted SDK and relay jobs required. | Revert this commit; CI returns to duplicated pins. |
| `16942a5d49` | Add a `SessionPort` snapshot boundary shared by local and remote sessions. | Behavior test compares the port with the existing topology read; hosted Rust test required. | Revert this commit; the frontend uses the direct enum again. |
| `e09f068dc4` | Convert relay slot/circuit invariant panics into atomic explicit errors. | `git diff --check`; hosted relay tests required. | Revert this commit; the old invariant panics return. |
| `eaa7108e9b` | Add this durable board and request log. | Markdown only. | Revert this commit; code remains unchanged. |

The integration branch can be reverted safely by reverting the rows in reverse
order. Do not revert the manual-IO bridge until its replacement has a hosted
red/green behavior proof.

- `PR 10408`: app bridge, quit policy, close semantics, config isolation, and
  TERM propagation. Revert its app commits together if removing the spike;
  keep daemon journal changes only with an explicit owner.
- `PR 10428`: replay mouse-wire-format and scoped attach fixes. Revert the
  serialization and client encoder as one unit; otherwise reattach can regress
  to urxvt encoding.
- `PR 10501`: checkpoint snapshot locking and quiet failure handling. Revert
  only with a replacement bounded-capture design; the old path disconnected
  healthy hosts.
- `PR 10513`: liveness sweep, reconnect give-up notices, and client exit
  reasons. Revert as one chain, then restore the prior exit-state contract.
- Manual-IO work: each slice must have a red behavior test before the fix and
  a hosted green run before removing bridge code. Revert by disabling the flag
  and retaining the existing bridge until the next slice is ready.

## Explicit blockers

1. No manual-IO implementation or end-to-end proof exists yet.
2. Journal size and WAL checkpoint latency can still create terminal-output
   admission stalls; prevention is not claimed.
3. launchd supervision, reboot checkpoints, and full agent restore are not
   implemented.
4. Cloud TUI acceptance remains a product-sized backlog, not a completed
   cmux-tui change.
5. `AdminServer` and `UnixServer` still detach accepted connection tasks;
   explicit shutdown awaits listeners but not all admitted work. A future
   cancellation-token design must thread through dispatch and WebSocket
   upgrades before claiming deterministic shutdown.
6. GitStatus and GitDiff children use `kill_on_drop`, but the generic timeout
   can drop the future before an explicit kill-and-reap await. A cleanup design
   must retain child ownership without letting descendants or permits escape.
7. Over-capacity or duplicate relay `Incoming` frames are intentionally dropped
   today. The wire protocol has no bounded rejection frame, so adding one needs
   a protocol decision.
8. The exact-head hosted run `32640497665` is running against `14bf092017`.
   It includes the shared Crossterm event-reader helper and its behavior test.
9. Attach passthrough PR [#10428](https://github.com/manaflow-ai/cmux/pull/10428)
   is not merge-ready. Its artifact downloads returned 404, and its diagnostic
   PTY tap still has blocking I/O, process-group, and log-permission risks.
   Rebase and remove or repair that tap before treating the PR as a base for
   liveness work.
10. This aggregate has no local Rust compile or test evidence. Treat every
    Rust behavior claim above as pending hosted verification, even where a
    focused source or diff check passed.
11. Relay child cancellation and reaping are still incomplete for generic
    timeout paths. The current changes do not provide a durable cancellation
    token and awaited child ownership for every relay child.
12. Durable Objects integration is not implemented. Cloud TUI lifecycle,
    persistence, and reconnect claims must not be inferred from the local
    relay and SDK hardening in this branch.

## Wave-2 change log

| Commit | Change | Proof / residual risk | Revert |
| --- | --- | --- | --- |
| `d63df58a41` | Loop all scripted PTY writes until all bytes are accepted. | Python compilation and hosted smoke coverage. | Revert this commit to restore one-shot writes and the short-write risk. |
| `96fdc46b8d`, `cacbc23b06` | Suppress transient Kitty budget status events and strengthen the test to reject every transient failure. | Hosted focused tests pending on the latest tip. | Revert both commits together. |
| `c81ce71042` | Disable graphics in the paint-before-pointer flake test. | Removes unrelated GPU timing from the test; hosted test pending. | Revert this test-only commit. |
| `61b2ed02b5`, `487ffecdbf`, `aa5f4904f4` | Own preview listeners, await shutdown, and await aborted peer writers. | Relay shutdown test passed on hosted run `32634154596`; `SharedRuntime` still has no async drop path. | Revert the three relay lifecycle commits together. |
| `6409cb72d6` | Wake terminal reconnect supervision when the owner closes. | Hosted focused lifecycle run pending; no fixed sleep remains in this path. | Revert this commit to restore delayed close. |
| `6f07f16e75` | Assert unique terminal IDs in daemon snapshots without a runtime object. | Behavior assertion; hosted test pending. | Revert this test-only commit. |
| `c178712823`, `9b656e4a0a` | Clarify the canonical remote command group and remove a stale hard-coded fixture count. | Markdown and diff checks pass. | Revert either docs commit independently. |
| `fa1983cc13`, `2ef5dfd372`, `adfc567c02`, `fdfab18694` | Validate session path components, use bindable digest fallback, isolate invalid empty sessions in C++, Go, Rust, Python, TypeScript, Java, and Zig, and validate Go high-level sessions before dialing. | Go packages and SDK schema checks pass. Hosted cross-language verification pending. Residual risk is intentional behavior change for callers that passed empty text to path-only helpers. | Revert all four socket-contract commits together, then restore the old path contract explicitly. |
| `f72bd724ea` | Reserve the validated journal decompression capacity once. | Hosted journal segment run `32634820877` pending. | Revert this optimization only. |
| `ef09c8b2c2` | Bound relay registration shutdown with a real one-second timeout assertion. | Hosted relay test pending. | Revert this test-only commit. |

## Wave-3 change log

| Commit | Change | Proof / residual risk | Revert |
| --- | --- | --- | --- |
| `e6c6982f6b` | Pin the Rust SDK runtime hash dependency. | Package checks are currently blocked by the failing protocol-contract job. | Revert this dependency correction. |
| `0b9f15b16d`, `03a89e19e4`, `bf89159826`, `31a8df3561` | Reject derived or empty lifecycle socket sessions before dialing, cover the invalid-session behavior, and localize the new errors. | Behavior coverage is present; exact-head protocol and inventory checks currently fail. | Revert the lifecycle validation commits together, then restore the old path-only behavior. |
| `cdac79f024`, `93b900c945` | Prune completed relay request tasks and abort detached admin listeners on drop. | Guard checks pass; hosted relay lifecycle coverage remains required. | Revert both ownership fixes together. |
| `f0b88fd72e`, `f9098ab8f6` | Negotiate connection progress capability and accept `attach` after global CLI options. | CLI and schema checks are covered by the current PR; exact-head rerun required. | Revert both compatibility fixes. |
| `b2f1d149fd` | Use monotonic deadlines in the TUI smoke script. | Script-level change; no local Rust test run. | Revert this test-harness change. |

## Wave-4 change log

| Commit | Change | Proof / residual risk | Revert |
| --- | --- | --- | --- |
| `029866fc51` | Apply the hosted Rust formatter output to the integration tip. | Hosted artifact identified the exact formatting delta; `git diff --check` passed. | Revert this style-only commit. |
| `64aa7df959` | Cap pending chatmux-relay workspace requests at 64 per connection and refuse excess work with the existing typed `failed` code. | Behavioral cap test and diff check; hosted Rust test required. A fixed cap can refuse legitimate bursts, so clients must retry. | Revert this commit to restore unbounded task admission. |
| `ff1095b6ed` | Replace the global artifact glibc claim with `runtimeByBinary` OS, architecture, and libc metadata while preserving checksum maps. | No in-org consumer reads the old field. External consumers may need migration. | Revert this workflow commit and restore the old manifest contract only with a consumer plan. |
| `60fcf83ef6` | Route runtime diagnostics through the bounded client log so raw-terminal ownership is not corrupted by `eprintln!`. | Diff check passed; hosted TUI runtime coverage remains required. | Revert this app logging commit. |
| `1c7910a717` | Flush terminal query replies after every parser command, including resize, defaults, clear-history, and drain. | Diff check passed; a capture-writer parser-loop test is still needed. | Revert this parser flush commit. |
| `737bd68689` | Bound SSH bootstrap child reaping to a two-second cleanup grace period after kill. | Diff check passed; hosted remote timeout test required. | Revert this cleanup bound. |
| `5b5de3f648` | Stop cancelling an active exact-commit TUI verification run when a newer request is queued. | `actionlint` passed; hosted workflow run required. Release workflows intentionally keep their own cancellation policy. | Revert this workflow guard. |
| `4b054f4eb8` | Add a dedicated Rust 1.88 MSRV job for public SDK crates and examples while keeping the workspace toolchain checks. | PyYAML and diff checks passed; hosted SDK run required. | Revert this CI coverage addition, which would permit MSRV drift. |
| `86ebb29994` | Correct `docs/remote.md` to describe static musl Linux packages instead of an incorrect glibc floor. | Docs-only; package contract and release docs agree. | Revert this documentation correction. |
| `a2cffdf6c8`, `8712d2f0e2` | Bound non-abortable relay filesystem/search work with eight shared blocking permits and keep the formatting canonical. | The cap bounds work that can outlive a disconnect; queued requests remain cancellable, while admitted closures can still finish. Hosted relay tests remain required. | Revert both commits together to restore unbounded blocking-pool admission. |
| `6e15ea5f38` | Document the `runtimeByBinary` raw-release contract, including per-file libc and package-specific wheel tags. | Docs match the generated manifest; external consumers still need to adopt the new field. | Revert this documentation commit only. |
| `d76bc5539b` | Admit GitStatus and GitDiff through the shared eight-permit pool and build scopes on the blocking pool before filesystem validation. | Prevents cross-connection process admission growth and async-runtime filesystem stalls. Hosted Rust verification required. | Revert this commit with `51a66ad061` to restore the prior Git/scope path. |
| `51a66ad061` | Apply the hosted formatter output for the shared admission helper. | `git diff --check` passed; exact hosted Rust formatter rerun required. | Revert this style-only commit. |
| `14bf092017` | Extract one injected Crossterm event-reader helper for blocking and timed input, with behavior coverage for poll/read ordering. | `git diff --check` passed; hosted run `32640497665` is required for Rust compilation and tests. | Revert this commit to restore duplicated input branches. |

## Aggregate socket, relay, and recovery tail

| Commit range | Change | Proof / residual risk | Revert |
| --- | --- | --- | --- |
| `7a9788b3f4` through `6eb2e4293e` | Apply the legacy hashed-session socket fallback consistently across Python, TypeScript, Rust, Java, Zig, and C++ resource clients, including Unix socket headers where required. | Cross-SDK behavior is aligned at the source level; no local Rust compile or test was run. Hosted SDK and protocol checks remain required. | Revert the SDK fallback commits as one compatibility change, then restore the previous hashed-only contract deliberately. |
| `c254984b62` | Bound Unix JSON-line readers so a peer cannot grow an unbounded frame or line in memory. | Diff and source checks pass; hosted Rust coverage is required. The limit is a protocol policy and may reject oversized future messages. | Revert this bound only with an explicit replacement limit. |
| `cbd64255b9`, `12f1d29eb2` | Validate wire identity during capability preflight and cover the mismatch behavior. | Prevents a capability reply from being accepted for the wrong connection. Rust compile/test remains hosted-only. | Revert both commits together to restore capability-only preflight. |
| `696c600f67` | Recover valid config sections independently so one malformed section does not discard unrelated configuration. | Recovery behavior is covered by focused tests; hosted Rust verification remains required. | Revert this recovery change to restore all-or-nothing parsing. |
| `d6f92ad2b4`, `f04c5409a0` | Add and localize mux recovery status messaging. | English and Japanese localization paths are updated; exact-head hosted UI/runtime verification remains open. | Revert the test and localization commits together. |
| `3adcaf2c78` | Quote systemd `ExecStart` arguments safely for paths and values containing shell metacharacters. | Static and diff checks pass; hosted packaging/install verification remains required. | Revert this service-unit quoting fix only with a replacement escaping rule. |

Rejected or deferred after review: PTY resize error handling was already fixed
by `80f40831dac`; Kitty transient-status suppression is already present as
`96fdc46b8d` and `cacbc23b06`; the TypeScript socket proposal `866e94d5d2`
would remove the current digest fallback; detached admin and Unix connection
tasks need a cancellation design, not a blind `JoinSet`; PR #10513's liveness
fix depends on its unmerged feature stack; PR #10521 still has journal-scan
complexity and host-state publication findings beyond its compile fixes.

## Merge and review board

| PR | Author | State on 2026-08-23 | Required action |
| --- | --- | --- | --- |
| [#9935](https://github.com/manaflow-ai/cmux/pull/9935) | Lawrence Chen | Merged as `ab4633e5612280a348f8e9a0a9626a3bfb527fe1`; exact-head autoreview clean and all checks green. | Done. |
| [#10244](https://github.com/manaflow-ai/cmux/pull/10244) | Lawrence Chen | Merged; exact head `c0b8dd5107`, checks and canonical autoreview passed. | Done. |
| [#10270](https://github.com/manaflow-ai/cmux/pull/10270) | Lawrence Chen | Head `30c5ff60a2`; dirty with conflicts in eight workflow/spec files and overlaps merged #10244. | Rebase only if a distinct socket fix remains; otherwise close as superseded. |
| [#10413](https://github.com/manaflow-ai/cmux/pull/10413) | Lawrence Chen | Head `891544e0ab`; superseded by the newer #10521 stack and still fails conformance compilation. | Close as superseded after #10521 lands. |
| [#10428](https://github.com/manaflow-ai/cmux/pull/10428) | Lawrence Chen | Head `076d648a2c`; existing branch still carries the unsafe diagnostic tap. | Do not merge the tap; use the safe subset in the integration branch or redesign the tool. |
| [#10513](https://github.com/manaflow-ai/cmux/pull/10513) | Lawrence Chen | Stacked head `55caae646e`; dedicated heartbeat fix `18b05775d8` and dead idle-state cleanup `d599fd89e0` are prepared on the in-org stack, but the branch is dirty. | Land the foundational stack with hosted coverage before merging the liveness fixes. |
| [#10521](https://github.com/manaflow-ai/cmux/pull/10521) | Lawrence Chen | Head `087bb3496a`; compile fixes pushed as `392bb50b92`, hosted run `32638928481` pending. Complexity and host-state race findings remain. | Do not merge until those findings have an explicit design resolution. |
| [#10537](https://github.com/manaflow-ai/cmux/pull/10537) | dkta0 | External author branch. Candidate fix `65d19bc694` cannot be pushed to the external fork. | Do not push outside `manaflow-ai`; use an in-org re-cut only if the semantic fix is redesigned. |
| [#10600](https://github.com/manaflow-ai/cmux/pull/10600) | Lawrence Chen | Merged at `1e1800db80` after exact-head checks and clean canonical review. | Done. |
| [#10601](https://github.com/manaflow-ai/cmux/pull/10601) | Lawrence Chen | Merged after exact-head checks and clean canonical autoreview. | Done. |
| [#10602](https://github.com/manaflow-ai/cmux/pull/10602) | Lawrence Chen | Open, head `67b7e6814f8355235e3930a6f3360a58dc0ba3c0`; overlaps aggregate #10603. | Treat as superseded if #10603 contains its deltas; otherwise run exact-head checks and review. |
| [#10603](https://github.com/manaflow-ai/cmux/pull/10603) | Lawrence Chen | Open, head `7a0f71692f8be77da182bbf8a3c89871bd88636f`; aggregate relay, SDK fallback, bounded-reader, identity, config, localization, and packaging hardening. | Run exact-head hosted checks and canonical review, then merge if clean. Close superseded [#10602](https://github.com/manaflow-ai/cmux/pull/10602) and [#10571](https://github.com/manaflow-ai/cmux/pull/10571) only after comparing remaining deltas. |
| [#10522](https://github.com/manaflow-ai/cmux/pull/10522) | Lawrence Chen | Open, head `b6d1e22a3f`; provider-menu routing and deleted-slot failover fixes. | Run exact-head checks and canonical review, then merge only if green. |
| [#10254](https://github.com/manaflow-ai/cmux/pull/10254) | Lawrence Chen | Open, head `e9c177d1c6bf38e89f51ce652003f8c4cf3f9d84`; cross-SDK socket validation. | Resolve C++ attachment and ordered legacy-fallback parity, then review. |

Do not merge stale or high-risk branches [#10131](https://github.com/manaflow-ai/cmux/pull/10131), [#10571](https://github.com/manaflow-ai/cmux/pull/10571), [#9022](https://github.com/manaflow-ai/cmux/pull/9022), [#9003](https://github.com/manaflow-ai/cmux/pull/9003), [#8999](https://github.com/manaflow-ai/cmux/pull/8999), [#9061](https://github.com/manaflow-ai/cmux/pull/9061), [#9062](https://github.com/manaflow-ai/cmux/pull/9062), or superseded stacks [#9922](https://github.com/manaflow-ai/cmux/pull/9922), [#10249](https://github.com/manaflow-ai/cmux/pull/10249), [#10254](https://github.com/manaflow-ai/cmux/pull/10254), and [#10259](https://github.com/manaflow-ai/cmux/pull/10259) without a fresh rebase and exact-head review.

## User-request ledger from local sessions

| Evidence | Request | Status |
| --- | --- | --- |
| `~/.claude/.../01959d25-4114-42de-8cfc-f13b8076a541.jsonl`, 2026-08-19 | All cmux terminals backed by cmux-tui, restart-safe daemon, sidebar layout alignment, quiet close behavior, and no idle-shell prompt. | Partially implemented through PRs [#10408](https://github.com/manaflow-ai/cmux/pull/10408), [#10413](https://github.com/manaflow-ai/cmux/pull/10413), [#10428](https://github.com/manaflow-ai/cmux/pull/10428), and [#10501](https://github.com/manaflow-ai/cmux/pull/10501). Dogfood proof for quiet close is still missing. |
| `~/.claude/.../2e8f629a-9792-478b-a63c-197c62c27114.jsonl`, 2026-08-18 | Cloud TUI with Freestyle VMs, snapshots, package preinstall, provider lifecycle, and reconnect. | Unfinished product backlog. Duplicate session `85319d51-f5d6-4bb6-a499-769643679905.jsonl` is merged into this row. |
| `~/.claude/.../f4a24a6b-dce7-4384-93e5-b2f59e641b57.jsonl`, 2026-08-10 | Decouple PTY resources from layout so one terminal can appear in multiple workspaces and future clients. | Unfinished architecture request. Needs a state-owner design before code extraction. |
| `~/.claude/.../f759472e-9be3-4e5b-9933-3a044314ccd5.jsonl`, 2026-08-06 | Bundle cmux-tui in cmux-relay, auto-pair from iPhone, and preinstall in provider images. | Merge with the cloud snapshot row; no completion evidence. |
| `~/.codex/sessions/2026/08/07/rollout-2026-08-07T19-41-07-019fdf6a-eb48-7882-94f9-40afee69fc68.jsonl` | Hosted verification must require an exact pushed SHA, Blacksmith Linux/macOS, Windows coverage, focused filters, artifacts, and no local Rust or Zig. | Workflow and guardrails are implemented in this wave. Full release and Windows confidence remain blocked by hosted checks. |
| `~/.codex/sessions/2026/08/09/rollout-2026-08-09T16-23-14-019fe8d6-6e4c-7d53-8dde-4135e325a281.jsonl` and `...16-23-48...jsonl` | Azure startup benchmark and Windows GNU exact-head correction. | Historical incomplete benchmark. Acceptance must cover cold readiness, warm attach, restored/incompatible state, headless startup, and Windows protocol, terminal, path, process, and SSH checks. Keep this as a release and CI follow-up, not a runtime patch. |
| `~/.codex/sessions/2026/08/04/rollout-2026-08-04T17-17-26-019fcf48-3fce-73f0-b5f6-8626631c8cb5.jsonl` and duplicate `...17-31-46...jsonl` | Add SSH hosts from the machine rail, attach to remote cmux TUIs, and preserve focused workspace state per machine and cmux window. | Unimplemented or partial. Requires secure host add/edit, authenticated attach, reconnect/close handling, per-machine/per-window focus state, and credential/host-key boundary tests. |
| `~/.codex/sessions/2026/08/23/rollout-2026-08-23T05-00-38-01a02e7e-82ab-7151-abfc-6f90686a6eb8.jsonl` | Runtime diagnostics must use the client log while the TUI owns the raw terminal. | Implemented in `60fcf83ef6`; hosted runtime verification remains. |
| `~/.codex/sessions/2026/08/23/rollout-2026-08-23T05-00-59-01a02e7e-d498-7d03-a93c-bf6ae4f80660.jsonl` | Flush Ghostty query replies after parser commands that produce no PTY output. | Implemented in `1c7910a717`; capture-writer behavior test remains. |
| `~/.codex/sessions/2026/08/23/rollout-2026-08-23T05-01-18-01a02e7f-224f-7172-a90b-f278473c70de.jsonl` | Exact-commit verification requests must queue instead of cancelling active runs. | Implemented in `5b5de3f648`; hosted workflow verification remains. |
| `~/.codex/sessions/2026/07/25/rollout-2026-07-25T20-51-15-019f9c8c-684c-7070-ad8d-3960d8e8f0f8.jsonl` | `ssh cmux.cloud` should provide authenticated VM and workspace sidebars with a TUI pane and reconnect. | Unfinished cloud product request; public-key authentication failed in the evidence session. |
| `~/.codex/sessions/2026/07/26/rollout-2026-07-26T20-57-20-019fa1b8-55e1-79b3-8448-f0b7ce2b4aba.jsonl` | Agents should create interactive TUI controls through stable SDK/CLI APIs without source edits. | Unfinished programmable UI/SDK request. |
| `~/.codex/sessions/2026/07/25/rollout-2026-07-25T16-00-36-019f9b82-4e89-78d1-be5c-27ba09784768.jsonl` | Replace the 511 kernel PTY ceiling with a userspace terminal model while preserving shell/job-control compatibility and multiplexing. | Unimplemented architecture proposal; needs a stress and compatibility design before code. |
| `~/.codex/sessions/2026/07/25/rollout-2026-07-25T20-51-15-019f9c8c-684c-7070-ad8d-3960d8e8f0f8.jsonl` | Every cloud TUI text input needs a visible cursor, word deletion, paste, mouse editing, and resize coverage. | Unverified acceptance detail for the cloud shell row. |
| `~/.codex/sessions/2026/07/11/rollout-2026-07-11T17-37-14-019f53c1-c0fa-7c40-ac05-1ada23f5dc90.jsonl` | TUI release publishing must use GitHub Actions OIDC without a long-lived npm authenticator. | Completed through [PR #8330](https://github.com/manaflow-ai/cmux/pull/8330); retain tag and approval checks for future releases. |
| `~/.claude/paste-cache/e5e0a602b679110b.txt` | Reboot restore/apply should return terminal tabs as exited tabs with old scrollback. | Unfinished; no current PR evidence. Needs a restart behavior proof. |
| `~/.claude/paste-cache/18bda3edc0facc99.txt` | Linux terminal panes need a built cmux-tui backend wired through `CMUX_TUI_BINARY`. | Blocked launcher gap; no implementation evidence. |

## Official pattern references

- Ratatui rendering and component architecture: `https://ratatui.rs/concepts/rendering/`, `https://www.ratatui.rs/concepts/application-patterns/component-architecture/`.
- Tokio shutdown and task ownership: `https://tokio.rs/tokio/topics/shutdown`, `https://docs.rs/tokio/latest/tokio/task/struct.JoinSet.html`.
- Crossterm event ownership: `https://docs.rs/crossterm/latest/crossterm/event/index.html`.
- portable-pty writer and resize ownership: `https://docs.rs/portable-pty/latest/portable_pty/trait.MasterPty.html`.
- SQLite WAL and recovery guidance: `https://www.sqlite.org/wal.html`, `https://www.sqlite.org/transactional.html`.

These sources support the current decisions: one event reader, one PTY writer,
complete short writes, bounded queues, cooperative cancellation with awaited
shutdown, immediate-mode rendering from durable state, and bounded journal
decompression. They do not justify copying a 60 FPS template or adding a
second state store.

## Wave-5 integration findings

| Commit | Change | Proof / residual risk |
| --- | --- | --- |
| `1094385e7f` | Import the private TUI test helpers through their supported module path. | Resolves hosted test import failures; hosted compile remains the authority. |
| `647e9721aa` | Localize the remaining TUI status-error strings. | English and Japanese keys are present; audit future status paths for bare literals. |
| `229eddbe5d` | Bound host input polling during shutdown. | Removes an unbounded wait from the close path; cancellation and host-loss coverage remain required. |
| `35132cda6c` | Localize browser-pane status copy. | Browser status now uses the shared localization table; verify every browser state in UI review. |
| `ec21e4d847` | Cover bounded host-input polling with a deterministic test. | Test exercises the timeout boundary; hosted compile and focused test are still required. |

The hosted compile failure was an import-resolution problem in the private test
helper, not a runtime protocol failure. The helper import is now explicit in
`1094385e7f`; rerun the exact-head hosted job before calling the sequence green.
The event-loop row is now bounded at shutdown, while normal input ownership is
still centralized in the shared reader. Localization is partial by design: the
recent status and browser paths are covered, but new UI copy must still enter
the localization table.

## Session findings

Recent `~/.claude` and `~/.codex` sessions confirm three durable requests:
hosted compile failures must report the first failing import and the resolved
module path; localization must cover status and browser state copy in every
supported language; and event-loop shutdown must use a bounded, cancellable
poll with deterministic behavior coverage. No session evidence proves full
session restore, cloud-TUI lifecycle completion, or manual-IO replacement, so
those remain open requests above.

## Wave-7 integration findings

| Commit | Change | Proof / residual risk | Revert |
| --- | --- | --- | --- |
| `c867048c1d` | Reserve the mouse-format correction suffix during replay preflight. | Exact-boundary behavior test and hosted Rust verification required. | Revert this commit with the replay serializer only if the caller restores an equivalent size reservation. |
| `97dcb1a83d` | Preserve ambiguous legacy mouse replay bytes instead of guessing SGR. | This is the only safe behavior when old daemons omit last-set metadata. Old SGR-last sessions still require a new daemon. | Revert only with a versioned replay metadata design. |
| `b887c03675`, `5104249661`, `b485855271`, `83073b343f` | Make scoped attach transparent at startup and derive host mouse capture from canonical terminal state. | Contract tests cover startup, tracking changes, and render-projection contention. Hosted Rust tests remain required. | Revert this scoped attach chain as one unit. |
| `737e78dd1d`, `e054417774`, `13436a1515`, `dac3c2c33b`, `dfa4ef3b6a` | Reassert host mouse and cursor state after focus or resize, and clear stale cursor state on DECSCUSR reset. | Tests cover focus, resize, normal-frame reset, and cursor provenance. A P2 remains for any future non-daemon surface replacement path. | Revert the reassert and cursor lifecycle commits together. |
| `0316d6bb42` | Cover resolved cursor colors without treating daemon colors as application-authored. | Behavior test added, hosted Rust verification required. | Revert this test-only commit. |
| `1c9bcf58a7`, `6f44e4201a`, `8e0040116e` | Localize remaining menu labels, client actions, copy toasts, and rename prompts in English and Japanese. | Static string audit leaves only test assertions. Hosted compile remains required. | Revert the localization commits together if catalog compatibility requires a staged migration. |

## Wave-8 current state and audit inventory (2026-08-23)

The integration tip for this section was `638e536f03`; the aggregate tip is
`7a0f71692f`. Localization recovery is a two-commit
chain: `01c4a2de8d` restores the missing catalog/source entries and
`638e536f03` restores the mux-recovery status path. Keep both commits together
until English and Japanese runtime coverage is green.

### PR inventory and supersession

| PR | Audit result | Action |
| --- | --- | --- |
| [#10603](https://github.com/manaflow-ai/cmux/pull/10603) | Aggregate relay stack; supersedes [#10602](https://github.com/manaflow-ai/cmux/pull/10602) | Prefer #10603 after replay and safe-attach deltas are present; close #10602 when verified. |
| [#10604](https://github.com/manaflow-ai/cmux/pull/10604) | Lawrence Chen | Relay cleanup and cancellation design, documentation only. | Merge after exact-head review and required checks. Keep runtime child reaping as a separate implementation task. |
| [#10254](https://github.com/manaflow-ai/cmux/pull/10254) | Cross-SDK stack; superseded by [#10249](https://github.com/manaflow-ai/cmux/pull/10249) and [#10239](https://github.com/manaflow-ai/cmux/pull/10239) | Do not merge the stale aggregate; review the two replacement stacks independently. |
| [#10268](https://github.com/manaflow-ai/cmux/pull/10268) | Superseded by [#10267](https://github.com/manaflow-ai/cmux/pull/10267) | Close #10268 after confirming #10267 contains its intended fix. |
| [#10131](https://github.com/manaflow-ai/cmux/pull/10131) | Superseded by [#9922](https://github.com/manaflow-ai/cmux/pull/9922) | Keep #10131 closed; no cherry-pick without a fresh audit. |
| [#10413](https://github.com/manaflow-ai/cmux/pull/10413) | Earlier journal stack; follows sequentially into [#10521](https://github.com/manaflow-ai/cmux/pull/10521) | Land and validate in order, 10413 then 10521, or explicitly port the dependency. |
| [#10136](https://github.com/manaflow-ai/cmux/pull/10136) and [#10259](https://github.com/manaflow-ai/cmux/pull/10259) | Mutual overlap in lifecycle/session ownership | Select one design and close the duplicate; do not merge both. |
| Release stack PRs | Overlapping release, packaging, and verification changes | Keep one linear release stack; rebase each child and rerun exact-head checks before merge. |

### Mined intents and acceptance

| Intent | Evidence path | Acceptance |
| --- | --- | --- |
| PTY ownership must have one writer and explicit lifecycle ownership. | `~/.claude/paste-cache/18bda3edc0facc99.txt`; `cmux-tui/crates/cmux-tui/src/pty.rs`; `cmux-tui/crates/cmux-tui/src/app.rs` | One owner handles writes, resize, close, and cancellation; short writes are complete; shutdown awaits the owner; no nested attach PTY. |
| Linux terminals need a built cmux-tui backend selected by `CMUX_TUI_BINARY`. | `~/.claude/paste-cache/18bda3edc0facc99.txt`; `cmux-tui/docs/remote.md`; launcher/config paths under `cmux-tui/` | A clean Linux install resolves the configured binary, reports a clear missing-binary error, and renders attach, input, resize, and reconnect. |
| SSH aggregation needs machine-rail host add/edit and remote TUI attach. | `~/.codex/sessions/2026/08/04/rollout-2026-08-04T17-17-26-019fcf48-3fce-73f0-b5f6-8626631c8cb5.jsonl`; `~/.codex/sessions/2026/07/25/rollout-2026-07-25T20-51-15-019f9c8c-684c-7070-ad8d-3960d8e8f0f8.jsonl` | Credentials and host keys stay in the host boundary; add/edit, authenticated attach, reconnect/close, and per-machine/per-window focus each have behavior tests. |
| Scrollbar parity must match native terminal behavior. | `cmux-tui/crates/cmux-tui/src/ui/`; `cmux-tui/docs/`; session-mining records in `~/.claude` | Scroll thumb tracks durable scrollback, wheel/drag/page keys agree, resize preserves position, and accessibility exposes the same actions. |

### Current-state change log and revert

On 2026-08-23 this board moved its declared tip from `3d47d1d537` to
`638e536f03`, documented the localization recovery chain, and added the audit
supersession and mined-intent tables. This is documentation only. Revert this
board change as one commit if the integration tip or audit conclusions change;
do not revert either localization commit independently from a tested replacement.

Residual risks remain: hosted exact-head verification is still required, manual
IO is not implemented, PTY and SSH ownership boundaries are incomplete, and
scrollbar parity has no end-to-end evidence. The PR inventory is an audit
snapshot, so statuses can become stale when GitHub heads change.
| `6828f9fa9d` | Explain the common top-level `command` config mistake and point to `commands`. | The guidance matches current serde validation. Error wording matching is a small residual risk. | Revert this diagnostic-only commit. |

The debug PTY tap from [PR 10428](https://github.com/manaflow-ai/cmux/pull/10428)
is deliberately not in this branch. Its current implementation can block on
PTY or stdout writes, so it can stop signal forwarding and terminal restore.
Its logs also needed restrictive permissions and its signal path needed process
group forwarding. The safe group and permission fixes exist in an isolated
follow-up, but nonblocking queued I/O is still required before the tool can be
accepted.

## Wave-7 PR dispositions

| PR | Author | Current evidence | Disposition |
| --- | --- | --- | --- |
| [#10602](https://github.com/manaflow-ai/cmux/pull/10602) | Lawrence Chen | Integration branch now contains the focused TUI fixes through `585e2477dd`; the remote head must be pushed and checked at that exact SHA. | Run hosted exact-head checks and canonical autoreview, then merge if clean. |
| [#10603](https://github.com/manaflow-ai/cmux/pull/10603) | Lawrence Chen | Aggregate relay branch includes the current hardening through `7a0f71692f`; exact hosted verification and review are pending. | Merge after exact-head hosted checks and canonical review are clean, then close superseded [#10602](https://github.com/manaflow-ai/cmux/pull/10602) and [#10571](https://github.com/manaflow-ai/cmux/pull/10571) if no unique delta remains. |
| [#10604](https://github.com/manaflow-ai/cmux/pull/10604) | Lawrence Chen | Documentation-only relay cleanup contract with official Tokio references; exact review is clean. | Merge after required checks. Runtime implementation remains a separate task. |
| [#10254](https://github.com/manaflow-ai/cmux/pull/10254) | Lawrence Chen | Exact head `0dc661ef65` still has C++ parity and legacy fallback review findings. | Finish the shared contract, then run exact-head checks and canonical autoreview. |
| [#10522](https://github.com/manaflow-ai/cmux/pull/10522) | Lawrence Chen | Provider-menu routing and deleted-slot failover fixes are pushed at `b6d1e22a3f`; canonical review is running after three P2 fixes. | Run exact-head checks and canonical review, then merge if green. |
| [#10428](https://github.com/manaflow-ai/cmux/pull/10428) | Lawrence Chen | Existing branch contains the unsafe tap and is not a clean ancestor of the safe subset. | Do not merge the tap. Close as superseded after the safe subset lands, unless the tap is redesigned and re-reviewed. |
| [#10521](https://github.com/manaflow-ai/cmux/pull/10521) | Lawrence Chen | Journal restore still has cold-start scan, lifecycle ordering, and privacy findings. | Keep open, fix design blockers before review or merge. |
| [#10513](https://github.com/manaflow-ai/cmux/pull/10513) | Lawrence Chen | Branch conflicts with current main and depends on the attach/liveness stack. | Rebase and resolve the heartbeat ownership design before merge. |

## Wave-7 user-session findings

| Evidence | Request | Status |
| --- | --- | --- |
| `~/.claude/paste-cache/65dcbaea177f5811.txt:100-110` | `space_open_pane` should open a terminal directly instead of requiring `enable_sandbox_terminal`. | Open simplification request. Keep the sandbox ownership boundary until a direct create-and-attach behavior test exists. |
| `~/.claude/history.jsonl:25096` | Create a workspace and attach in one command. | Open CLI simplification request. Existing create and attach paths need one shared receipt before combining them. |
| `~/.claude/history.jsonl:21099`, `23606`, `23635` | Reboot restore must preserve tabs, scrollback, focus, and split layout. | Open. `ensure_initial` is already idempotent, so the remaining gap is journal adoption and process restoration, not another startup mutation patch. |
| `~/.claude/paste-cache/90358f6aa2892145.txt:1-38` | Local client focus must not unexpectedly change another attached client's workspace. | Open post-merge ownership decision after PR [#10331](https://github.com/manaflow-ai/cmux/pull/10331). |
| `~/.claude/paste-cache/18bda3edc0facc99.txt:40-50` | Linux devbox terminal panes need a built `cmux-tui` binary via `CMUX_TUI_BINARY`. | Open packaging and launcher gap. |
| `~/.claude/paste-cache/c85cdb5910c8fffa.txt:1-6` | Invalid `command` config should give an actionable migration message. | Implemented in `6828f9fa9d`. |

## Wave-7 official references

- XTerm mouse modes are mutually exclusive, and modes 1006 and 1015 are distinct: `https://xtermjs.org/docs/api/vtfeatures/` and `https://www.x.org/docs/xterm/ctlseqs.pdf`.
- Crossterm polling guarantees that a successful poll is followed by a nonblocking read: `https://docs.rs/crossterm/latest/crossterm/event/index.html`.
- Tokio task cancellation and ownership patterns: `https://tokio.rs/tokio/topics/shutdown` and `https://docs.rs/tokio/latest/tokio/task/struct.JoinSet.html`.

These references support the current decisions: preserve ambiguous legacy bytes,
use a versioned protocol for future explicit mouse metadata, centralize host
state ownership, and bound event polling and task admission.

## Wave-8 changes and open review findings

| Commit | Change | Proof / residual risk | Revert |
| --- | --- | --- | --- |
| `0ccb2a1e8b` | Treat C1 ST (`0x9c`) as a valid terminator for all ESC-opened terminal string bodies in cursor provenance parsing. | Official xterm control-sequence reference and focused regression coverage; direct 8-bit string openers remain outside this slice. | Revert this parser/test commit together. |
| `bce7bdfc8b` | Make release `runtimeByBinary` use `architecture` and explicit `libc` values for every platform in current and legacy manifests. | `python3 -m pytest -q tests/test_tui_publish_workflow_security.py` passed 48 tests; consumers must migrate from any private `arch` field. | Revert the workflow, docs, and security-test commit together. |
| `488804b909` | Exercise fail-closed handling for legacy browser mouse and wheel requests with `frame_seq: null`. | Test-only; hosted Rust verification remains required. | Revert this test commit. |
| `9dd26b52bb` | Bound Unix daemon handlers at 64 and track them in a listener-owned `JoinSet`, aborting and awaiting on shutdown. | Tokio lifecycle review found no P0-P2 defect; active-handler, flood, and drop behavior tests remain useful follow-up coverage. | Revert this daemon lifecycle commit. |
| `b86a250a3d` | Replace duplicated AdminServer abort-and-drain loops with `JoinSet::shutdown().await`. | Same cancellation semantics with one Tokio primitive; hosted Rust verification remains required. | Revert this two-line lifecycle cleanup. |
| `d94cef71f8` | Record a safe continuation-token design for journal restore preview so one archive segment is decoded once across pages. | Design-only because a live SQLite snapshot and owned cursor are required; no speculative runtime iterator was added. | Revert this documentation commit. |
| `b5dd3abec7` | Record measured projection complexity and defer caching until a composite invalidation revision exists. | Retired-surface cleanup is already O(tree + retired) with a `HashSet`; per-frame row allocations remain an open optimization. | Revert this documentation commit. |
| `edf9ca96f7`, `585e2477dd` | Route browser, sidebar, provider, and action-status copy through the EN/JA catalog, including provider action IDs. | Known third-party provider labels remain provider-supplied; hosted compile and UI review remain required. | Revert both localization commits together. |
| `bc3839813c` | Make raw `--session` socket resolution fallible so invalid names cannot bypass validation or hash an unsafe path. | Focused hosted run before this commit failed on the old test branch; final exact-head hosted run is required. | Revert this raw-client contract fix. |
| `3d47d1d537` | Add Unix listener shutdown, admission-recovery, and Drop cleanup behavior tests. | Tests are formatted but not run locally; hosted Rust verification remains required. | Revert this test-only commit. |

The current integration branch is not a claim that every open TUI PR is safe.
PR [#10254](https://github.com/manaflow-ai/cmux/pull/10254) still needs C++
parity and an ordered legacy fallback probe. PR [#10522](https://github.com/manaflow-ai/cmux/pull/10522)
has a pushed provider-menu fix awaiting exact-head checks and review. Aggregate
PR [#10603](https://github.com/manaflow-ai/cmux/pull/10603) has an explicit
cleanup contract in [#10604](https://github.com/manaflow-ai/cmux/pull/10604),
but child-process group reaping still needs a separate implementation and
behavior test.

## Simplification audit and residual risks

The audit removes duplicate socket fallback branches, keeps one bounded path
validator per client, and keeps one shared terminal log boundary. Go now retains
minimal fallback state, C++ attachment reports classified errno failures, and
Rust fallback errors carry path context. These are principled contract
reductions, not timing workarounds. Remaining risks are unchanged: no local
Rust compile evidence, no manual-IO end-to-end proof, incomplete cancellation
and child reaping, unresolved PTY resize and paste issues, and stale GitHub
status snapshots. The issue and PR rows above do not claim those items are
fixed.

## Wave 19 change log and revert chains

| Commit range | Change | Proof / residual risk | Revert chain |
| --- | --- | --- | --- |
| `3133fc4222` | Run the full PyPI wheel contract validator before executable smoke checks. | Python package and workflow tests passed; hosted package build remains required. | Revert the workflow and its ordering test together. |
| `5ef7a91212` through `83ee31d7de` | Bound workspace fanout and legacy socket fallback paths, flatten Rust fallback conditions, match Python hashed parents, and choose one client fallback authority. | Source and focused Python checks cover the contract; cross-SDK hosted checks remain required. | Revert the fallback-selection commits as one compatibility chain, then restore the old explicit opt-in behavior. |
| `864abe367e` through `f6ea69fb41` | Accept compatible journal protocol versions, preserve Rust config literals, harden bounded readers, and apply hosted formatting. | No local Rust compile evidence. Protocol compatibility must be checked against older daemons. | Revert protocol acceptance with its tests, and formatting independently. |
| `7a0f71692f`, `8e1818033d` | Escape percent characters in systemd paths and await preview-proxy accept readiness. | Static checks pass; packaging and reconnect timing remain hosted concerns. | Revert the service quoting and readiness changes together if the service contract changes. |

## Wave 20 change log and revert chains

| Commit range | Change | Proof / residual risk | Revert chain |
| --- | --- | --- | --- |
| `ec6b4fa6c9` through `26a6ae9ad0` | Bound relay workspace admission and preserve mandatory responses under queue pressure, with shell-start waiter ownership and canonical formatting. | Queue behavior is source-reviewed; producer and consumer saturation tests are still needed. | Revert admission, response, and waiter commits together. |
| `c3137be28c` through `91630119c6` | Scope PTY cwd to allowed roots, preserve socket authority, validate existing and restored attachments, and fail closed on scoped reattach. | CWD and attachment checks are present; relative-cwd compatibility and full reconnect coverage remain open. | Revert the cwd/reattach chain as one security contract. |
| `ff62270c0f` through `c24f4e05ec` | Match hashed socket parents exactly and require explicit opt-in for raw legacy fallback. | Prevents ambiguous socket selection; callers relying on implicit fallback need migration. | Revert parent matching and opt-in changes together, then document the old contract. |
| `82819f46a6` through `6076269feb` | Bound and validate allowed-root lists, workspace reads, response staging, and PTY cwd metadata; clean obsolete authority state and repair Java interruption cleanup. | Bounds are deliberate, but Java connect timeout, producer queue lifetime, and relative-cwd migration remain unresolved. | Revert the root and cwd policy commits as a staged chain, preserving the prior parser only with a replacement limit and migration test. |

## PR status and classification

| PR | Author | Current status | Classification and action |
| --- | --- | --- | --- |
| [#10522](https://github.com/manaflow-ai/cmux/pull/10522) | Lawrence Chen | Merged 2026-08-23, merge `409e9dc1620d47489313752f6cae4b5987d7b274` | Merged provider/sidebar rail work. No follow-up merge needed. |
| [#10604](https://github.com/manaflow-ai/cmux/pull/10604) | Lawrence Chen | Merged 2026-08-23, merge `1956d7f440add80ba35e585d83697d9dae44d3e2` | Merged cleanup contract. Runtime child reaping remains separate. |
| [#10605](https://github.com/manaflow-ai/cmux/pull/10605) | Lawrence Chen | Merged 2026-08-23, merge `51294051938830a1e3d3013a256d851ad4cfa1d3` | Merged workflow simplification. |
| [#10606](https://github.com/manaflow-ai/cmux/pull/10606) | Lawrence Chen | Merged 2026-08-23, merge `8af5331e27b832eb517bb5c1892391348b5cb6e9` | Merged diagnostics routing. |
| [#10608](https://github.com/manaflow-ai/cmux/pull/10608) | Lawrence Chen | Merged 2026-08-23, merge `2ee1e355c0a9b405ada3e2b812b0cec5e2ae4278` | Merged cross-language socket contract docs. |
| [#10603](https://github.com/manaflow-ai/cmux/pull/10603) | Lawrence Chen | Open, head `5ce10b76303038392f4550b4f654dbd19ad50348` | Aggregate implementation. Requires exact-head hosted checks, replay/safe-attach parity, and lifecycle review. |
| [#10602](https://github.com/manaflow-ai/cmux/pull/10602) | Lawrence Chen | Open, head `67b7e6814f8355235e3930a6f3360a58dc0ba3c0` | Focused hardening stack. Treat as superseded by #10603 if all unique deltas are present. |
| [#10607](https://github.com/manaflow-ai/cmux/pull/10607) | Lawrence Chen | Open, head `126d772a131ce71f245ae56c3048aa99f3607d17` | Identity-preflight fix. Review protocol compatibility and run hosted tests. |
| [#10609](https://github.com/manaflow-ai/cmux/pull/10609) | Lawrence Chen | Open, head `bdcbb8c8049e` | Action-result enqueue refactor. Keep separate until queue ownership and backpressure tests pass. |
| [#10611](https://github.com/manaflow-ai/cmux/pull/10611) | Lawrence Chen | Open, head `75f4192d2adc` | TypeScript empty-path validation. Review with the shared SDK fallback contract. |
| [#10254](https://github.com/manaflow-ai/cmux/pull/10254) | Lawrence Chen | Open, head `e9c177d1c6bf38e89f51ce652003f8c4cf3f9d84` | Cross-SDK validation stack. Do not merge until C++ attachment and ordered fallback parity are complete. |
| [#10571](https://github.com/manaflow-ai/cmux/pull/10571) | Lawrence Chen | Open, stale stack | Classify as superseded by #10603 unless a unique relay feature is intentionally retained. |

## New session-mined intents and acceptance

| Intent | Evidence path | Acceptance |
| --- | --- | --- |
| npm and PyPI artifacts need executable smoke checks, not only archive inspection. | `~/.codex/sessions/2026/08/23/rollout-2026-08-23T08-16-27-01a02f31-cad0-7043-a08a-8d4cb183abb5.jsonl`; `.github/workflows/cmux-tui-build-package.yml` | Build exactly six wheels with matching version and `RECORD`, verify the hook mode, install offline, and run `cmux --help`; keep npm and PyPI checks independent. |
| Single-terminal attach should not create duplicate terminal resources. | `~/.codex/sessions/2026/08/23/rollout-2026-08-23T07-31-59-01a02f09-1652-7d03-a3ed-69a5a484d82f.jsonl` | Attach one existing terminal, prove one resource identity, preserve focus and cwd, then reconnect and close without an orphan. |
| Color behavior must match between daemon, host, and client projections. | `~/.codex/sessions/2026/08/23/rollout-2026-08-23T07-55-08-01a02f1e-46a3-7113-99cd-c8a9838e86c7.jsonl` | Prove ANSI, OSC, and theme-query parity without treating daemon-owned colors as client-authored state. |
| Linux packaging needs a real `CMUX_TUI_BINARY` backend. | `~/.codex/sessions/2026/08/23/rollout-2026-08-23T06-33-58-01a02ed3-f760-7fd0-ac3e-fd4330e0c9c2.jsonl`; `cmux-tui/docs/remote.md` | A clean Linux install resolves the configured binary, reports a useful missing-binary error, and supports attach, input, resize, and reconnect. |
| Durable event streams need resumable ordering across reconnects. | `~/.codex/sessions/2026/08/23/rollout-2026-08-23T02-16-00-01a02de7-c99a-72f0-954b-f1c36a3894c6.jsonl` | Persist monotonic event IDs, resume from a cursor without loss or duplication, bound replay storage, and make shutdown ownership explicit. |

## Residual risks after Waves 19 and 20

The following risks remain open and are not implied to be fixed by the latest
commits:

- Java Unix connection setup still needs an explicit connect timeout and a
  behavior test for a peer that accepts but never responds.
- PTY inbound data can still exceed a bounded lifecycle unless every producer
  has an admission limit and cancellation path.
- Workspace producer queues now have bounds in several paths, but ownership of
  a queued item across disconnect, shutdown, and retry is not fully proven.
- Relative PTY cwd input is now rejected or normalized in more paths. A stable
  documented relative-cwd migration contract and compatibility test are still
  required.
- No local Rust compile or end-to-end hosted result is claimed here. Manual-IO,
  durable restore, cloud lifecycle, and complete child reaping remain open.

The ledger still records at least 180 substantive agent turns. It counts named
audits, fixes, reviews, and merge gates, and excludes empty or duplicate turns.
The requested 10,000-session target is not reached, and no sessions are being
created to inflate the count.

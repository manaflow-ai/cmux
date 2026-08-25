# cmux-tui technical-debt board

Last updated: 2026-08-24.
Audit base: `origin/main` at `835d046fed9d339443f718ff0f6ef87813272bbb`.
Integration branch: `aggregate-final`.
Current integration code tip before this documentation commit: `387b4185f28e8baf040207f3e7ec9ffb50f3b53b`.

Current exact aggregate tip is `387b4185f28e8baf040207f3e7ec9ffb50f3b53b`,
747 commits ahead of `origin/main` before this documentation update.
Exact worktree HEAD at audit time: `387b4185f28e8baf040207f3e7ec9ffb50f3b53b`.
The aggregate branch is `aggregate-final`; the review branch is
`https://github.com/manaflow-ai/cmux/tree/feat-tui-tech-debt-wave1-clean`.
Current-snapshot rule: the facts above and the final-tail notes below are the
only live state in this document. Older sections preserve prior audit snapshots
for revert history. Treat their SHAs, ahead counts, PR heads, and review status
as historical unless they match this snapshot.
The current integration sequence includes the hosted formatter and verification
fixes through `66e83c808f`, the replay preflight correction `c867048c1d`, the
safe scoped-attach series through `dfa4ef3b6a`, manifest and socket-contract
hardening, Unix/Admin task ownership, browser guard coverage, and localization
through `638e536f03`. Localization recovery is recorded in `01c4a2de8d`,
`638e536f03`, and `f04c5409a0`. The aggregate tail adds legacy hashed-socket
fallbacks for Python, TypeScript, Rust, Java, Zig, Go, and C++, bounded Unix JSON
readers, wire-identity preflight, independent config-section recovery,
localization recovery, and systemd quoting fixes. The current tail also bounds
relay and remote queues, validates relay frame versions, joins Python cleanup,
uses one Go fallback deadline, guards TypeScript transport callbacks, bounds
Iroh result delivery, and hardens filesystem-watch admission and overflow
wakeup through `643dbfe2e5`. The final formatting pass is `b61f1bada6`, followed
by socket-send simplification, heartbeat bounds, fairness accounting, shell
reservation cleanup, explicit PTY overflow, preview saturation disconnect,
cross-language transport cleanup, CLI metadata, capability documentation,
credential-child reaping, journal-writer ownership/finalization, explicit socket
parent and lease cleanup, package-mode preservation, and C1 parser support
through `f7471b21e6a4a0e5cac745e78202d4470b87abb5`. The exact-head tail adds bounded preview and Windows
process cleanup, safe socket fallback precedence, Python cancellation
propagation, and the Rust fallback-test contract. Documentation-only bridge commits are
[`42b776a327`](https://github.com/manaflow-ai/cmux/commit/42b776a327c17386d131ef1b1f8a382b02683954)
and [`cef7c71460`](https://github.com/manaflow-ai/cmux/commit/cef7c71460f72444e874f7c9f26100e9259874c1).
The 25-file relay/TUI integration merge is `05c0b30277`. The latest code tail
also includes exact socket-parent matching, bounded workspace reads, watcher
sink termination, cross-language fallback correction, Windows dependency
declarations, path-error classification, shell and preview task ownership,
and clippy cleanup through the earlier aggregate tail, followed by the current
main merge, C1 parser normalization, relay stderr draining, cancellation retry
state, private SSH staging, selector tests, workflow identity checks, and CLI
payload-scope parsing.

Latest wave follow-ups are recorded in the changelog. The prior exact-head
autoreview found three relay retention issues, now fixed in the latest tail;
the final review is pending. Two earlier remote-tmux findings were ignored as
out of scope. No new session was counted for documentation-only bookkeeping;
the ledger remains a lower bound on substantive turns, not a fabricated
10,000-session total.

Subagent ledger: at least 205 substantive agent turns are complete in this
run. The count includes code audits, web research, session mining, fixes,
reviews, and merge gates. It excludes empty or duplicate turns. The requested
10,000-session target is not reached. I will not create empty sessions to
inflate the count. The new intent rows do not count as completed work or extra
sessions. New turns must have a named deliverable.

## Current state

The latest code tail is `387b4185f28e8baf040207f3e7ec9ffb50f3b53b`. It carries the watch compatibility,
queue-ownership, fairness, timer-bound, shell-reservation, PTY overflow,
preview saturation, SDK lifecycle, CLI grammar, capability documentation,
credential-child reaping, journal-writer ownership/finalization, explicit
socket cleanup, package-mode preservation, 8-bit C1 parser fixes, and inline
global CLI values, bounded preview and process cleanup, safe socket fallback
precedence, cancellation propagation, cross-platform root parsing, and SDK
clippy cleanup after the
25-file relay/TUI integration merge. The issues below remain open.

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
11. Credential-command failures now kill and reap their child on every error
    path. Generic relay child timeout and cancellation paths still lack a
    durable cancellation token and awaited ownership for every relay child.
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
| [`fb3ac754c5`](https://github.com/manaflow-ai/cmux/commit/fb3ac754c5d55869f968289e3906e3b6b6b0872e), [`ab2b944ab8`](https://github.com/manaflow-ai/cmux/commit/ab2b944ab81a2ebf09a0c595b185344665f9c74f), [`5f8860398e`](https://github.com/manaflow-ai/cmux/commit/5f8860398ee30e255f37cc5e8633159fb0058aa1), and [`09190e6da9`](https://github.com/manaflow-ai/cmux/commit/09190e6da92b60a60000913b9cbf9931ea4b94c7) | Share terminal-reader, gap, barrier, and writer finalization between explicit shutdown and ordinary `Mux` drop, including self-join handoff and shared completion state. | Duplicate writers are rejected before spawn and concurrent closers share one join result. A lifecycle owner should still call `shutdown` before releasing its final `Arc<Mux>` when durable gap delivery is required; late self-drop bytes remain best-effort. | Revert the finalization and writer-state commits together. |

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
| `82819f46a6` through `6076269feb` | Bound and validate allowed-root lists, workspace reads, response staging, and PTY cwd metadata; clean obsolete authority state and repair Java interruption cleanup. | Bounds are deliberate; producer queue lifetime and relative-cwd migration remain unresolved. The later Java timeout connector is recorded in Wave 21. | Revert the root and cwd policy commits as a staged chain, preserving the prior parser only with a replacement limit and migration test. |

## PR status and classification

| PR | Author | Current status | Classification and action |
| --- | --- | --- | --- |
| [#10522](https://github.com/manaflow-ai/cmux/pull/10522) | Lawrence Chen | Merged 2026-08-23, merge `409e9dc1620d47489313752f6cae4b5987d7b274` | Merged provider/sidebar rail work. No follow-up merge needed. |
| [#10604](https://github.com/manaflow-ai/cmux/pull/10604) | Lawrence Chen | Merged 2026-08-23, merge `1956d7f440add80ba35e585d83697d9dae44d3e2` | Merged cleanup contract. Runtime child reaping remains separate. |
| [#10605](https://github.com/manaflow-ai/cmux/pull/10605) | Lawrence Chen | Merged 2026-08-23, merge `51294051938830a1e3d3013a256d851ad4cfa1d3` | Merged workflow simplification. |
| [#10606](https://github.com/manaflow-ai/cmux/pull/10606) | Lawrence Chen | Merged 2026-08-23, merge `8af5331e27b832eb517bb5c1892391348b5cb6e9` | Merged diagnostics routing. |
| [#10608](https://github.com/manaflow-ai/cmux/pull/10608) | Lawrence Chen | Merged 2026-08-23, merge `2ee1e355c0a9b405ada3e2b812b0cec5e2ae4278` | Merged cross-language socket contract docs. |
| [#10603](https://github.com/manaflow-ai/cmux/pull/10603) | Lawrence Chen | Open, head `17413db11cc0ebb7b0b5c254447cede3faaad0cf` | Aggregate implementation. Requires exact-head hosted checks, replay/safe-attach parity, and lifecycle review. |
| [#10602](https://github.com/manaflow-ai/cmux/pull/10602) | Lawrence Chen | Open, head `67b7e6814f8355235e3930a6f3360a58dc0ba3c0` | Focused hardening stack. Treat as superseded by #10603 if all unique deltas are present. |
| [#10607](https://github.com/manaflow-ai/cmux/pull/10607) | Lawrence Chen | Open, head `126d772a131ce71f245ae56c3048aa99f3607d17` | Superseded by aggregate [#10603](https://github.com/manaflow-ai/cmux/pull/10603), which contains the capability-shape and protocol-compatibility fixes. |
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

- PTY inbound data can still exceed a bounded lifecycle unless every producer
  has an admission limit and cancellation path.
- Workspace producer queues now have bounds in several paths, but ownership of
  a queued item across disconnect, shutdown, and retry is not fully proven.
- Relative PTY cwd input is now rejected or normalized in more paths. A stable
  documented relative-cwd migration contract and compatibility test are still
  required.
- No local Rust compile or end-to-end hosted result is claimed here. Manual-IO,
  durable restore, cloud lifecycle, and complete child reaping remain open.

The ledger still records at least 205 substantive agent turns. It counts named
audits, fixes, reviews, and merge gates, and excludes empty or duplicate turns.
The requested 10,000-session target is not reached, and no sessions are being
created to inflate the count.

## Wave 20 follow-up, current aggregate tip

The code tip advanced from `8c5f808302` through the following bounded
security, ingress, and metadata commits. These entries preserve the earlier
Wave 20 decisions and do not convert an implementation slice into a completed
product request.

| Commit | Change | Proof / residual risk | Revert chain |
| --- | --- | --- | --- |
| [`aa7f9d29a7`](https://github.com/manaflow-ai/cmux/commit/aa7f9d29a70e391bc606e1874b077d7b82bcc588) | Bound relay PTY ingress and reject saturation. | Protects the ingress boundary; producer cancellation and client retry behavior still need hosted coverage. | Revert with the ingress-pressure commits below. |
| [`92ded0653e`](https://github.com/manaflow-ai/cmux/commit/92ded0653e9405cfc7352517aceeeddfe5c6cc6a) | Validate capability identity shape before accepting the reply. | Fail-closed shape validation is covered at source level; exact-head protocol tests remain required. | Revert with the identity-preflight chain, not independently from its contract tests. |
| [`b1775bcab2`](https://github.com/manaflow-ai/cmux/commit/b1775bcab2e9246fae9392e725900f4df28769fd) | Reject empty local allowed-root entries. | Prevents an empty root from broadening access; migration behavior for old configs remains open. | Revert with the allowed-root policy chain. |
| [`6076269feb`](https://github.com/manaflow-ai/cmux/commit/6076269feb8d8dd32d9205a0b3a510f2290a3f83), [`f6988cef87`](https://github.com/manaflow-ai/cmux/commit/f6988cef8769ba1d08a331badf8e48cef89c5b84) | Require absolute or home-relative PTY cwd and reject malformed values. | Establishes a path-bound contract; relative-cwd compatibility needs an explicit migration test. | Revert both cwd policy commits together. |
| [`20e2ea8f47`](https://github.com/manaflow-ai/cmux/commit/20e2ea8f47c4345ecd1a97d7b4be6a0481bf2578), [`63dbb11f99`](https://github.com/manaflow-ai/cmux/commit/63dbb11f99c9a45a04ff457453aefc0391e8cad7) | Reject untrusted cwd metadata and apply one shared allowed-root policy to workspace roots. | Closes parser disagreement between workspace and PTY paths; full cross-client behavior remains required. | Revert as one root-validation chain. |
| [`6a84e6a770`](https://github.com/manaflow-ai/cmux/commit/6a84e6a77034fe708225eedbc22f02c02475b383), [`bb5c906f57`](https://github.com/manaflow-ai/cmux/commit/bb5c906f574d77fe16af120e06d729869cd5e8d1), [`eaf23dfb83`](https://github.com/manaflow-ai/cmux/commit/eaf23dfb83dfb2e260e7a6be8c0e81e5f4ae3df7) | Count root byte limits consistently and validate daemon/action workspace metadata and allowed-root paths. | Bounds are explicit; malformed metadata still needs hosted red/green coverage across every action producer. | Revert the metadata and byte-limit commits as one validation chain. |
| [`3ee329e31f`](https://github.com/manaflow-ai/cmux/commit/3ee329e31f00e10e13195b9841e36aaf73e896a4), [`4511a8ba35`](https://github.com/manaflow-ai/cmux/commit/4511a8ba35432c0f4ecbe9ed8254ef6b03bc04a9) | Keep relay ingress responsive under busy responses and always process PTY close. | Prevents close starvation under pressure; queue ownership and shutdown ordering remain open. | Revert both ingress-pressure commits together with `aa7f9d29a7`. |

## PR decisions after the latest audit

| PR | Author | Status | Decision |
| --- | --- | --- | --- |
| [#10611](https://github.com/manaflow-ai/cmux/pull/10611) | Lawrence Chen | Merged 2026-08-23, merge `91b991496de2667a22e65176a8f11f715e6c089b` | Keep the TypeScript empty-path validation. No further action. |
| [#10607](https://github.com/manaflow-ai/cmux/pull/10607) | Lawrence Chen | Open, head `126d772a131ce71f245ae56c3048aa99f3607d17` | Superseded by [#10603](https://github.com/manaflow-ai/cmux/pull/10603); its identity-shape and protocol-compatibility fixes are in the aggregate. |
| [#10609](https://github.com/manaflow-ai/cmux/pull/10609) | Lawrence Chen | Open, head `bdcbb8c8049eb552a0d646cdce78d58d294b7b82` | Keep separate until action-result queue ownership, saturation, cancellation, and retry behavior have tests. |
| [#10603](https://github.com/manaflow-ai/cmux/pull/10603) | Lawrence Chen | Open, head `17413db11cc0ebb7b0b5c254447cede3faaad0cf` | Aggregate remains the likely integration vehicle, but do not merge until the final exact-head review and hosted lifecycle evidence pass. |

## Residual risks, updated

- Workspace producer queues have bounds in multiple paths, but a queued item
  can still outlive its producer across disconnect, retry, and shutdown. The
  ownership contract needs a behavior test, not another numeric cap.
- PTY inbound saturation now fails closed at one ingress boundary. Every
  producer path still needs a bounded admission decision and cancellation
  proof before claiming global backpressure safety.
- Relative cwd rejection is safer than accepting ambiguous paths, but callers
  need a documented absolute/home-relative migration contract.

The ledger remains an honest lower bound of at least 205 substantive agent
turns. It does not represent an exact session-file count, and the requested
10,000-session target is not reached.

## GitHub TUI PR inventory, read-only snapshot 2026-08-23

This inventory comes from the GitHub open-PR search for cmux-tui-related work
and direct PR reads. “Merge candidate” means the change may be merged after the
listed checks. It is not merge authorization. No PR was closed or merged while
making this snapshot. Every entry has a full URL and the current author.

### Merge candidates

| PR | Author | Classification and required gate |
| --- | --- | --- |
| [https://github.com/manaflow-ai/cmux/pull/9922](https://github.com/manaflow-ai/cmux/pull/9922) | Lawrence Chen | Merge candidate for the trusted startup benchmark. Re-run the benchmark and hosted workflow on its current head. |
| [https://github.com/manaflow-ai/cmux/pull/10251](https://github.com/manaflow-ai/cmux/pull/10251) | Lawrence Chen | Merge candidate for binary/distribution version parity after package-contract and release checks. |
| [https://github.com/manaflow-ai/cmux/pull/10239](https://github.com/manaflow-ai/cmux/pull/10239) | Lawrence Chen | Merge candidate for unsafe session-name rejection after SDK matrix and exact-head review. |
| [https://github.com/manaflow-ai/cmux/pull/10249](https://github.com/manaflow-ai/cmux/pull/10249) | Lawrence Chen | Merge candidate for the replacement SDK session-name contract; keep ordered with the other SDK changes. |

### Superseded or duplicate stacks

| PR | Author | Classification and replacement |
| --- | --- | --- |
| [https://github.com/manaflow-ai/cmux/pull/10607](https://github.com/manaflow-ai/cmux/pull/10607) | Lawrence Chen | Superseded by aggregate [https://github.com/manaflow-ai/cmux/pull/10603](https://github.com/manaflow-ai/cmux/pull/10603), which contains the capability-shape and protocol-compatibility fixes. |
| [https://github.com/manaflow-ai/cmux/pull/9933](https://github.com/manaflow-ai/cmux/pull/9933) | Lawrence Chen | Superseded by the benchmark contract in [https://github.com/manaflow-ai/cmux/pull/9922](https://github.com/manaflow-ai/cmux/pull/9922). |
| [https://github.com/manaflow-ai/cmux/pull/10228](https://github.com/manaflow-ai/cmux/pull/10228) | Lawrence Chen | Superseded by merged color-environment work in [https://github.com/manaflow-ai/cmux/pull/10429](https://github.com/manaflow-ai/cmux/pull/10429). |
| [https://github.com/manaflow-ai/cmux/pull/9890](https://github.com/manaflow-ai/cmux/pull/9890) | Lawrence Chen | Superseded by the merged rolling-log and close/liveness fixes in [https://github.com/manaflow-ai/cmux/pull/10486](https://github.com/manaflow-ai/cmux/pull/10486). |
| [https://github.com/manaflow-ai/cmux/pull/10254](https://github.com/manaflow-ai/cmux/pull/10254) | Lawrence Chen | Superseded by the replacement SDK stacks [https://github.com/manaflow-ai/cmux/pull/10239](https://github.com/manaflow-ai/cmux/pull/10239) and [https://github.com/manaflow-ai/cmux/pull/10249](https://github.com/manaflow-ai/cmux/pull/10249). |
| [https://github.com/manaflow-ai/cmux/pull/9876](https://github.com/manaflow-ai/cmux/pull/9876) | Lawrence Chen | Superseded by the trusted benchmark line in [https://github.com/manaflow-ai/cmux/pull/9922](https://github.com/manaflow-ai/cmux/pull/9922). |
| [https://github.com/manaflow-ai/cmux/pull/10602](https://github.com/manaflow-ai/cmux/pull/10602) | Lawrence Chen | Superseded when the aggregate implementation in [https://github.com/manaflow-ai/cmux/pull/10603](https://github.com/manaflow-ai/cmux/pull/10603) contains all unique deltas. |
| [https://github.com/manaflow-ai/cmux/pull/10131](https://github.com/manaflow-ai/cmux/pull/10131) | Lawrence Chen | Superseded by [https://github.com/manaflow-ai/cmux/pull/9922](https://github.com/manaflow-ai/cmux/pull/9922); retain no benchmark fork without a fresh audit. |
| [https://github.com/manaflow-ai/cmux/pull/9821](https://github.com/manaflow-ai/cmux/pull/9821) | Lawrence Chen | Superseded by the journal and liveness stack in [https://github.com/manaflow-ai/cmux/pull/10413](https://github.com/manaflow-ai/cmux/pull/10413) and [https://github.com/manaflow-ai/cmux/pull/10521](https://github.com/manaflow-ai/cmux/pull/10521). |
| [https://github.com/manaflow-ai/cmux/pull/9819](https://github.com/manaflow-ai/cmux/pull/9819) | Lawrence Chen | Superseded by the newer journal attachment-state design in [https://github.com/manaflow-ai/cmux/pull/10413](https://github.com/manaflow-ai/cmux/pull/10413). |
| [https://github.com/manaflow-ai/cmux/pull/9813](https://github.com/manaflow-ai/cmux/pull/9813) | Lawrence Chen | Superseded by the durable restore stack in [https://github.com/manaflow-ai/cmux/pull/10521](https://github.com/manaflow-ai/cmux/pull/10521). |
| [https://github.com/manaflow-ai/cmux/pull/9806](https://github.com/manaflow-ai/cmux/pull/9806) | Lawrence Chen | Superseded by the journal projection and restore sequence now carried by [https://github.com/manaflow-ai/cmux/pull/10521](https://github.com/manaflow-ai/cmux/pull/10521). |
| [https://github.com/manaflow-ai/cmux/pull/9647](https://github.com/manaflow-ai/cmux/pull/9647) | Lawrence Chen | Superseded by the daemon-backed attach direction in [https://github.com/manaflow-ai/cmux/pull/10408](https://github.com/manaflow-ai/cmux/pull/10408) and aggregate [https://github.com/manaflow-ai/cmux/pull/10603](https://github.com/manaflow-ai/cmux/pull/10603). |
| [https://github.com/manaflow-ai/cmux/pull/9818](https://github.com/manaflow-ai/cmux/pull/9818) | Lawrence Chen | Superseded by the current durable-proof and liveness stack in [https://github.com/manaflow-ai/cmux/pull/10513](https://github.com/manaflow-ai/cmux/pull/10513). |
| [https://github.com/manaflow-ai/cmux/pull/9816](https://github.com/manaflow-ai/cmux/pull/9816) | Lawrence Chen | Superseded by the journal effect workflow in [https://github.com/manaflow-ai/cmux/pull/10521](https://github.com/manaflow-ai/cmux/pull/10521). |
| [https://github.com/manaflow-ai/cmux/pull/9815](https://github.com/manaflow-ai/cmux/pull/9815) | Lawrence Chen | Superseded by the later journal state machine and restore stack in [https://github.com/manaflow-ai/cmux/pull/10521](https://github.com/manaflow-ai/cmux/pull/10521). |
| [https://github.com/manaflow-ai/cmux/pull/8503](https://github.com/manaflow-ai/cmux/pull/8503) | Lawrence Chen | Superseded by merged terminal color/font parity work in [https://github.com/manaflow-ai/cmux/pull/10429](https://github.com/manaflow-ai/cmux/pull/10429). |
| [https://github.com/manaflow-ai/cmux/pull/10413](https://github.com/manaflow-ai/cmux/pull/10413) | Lawrence Chen | Superseded by the newer restore-apply sequence in [https://github.com/manaflow-ai/cmux/pull/10521](https://github.com/manaflow-ai/cmux/pull/10521). |
| [https://github.com/manaflow-ai/cmux/pull/10571](https://github.com/manaflow-ai/cmux/pull/10571) | Lawrence Chen | Superseded by aggregate relay work in [https://github.com/manaflow-ai/cmux/pull/10603](https://github.com/manaflow-ai/cmux/pull/10603). |
| [https://github.com/manaflow-ai/cmux/pull/10408](https://github.com/manaflow-ai/cmux/pull/10408) | Lawrence Chen | Superseded spike; use the safe daemon/attach subset carried by [https://github.com/manaflow-ai/cmux/pull/10603](https://github.com/manaflow-ai/cmux/pull/10603). |

### Unsafe or not mergeable without redesign

| PR | Author | Classification and reason |
| --- | --- | --- |
| [https://github.com/manaflow-ai/cmux/pull/10428](https://github.com/manaflow-ai/cmux/pull/10428) | Lawrence Chen | Unsafe: the diagnostic PTY tap can block writes and signal forwarding. Do not merge without nonblocking I/O, process-group handling, and permission tests. |
| [https://github.com/manaflow-ai/cmux/pull/9061](https://github.com/manaflow-ai/cmux/pull/9061) | Wolfie | Unsafe/stale: nested bracketed-paste stripping changes terminal bytes without a current protocol proof. Keep closed unless re-cut and reviewed. |
| [https://github.com/manaflow-ai/cmux/pull/9062](https://github.com/manaflow-ai/cmux/pull/9062) | Wolfie | Unsafe/stale: browser-tab key documentation is detached from the current command contract. Re-cut only with current schema and behavior evidence. |

### Needs review

| PR | Author | Classification and review focus |
| --- | --- | --- |
| [https://github.com/manaflow-ai/cmux/pull/9785](https://github.com/manaflow-ai/cmux/pull/9785) | Lawrence Chen | Needs review: large native Swift frontend scope and state-ownership impact. |
| [https://github.com/manaflow-ai/cmux/pull/9022](https://github.com/manaflow-ai/cmux/pull/9022) | iarbpairs | Needs review: external scrollback fix requires current replay and bounded-memory tests. |
| [https://github.com/manaflow-ai/cmux/pull/9783](https://github.com/manaflow-ai/cmux/pull/9783) | Lawrence Chen | Needs review: persistent Pi sessions need a current durable-state and process-lifecycle design. |
| [https://github.com/manaflow-ai/cmux/pull/10321](https://github.com/manaflow-ai/cmux/pull/10321) | Lawrence Chen | Needs review: cloud TUI product scope, provider lifecycle, auth, and reconnect acceptance remain incomplete. |
| [https://github.com/manaflow-ai/cmux/pull/8769](https://github.com/manaflow-ai/cmux/pull/8769) | Lawrence Chen | Needs review: stale-server cleanup must define ownership, locking, and safe process selection. |
| [https://github.com/manaflow-ai/cmux/pull/9593](https://github.com/manaflow-ai/cmux/pull/9593) | Abdulaziz Albahar | Needs review: broker-gated iroh transport needs auth, shutdown, and dependency-boundary review. |
| [https://github.com/manaflow-ai/cmux/pull/9682](https://github.com/manaflow-ai/cmux/pull/9682) | Lawrence Chen | Needs review: Windows SSH support needs hosted Windows protocol, path, and process coverage. |
| [https://github.com/manaflow-ai/cmux/pull/10603](https://github.com/manaflow-ai/cmux/pull/10603) | Lawrence Chen | Needs review: aggregate integration candidate; exact-head checks, replay/safe-attach parity, queue ownership, and child lifecycle remain required. |
| [https://github.com/manaflow-ai/cmux/pull/10513](https://github.com/manaflow-ai/cmux/pull/10513) | Lawrence Chen | Needs review: heartbeat and host-loss stack is dirty and depends on foundational attach work. |
| [https://github.com/manaflow-ai/cmux/pull/9524](https://github.com/manaflow-ai/cmux/pull/9524) | Abdulaziz Albahar | Needs review: iroh sidecar stage needs transport security, packaging, and failure-mode evidence. |
| [https://github.com/manaflow-ai/cmux/pull/10521](https://github.com/manaflow-ai/cmux/pull/10521) | Lawrence Chen | Needs review: restore scan complexity, lifecycle ordering, and privacy findings remain unresolved. |
| [https://github.com/manaflow-ai/cmux/pull/4017](https://github.com/manaflow-ai/cmux/pull/4017) | Austin Wang | Needs review: fullscreen TUI behavior must be reconciled with current Ghostty and resize ownership. |
| [https://github.com/manaflow-ai/cmux/pull/9606](https://github.com/manaflow-ai/cmux/pull/9606) | Lawrence Chen | Needs review: persistent Daytona lifecycle and TUI reconnect need current cloud contracts. |
| [https://github.com/manaflow-ai/cmux/pull/7578](https://github.com/manaflow-ai/cmux/pull/7578) | Lawrence Chen | Needs review: VM onboarding TUI needs current CLI, auth, and provider acceptance. |
| [https://github.com/manaflow-ai/cmux/pull/7591](https://github.com/manaflow-ai/cmux/pull/7591) | Austin Wang | Needs review: extension installation and marketplace trust boundaries need current consent and pinning checks. |

### Recent merged TUI work

| PR | Author | Status |
| --- | --- | --- |
| [https://github.com/manaflow-ai/cmux/pull/10611](https://github.com/manaflow-ai/cmux/pull/10611) | Lawrence Chen | Merged, `91b991496de2667a22e65176a8f11f715e6c089b`. |
| [https://github.com/manaflow-ai/cmux/pull/10608](https://github.com/manaflow-ai/cmux/pull/10608) | Lawrence Chen | Merged, `2ee1e355c0a9b405ada3e2b812b0cec5e2ae4278`. |
| [https://github.com/manaflow-ai/cmux/pull/10606](https://github.com/manaflow-ai/cmux/pull/10606) | Lawrence Chen | Merged, `8af5331e27b832eb517bb5c1892391348b5cb6e9`. |
| [https://github.com/manaflow-ai/cmux/pull/10605](https://github.com/manaflow-ai/cmux/pull/10605) | Lawrence Chen | Merged, `51294051938830a1e3d3013a256d851ad4cfa1d3`. |
| [https://github.com/manaflow-ai/cmux/pull/10604](https://github.com/manaflow-ai/cmux/pull/10604) | Lawrence Chen | Merged, `1956d7f440add80ba35e585d83697d9dae44d3e2`. |
| [https://github.com/manaflow-ai/cmux/pull/10522](https://github.com/manaflow-ai/cmux/pull/10522) | Lawrence Chen | Merged, `409e9dc1620d47489313752f6cae4b5987d7b274`. |
| [https://github.com/manaflow-ai/cmux/pull/10601](https://github.com/manaflow-ai/cmux/pull/10601) | Lawrence Chen | Merged, `74c2d71c7ea58949a744e1545f49c72329d0e53e`. |
| [https://github.com/manaflow-ai/cmux/pull/10600](https://github.com/manaflow-ai/cmux/pull/10600) | Lawrence Chen | Merged, `1e1800db80e54d7f63e02ae5a30bbd1b2f7cb3d0`. |
| [https://github.com/manaflow-ai/cmux/pull/10559](https://github.com/manaflow-ai/cmux/pull/10559) | Lawrence Chen | Merged, `393300048360183b18d28396ba343cecfe88fa49`. |
| [https://github.com/manaflow-ai/cmux/pull/10501](https://github.com/manaflow-ai/cmux/pull/10501) | Lawrence Chen | Merged, `a4a2af086fdcc42816efb3b2bac4961b8b01c8b7`. |
| [https://github.com/manaflow-ai/cmux/pull/10486](https://github.com/manaflow-ai/cmux/pull/10486) | Lawrence Chen | Merged, `35cbaa63ce5c2768a0f64af2cf1eeb06d719232d`. |
| [https://github.com/manaflow-ai/cmux/pull/10429](https://github.com/manaflow-ai/cmux/pull/10429) | Lawrence Chen | Merged, `23f0c002883bfd4d22721ef670b1666143f7fdbb`. |
| [https://github.com/manaflow-ai/cmux/pull/10331](https://github.com/manaflow-ai/cmux/pull/10331) | Lawrence Chen | Merged, `1c33f4b93b3cbefe9aebcac5ca12484c59cefff6`. |
| [https://github.com/manaflow-ai/cmux/pull/10244](https://github.com/manaflow-ai/cmux/pull/10244) | Lawrence Chen | Merged, `b71f27ffef49d53b5b9b0a3d05e53e41d2454d9b`. |

## Wave 21 change log and current protocol audit

The exact aggregate code tip before this documentation commit is
`4efcee9a19f55322bc16cde24e2e54dade445ae9`. The rows below preserve the
pre-`cc374f8af6` ingress foundations that are part of the current tip, then
record the workspace, metadata, cleanup, Java, and protocol commits after that
tip. No row claims complete product-level backpressure or restore behavior.

| Commit | Change | Proof / residual risk | Revert chain |
| --- | --- | --- | --- |
| [`ff70454aef`](https://github.com/manaflow-ai/cmux/commit/ff70454aef7dfdc3e528b569bd326479ce83ad32), [`836ec27806`](https://github.com/manaflow-ai/cmux/commit/836ec27806ad12e38de32c9194d8ce7e4e99072f), [`7a1816acf6`](https://github.com/manaflow-ai/cmux/commit/7a1816acf68fafdc1b65c4793d9753cd0e233db3) | Bound preview/websocket messages and PTY input frames before allocation. | Rejects oversized ingress at the protocol edge; the byte-bounded workspace producer bridge remains open. | Revert the ingress limits together, retaining an explicit replacement bound. |
| [`ce4df1a352`](https://github.com/manaflow-ai/cmux/commit/ce4df1a352b01408451bc9368e0428db27db0627) | Preserve Windows named-pipe path lengths. | Avoids truncating valid pipe names; hosted Windows attach coverage remains required. | Revert this platform compatibility fix independently. |
| [`a44378f1d8`](https://github.com/manaflow-ai/cmux/commit/a44378f1d87ca6ff4c645dae60855088621ddbdb), [`efbe0bcceb`](https://github.com/manaflow-ai/cmux/commit/efbe0bccebe1d30207b923bcf62cca0f7c56bde9) | Cap and validate persisted relay configuration size and paths, failing closed on malformed config. | Bounds config allocation and path interpretation; synchronous canonicalization and TOCTOU between validation and use remain risks. | Revert config-size and config-path checks together, then restore a bounded replacement contract. |
| [`f4f51a4892`](https://github.com/manaflow-ai/cmux/commit/f4f51a48927ec4398bdb2b721ea35fe45a26248d), [`15ad87d339`](https://github.com/manaflow-ai/cmux/commit/15ad87d3397e84e43e0d6287316a5a63af50dcf1), [`c85545ea56`](https://github.com/manaflow-ai/cmux/commit/c85545ea56cd09819b7c1c7d4a9e6e7ed8fdf842) | Validate restored workspace metadata and close control on missing or invalid cwd metadata. | Invalid metadata now fails closed; relative-cwd migration remains an explicit compatibility task. | Revert metadata validation and close-control changes as one lifecycle chain. |
| [`863bdb4517`](https://github.com/manaflow-ai/cmux/commit/863bdb4517b0ffc36376793ba576fe92abe3a108), [`cc374f8af6`](https://github.com/manaflow-ai/cmux/commit/cc374f8af6bea658945d6436cb412e58adc085df), [`dac788abe3`](https://github.com/manaflow-ai/cmux/commit/dac788abe37f322f284098e03f2007edbe83f401) | Share workspace path policy, bound filesystem-watch ingress, and reject excess watches before root resolution. | Watch count and ingress bytes are bounded before expensive work; producer ownership after disconnect still needs behavior coverage. | Revert path policy, watch bounds, and capacity admission together. |
| [`fa9b8e746a`](https://github.com/manaflow-ai/cmux/commit/fa9b8e746a2f952e842caae39de84992b5101481), [`af1f9c88be`](https://github.com/manaflow-ai/cmux/commit/af1f9c88beff2c9dc139f737e34725269e40e077), [`23ef468e2e`](https://github.com/manaflow-ai/cmux/commit/23ef468e2e51c04b93574ea42c85779dc738145d) | Preflight workspace allowed roots before decoding, validate CLI root syntax, and apply canonical formatting. | Prevents malformed roots from reaching decoders; root checks still need cross-client and migration tests. | Revert preflight and CLI syntax validation together; formatting is independent. |
| [`a04df9a79d`](https://github.com/manaflow-ai/cmux/commit/a04df9a79d30aa52c41c13607279e159f1d0a8e2), [`09ec949a23`](https://github.com/manaflow-ai/cmux/commit/09ec949a2398be1f5c53f33da2746f2006640e12), [`f2cc4e3739`](https://github.com/manaflow-ai/cmux/commit/f2cc4e37397f90b65978774f67926451129cc2d5) | Reject malformed strict PTY tab metadata, format the strict metadata path, and close control on strict-tab failure. | Strict-tab failure no longer leaves a control path open; behavior coverage remains hosted-only. | Revert the strict metadata and cleanup commits together. |
| [`531e81ae70`](https://github.com/manaflow-ai/cmux/commit/531e81ae702523ae577a4a9585a03f8a453d3fa6) | Avoid cloning PTY ingress frames. | Removes an avoidable allocation on the hot path; bounded admission and lifetime ownership remain separate concerns. | Revert this optimization independently. |
| [`09aedd37f4`](https://github.com/manaflow-ai/cmux/commit/09aedd37f4f0115ef00a42b4018e0f8bee805860) | Add a bounded Java Unix-socket connect timeout and connector cleanup. | The stale Java-timeout residual is closed by this change; hosted Java interruption and timeout tests remain the authority. | Revert timeout and cleanup together, retaining an explicit timeout contract. |
| [`f6781f44da`](https://github.com/manaflow-ai/cmux/commit/f6781f44da70bc557b1ad3001c44820e40d9d93a), [`4efcee9a19`](https://github.com/manaflow-ai/cmux/commit/4efcee9a19f55322bc16cde24e2e54dade445ae9) | Reject undeclared journal protocols and bound compatibility acceptance. | Older declared protocols remain supported; undeclared or oversized compatibility paths fail closed. Hosted cross-version tests remain required. | Revert the compatibility test and implementation together. |

Strict-tab cleanup and Java connect timeout are no longer residual defects in
this board. Remaining risks are narrower: the byte-bounded workspace producer
bridge still needs end-to-end ownership and cancellation proof; synchronous
canonicalization can still block a request path; validation and later use can
still have a TOCTOU window; and relative cwd migration needs a documented
absolute/home-relative contract.

## PR decisions after Wave 21

| PR | Author | Status | Decision |
| --- | --- | --- | --- |
| [https://github.com/manaflow-ai/cmux/pull/10603](https://github.com/manaflow-ai/cmux/pull/10603) | Lawrence Chen | Open, current head `723f2079b3a23536f0deb0d953ed6732f60fa339` | Aggregate remains the integration vehicle; exact-head checks and queue/lifecycle review are required. |
| [https://github.com/manaflow-ai/cmux/pull/10607](https://github.com/manaflow-ai/cmux/pull/10607) | Lawrence Chen | Open, head `126d772a131ce71f245ae56c3048aa99f3607d17` | Superseded by [https://github.com/manaflow-ai/cmux/pull/10603](https://github.com/manaflow-ai/cmux/pull/10603), which contains its identity-shape and protocol fixes. |
| [https://github.com/manaflow-ai/cmux/pull/10609](https://github.com/manaflow-ai/cmux/pull/10609) | Lawrence Chen | Open, head `bdcbb8c8049eb552a0d646cdce78d58d294b7b82` | Needs review for action-result queue ownership, saturation, cancellation, and retry behavior. |
| [https://github.com/manaflow-ai/cmux/pull/10612](https://github.com/manaflow-ai/cmux/pull/10612) | Lawrence Chen | Open, clean head `1a7f82c9d59755db3b00f27040b37a4aeb10c7b4` | Needs review. Inherited Greptile finding: `theme.chrome=auto` documentation says unavailable OSC 11 always falls back to dark, while startup uses the configured-background fallback. Resolve the documentation/runtime mismatch before merge. |

## Wave 22 bounded transport tail

The exact aggregate code tip immediately before this board commit is
`b61f1bada6498ee9d6549f4550f9a062f327f22c`. The companion
`TECH-DEBT-CHANGELOG.md` is a historical snapshot at an older tip. This table
is the current revert map. A bound at one ingress edge is not a claim of global
backpressure or complete remote-session recovery.

| Commit | Change | Evidence and residual risk | Revert chain |
| --- | --- | --- | --- |
| [`30419a1ad9`](https://github.com/manaflow-ai/cmux/commit/30419a1ad9943ead006239aa46358227fdb21f8e) and [`7f8c8c3f11`](https://github.com/manaflow-ai/cmux/commit/7f8c8c3f11e2ff6563993f72e6f2f494f7ec2071) | Bound remote stream chunk channels and add saturation, reset-drain, and permit-release tests. | `try_send` resets a full stream and releases its budget. Hosted cross-client reset and retry behavior remain open. | Revert the channel change and its tests together. |
| [`70ac436947`](https://github.com/manaflow-ai/cmux/commit/70ac43694725ed14abf1a01ab42b62141abc9853), [`33c5804900`](https://github.com/manaflow-ai/cmux/commit/33c58049008f71fedfef2ca5845bd9733a9d2594), [`b233104b30`](https://github.com/manaflow-ai/cmux/commit/b233104b3036275c1a359d8d83b9ba717a6fa637), and [`aadd1c8da8`](https://github.com/manaflow-ai/cmux/commit/aadd1c8da8b83b480aebb1f720e5322b8f335a93) | Bound preview WebSocket queues by message count and bytes, cancel replaced peers, admit a complete PTY frame before the output cap, and bound displaced-peer writer cleanup. | Slow peers now fail closed or receive a bounded close. The one-second flush policy and raw attach backlog truncation still need behavior tests. | Revert the preview queue, cancellation, PTY admission, and cleanup commits as one peer-lifecycle chain. |
| [`35a3aaa104`](https://github.com/manaflow-ai/cmux/commit/35a3aaa10454b7206f54f8259bac1bf43622f06c) | Reject oversized critical frames and limit critical-frame priority bursts so watch traffic gets service. | Queue fairness is explicit. Global producer ownership and retry semantics remain open. | Revert this outbound scheduling change independently. |
| [`80d5a5393c`](https://github.com/manaflow-ai/cmux/commit/80d5a5393cc5654d00d254adc9c9b78c4e1573df), [`8c9e530326`](https://github.com/manaflow-ai/cmux/commit/8c9e530326af78ff0e2f256835746bb87d44c714), and [`9a887a2e05`](https://github.com/manaflow-ai/cmux/commit/9a887a2e05917572be7b7a79ec94e2ccdb5f81c) | Validate known relay frame versions, bound Iroh accept-result buffering, and make watch replacement and overflow signaling generation-safe. | Malformed known versions fail closed. Hosted cross-version, Iroh shutdown, and filesystem-watch cancellation tests remain required. | Revert protocol parsing separately; revert Iroh and watch admission together with their lifecycle tests. |
| [`c7e66ee6ac`](https://github.com/manaflow-ai/cmux/commit/c7e66ee6ac4e7e42798faba2635869337801cbb6) | Reserve filesystem-watch capacity before spawning and announce an opened watch before event delivery. | Prevents duplicate admission during a race. Synchronous filesystem work, parent-directory TOCTOU, and cancellation after disconnect remain open. | Revert this watch ownership change with the watch replacement chain. |
| [`2ac781a18e`](https://github.com/manaflow-ai/cmux/commit/2ac781a18ef25a019bb5cb22d65b6b02688dca5f), [`e7a931766a`](https://github.com/manaflow-ai/cmux/commit/e7a931766adc6709f3f5422d2f0ee3acb616c731), and [`643dbfe2e5`](https://github.com/manaflow-ai/cmux/commit/643dbfe2e5d688f07f633b92d758e7990ad55e31) | Install watch tasks only for the current generation, latch watcher errors when the bounded event queue is full, and wake the loop for latched errors or outbound send failure. | Overflow and watcher errors now reach the loop instead of waiting indefinitely. Cancellation after disconnect, synchronous filesystem work, and parent-directory TOCTOU remain open. | Revert these three watch wakeup and lifecycle commits together with the watch admission chain. |
| [`b61f1bada6`](https://github.com/manaflow-ai/cmux/commit/b61f1bada6498ee9d6549f4550f9a062f327f22c) | Apply Rust formatting to the relay PTY, session, and workspace changes after the watch hardening tail. | Formatting only. It adds no behavior proof; rerun formatter, compile, and focused watch tests after further edits. | Revert this formatting commit independently; retain the behavior and test commits. |
| [`c30f737369`](https://github.com/manaflow-ai/cmux/commit/c30f7373694abfe39f52aa58330ffe011139f7fd), [`dc8f116bfd`](https://github.com/manaflow-ai/cmux/commit/dc8f116bfda28021670b4668f37a7c693b4b84e8), and [`41a1bebf4c`](https://github.com/manaflow-ai/cmux/commit/41a1bebf4c77299ef7d271462e732aba37d9576d) | Guard TypeScript data callbacks, share one Go fallback deadline, and make concurrent Python close callers await one cleanup task. | The callback no longer escapes through `EventEmitter`; fallback no longer multiplies the timeout; Python cleanup is joinable. Long Unicode socket paths and hosted multi-language cancellation tests remain open. | Revert each binding fix with its focused test; do not revert the shared protocol contract. |

## Wave 23 fairness and lifecycle tail

The exact aggregate code tip immediately before this board commit is
`05c0b30277f5ab9c22516b17a285756e0edbde32`. These rows follow the Wave 22
transport bounds and keep their residuals open. They record targeted ownership
and fairness fixes, not complete relay or PTY recovery.

| Commit | Change | Evidence and residual risk | Revert chain |
| --- | --- | --- | --- |
| [`c11cb7fe95`](https://github.com/manaflow-ai/cmux/commit/c11cb7fe95ac7ee6acedf2f8a7db5e17bbec39c8) | Share one socket text-send helper for heartbeat and outbound frames while preserving pending-byte accounting. | Removes duplicate send and error handling. It does not prove producer cancellation, reconnect ordering, or raw attach backlog behavior. | Revert the helper independently; retain the bounded queue contract. |
| [`4d96818339`](https://github.com/manaflow-ai/cmux/commit/4d9681833950f454c27060f62d800897ab2488ee) | Bound accepted heartbeat intervals to the Node timer limit, `1..=2,147,483,647` ms. | Rejects values that could become unsafe or near-immediate timers. Cross-language timer, reconnect, and heartbeat-liveness tests remain required. | Revert the parser bound and boundary tests together. |
| [`ba8f2941a6`](https://github.com/manaflow-ai/cmux/commit/ba8f2941a6b3b32ce73c295605bec86fa1cdc010) | Reset the critical-burst fairness gauge on heartbeat and incoming traffic, and release pending-byte accounting when critical delivery fails. | Prevents a failed send from leaking the pending gauge and lets control traffic reset the burst. End-to-end starvation and disconnect tests remain open. | Revert this accounting and fairness cleanup with its focused tests. |
| [`4325b75969`](https://github.com/manaflow-ai/cmux/commit/4325b759694e57af819fd4075045431086717e02) | Service the critical relay queue in bounded eight-frame bursts, then allow watch, heartbeat, and incoming traffic; keep direct PTY/auth handles available for the worker. | Critical traffic remains bounded while other sources receive service. Queue ownership across retry, cancellation, and shutdown remains open. | Revert the fair-select change with the gauge cleanup, retaining frame caps. |
| [`2e33e1a07b`](https://github.com/manaflow-ai/cmux/commit/2e33e1a07b5a25bccb93fb9e191539127163ab7e) | Remove a shell-start reservation when the persistent-shell cap rejects a request. | A rejected start no longer leaks a reservation or blocks later starts. PTY process-group cleanup, raw attach backlog loss signaling, and restart persistence remain open. | Revert the reservation cleanup independently; preserve the cap and admission contract. |
| [`05c0b30277`](https://github.com/manaflow-ai/cmux/commit/05c0b30277f5ab9c22516b17a285756e0edbde32) | Merge the 25-file relay/TUI integration from `origin/codex/chatmux-relay-techdebt`, including the TypeScript socket contract and tests, terminal client, native app/session/UI, docs, smoke, inventory, and publish-security updates. | This is structural integration, not completion proof. Exact-head Rust, TypeScript, Python, and behavior checks must inspect the resolved transport conflicts and the new session/UI paths. | Revert the merge to `2e33e1a07b`; keep the bounded transport and fairness commits as a separate chain. |

## Wave 24 SDK, overflow, and capability tail

The exact aggregate code tip immediately before this board commit is
`e8df21eed2866eba03b2548e790ba8a5a887b5da`. These rows follow the Wave 23
merge and record bounded failure behavior across the relay, SDKs, CLI, and
provider contract. They do not prove cross-platform release or restore parity.

| Commit | Change | Evidence and residual risk | Revert chain |
| --- | --- | --- | --- |
| [`97dbc18bfd`](https://github.com/manaflow-ai/cmux/commit/97dbc18bfd0d83f4abfbe247024fb105f27a411d), [`b94f21108e`](https://github.com/manaflow-ai/cmux/commit/b94f21108ee5fd8c6ede4cbc94bf4a9a1dc8c068), and [`47082c21d4`](https://github.com/manaflow-ai/cmux/commit/47082c21d40db9c956404e1483984dc8ef510c72) | Turn raw PTY attach backlog overflow into an explicit `pty_error` with code `overflow`, close the affected attachment, and require reattach. | Accepted bytes stay ordered and excess bytes no longer disappear silently. Every client must handle the error and reattach; replay, process-group cleanup, and loss reporting remain open. | Revert the raw backlog and protocol-error commits together. |
| [`0a6a7e2e91`](https://github.com/manaflow-ai/cmux/commit/0a6a7e2e918e006299d4074197c7966b7d1dc3c6) and [`e8df21eed2`](https://github.com/manaflow-ai/cmux/commit/e8df21eed2866eba03b2548e790ba8a5a887b5da) | Disconnect preview peers when a bounded queue saturates, fail closed on initialization or ping enqueue failure, and format the guard. | A slow or incoherent peer no longer receives silently dropped CDP frames. Reconnect and target-state behavior need browser-level proof. | Revert the saturation behavior and formatting together. |
| [`e9a9f89c1e`](https://github.com/manaflow-ai/cmux/commit/e9a9f89c1ebde8f60d8242c78baac4fcdd30ef3a) | Bound Git workspace pathspecs and cap `git status` output before parsing. | Root-scoped validation and output caps reduce allocation risk. Parent-directory TOCTOU between validation and Git use remains open. | Revert pathspec and status bounds together, retaining an explicit cap. |
| [`f36f57d56f`](https://github.com/manaflow-ai/cmux/commit/f36f57d56ffe90f3ec0cee1069c40b52622f9468) and [`8b61aede0b`](https://github.com/manaflow-ai/cmux/commit/8b61aede0bf33318d1bf9f5e04d19bab5256e88b) | Make the Java Unix accept test wait for the server and close the transport on EOF. | The test no longer races listener teardown, and later Java operations fail deterministically after EOF. Hosted Java interruption, timeout, and repeated-close coverage remains required. | Revert the test synchronization and EOF cleanup together. |
| [`bcf0bb643b`](https://github.com/manaflow-ai/cmux/commit/bcf0bb643b1031010deab5fa40040d31f2fc94f1) and [`051d8c17b2`](https://github.com/manaflow-ai/cmux/commit/051d8c17b2a117414245c71c6e02ffb40214554d) | Preserve Zig resolved connection types and unwind the connection when path allocation fails. | Zig fallback and direct paths release ownership on allocation failure. Cross-platform allocator and fallback tests remain required. | Revert both Zig ownership fixes together. |
| [`df28816dba`](https://github.com/manaflow-ai/cmux/commit/df28816dba899e11296775a98182a583f431be88) and [`d85629e39e`](https://github.com/manaflow-ai/cmux/commit/d85629e39e82e5560818af811bf0f35a255686ce) | Pass Rust MSRV components as separate rustup flags in SDK and relay workflows. | CI now expresses component installation in the supported form. Hosted MSRV and release artifacts remain the authority; no local Rust proof is claimed. | Revert the workflow syntax changes together. |
| [`57b8bbeba9`](https://github.com/manaflow-ai/cmux/commit/57b8bbeba9c5d44385e1530682c9299ca3db0db6) | Satisfy full-workspace Clippy after the integration merge. | The narrow lint issue is addressed. This is not a substitute for a local Rust compile or hosted behavior run. | Revert this lint-only change independently. |
| [`6d364cf171`](https://github.com/manaflow-ai/cmux/commit/6d364cf1718ba6fd60556304c411c0af146b2ba1), [`175243036f`](https://github.com/manaflow-ai/cmux/commit/175243036f6a2625d4b9f469b142d6eee2ba40ad), and [`77520f11b8`](https://github.com/manaflow-ai/cmux/commit/77520f11b8e30aef0bf7750e237b828c1661f644) | Pin TypeScript socket fallback order, ignore non-contract temporary variables, and suppress queued errors after intentional transport close. | Runtime fallback selection and close state are now tested and guarded. Long-path, reconnect, and handler-failure behavior remain open. | Revert the TypeScript fallback and close chain together. |
| [`dfdcf87294`](https://github.com/manaflow-ai/cmux/commit/dfdcf8729466104544fda5a73d337f648b44346c) and [`d372eb573d`](https://github.com/manaflow-ai/cmux/commit/d372eb573dad43bd127a29d9f1b64b1216bf68fa) | Reject invalid Go transport write counts and close a replaced C++ Unix socket during move assignment. | Invalid write results fail closed and C++ replacement releases the old descriptor. Hosted SDK matrix and repeated move/close tests remain required. | Revert both SDK lifecycle fixes together. |
| [`8113a59bd5`](https://github.com/manaflow-ai/cmux/commit/8113a59bd5f5f8443e13277c7f45a096b07c0771), [`a6a900a969`](https://github.com/manaflow-ai/cmux/commit/a6a900a96942f2e61570346f542ea4c7bd69712d), and [`5fe58262de`](https://github.com/manaflow-ai/cmux/commit/5fe58262de2321833f1ee6a69c7391e494976eaf) | Centralize remote-command classification for Unix and non-Unix startup, and make boolean CLI flags explicit metadata with tokenizer tests. | Startup routing and boolean parsing now share one grammar. Unknown flags, aliases, and cross-platform command behavior still need hosted coverage. | Revert classifier and metadata changes together with their tests. |
| [`41c5e637a5`](https://github.com/manaflow-ai/cmux/commit/41c5e637a587c2a7db84d0ddfcb2083894cedb73), [`db18624a11`](https://github.com/manaflow-ai/cmux/commit/db18624a11397629d8219e4530516fa7009e5526), and [`9d0d631694`](https://github.com/manaflow-ai/cmux/commit/9d0d631694852ec75eb33a1e15c2be44abcafb55) | Remove a watch registry entry even when startup exits before handle installation, await relay cleanup after abort, and test cancellation-safe Python close joining. | Early watcher failure and cancellation now have explicit cleanup paths. Shutdown ordering across all producers and SDKs remains open. | Revert these cleanup and test commits as one lifecycle chain. |
| [`b94e6fd14b`](https://github.com/manaflow-ai/cmux/commit/b94e6fd14b9d847bfdc272d90a2827f0781581db) and [`4b12ef9e07`](https://github.com/manaflow-ai/cmux/commit/4b12ef9e070558bd3caa50fe8f6407319231863e) | Document optional `connection-progress-v1` capability negotiation and place the capability note in the provider summary. | Providers may emit advisory progress only after negotiation. Legacy clients, unknown capability filtering, and live progress ordering still need behavior tests. | Revert the two documentation placements together; retain the protocol contract only if separately versioned. |

## Wave 25 lifecycle, socket, packaging, and C1 tail

The exact aggregate code tip immediately before this documentation commit is
`ace9e5f57fb7e98d45aa8a22cdf2efa0fac09ec6`. The rows below follow Wave 24 and
record child ownership, journal finalization, socket cleanup, SDK fallback
tests, package executable bits, and 8-bit terminal control parsing. The
documentation-only bridge commits
[`42b776a327`](https://github.com/manaflow-ai/cmux/commit/42b776a327c17386d131ef1b1f8a382b02683954)
and [`cef7c71460`](https://github.com/manaflow-ai/cmux/commit/cef7c71460f72444e874f7c9f26100e9259874c1)
preserve the prior board and changelog evidence and make no runtime claim.

| Commit | Change | Evidence and residual risk | Revert chain |
| --- | --- | --- | --- |
| [`c906a2ff62`](https://github.com/manaflow-ai/cmux/commit/c906a2ff62b73968b32d00e48072f5afe15d5351) | Kill and await the credential command on missing stdout, read failure, and timeout. | Every credential-command error path now reaps its child instead of relying on `kill_on_drop`. Generic relay child timeout and cancellation paths still need a durable cancellation token and awaited ownership. | Revert this credential-child lifecycle fix with its error-path coverage. |
| [`fb3ac754c5`](https://github.com/manaflow-ai/cmux/commit/fb3ac754c5d55869f968289e3906e3b6b6b0872e) | Reserve journal-writer ownership before spawn and make `Mux` drop close and join the writer. | Duplicate writers cannot start and the owner state is explicit. Durable gap delivery still depends on a lifecycle owner calling `shutdown` before releasing the final `Arc<Mux>`. | Revert the writer owner-state and `Mux` drop changes together. |
| [`ab2b944ab8`](https://github.com/manaflow-ai/cmux/commit/ab2b944ab81a2ebf09a0c595b185344665f9c74f) | Hand a journal writer self-join to a reaper thread. | A writer that drops the last `Mux` owner no longer deadlocks waiting on itself. Reaper creation and panic reporting still need hosted shutdown coverage. | Revert the self-join handoff and its behavior test together. |
| [`5f8860398e`](https://github.com/manaflow-ai/cmux/commit/5f8860398ee30e255f37cc5e8633159fb0058aa1) and [`09190e6da9`](https://github.com/manaflow-ai/cmux/commit/09190e6da92b60a60000913b9cbf9931ea4b94c7) | Coordinate journal finalization through shared completion state and apply the hosted formatter output. | Concurrent closers wait for one join result, and terminal-reader drain, gap emission, and writer close share one path. Late queued bytes during self-drop remain best-effort until the lifecycle owner calls `shutdown`. | Revert finalization and formatting as one writer-lifecycle chain. |
| [`5f6bf91e76`](https://github.com/manaflow-ai/cmux/commit/5f6bf91e760c1feb97671aa19f800e3e4f80674d) and [`c8ec5be775`](https://github.com/manaflow-ai/cmux/commit/c8ec5be775352f54acb0707abc13efa6e4be163b), [`44a2f05134`](https://github.com/manaflow-ai/cmux/commit/44a2f0513465da2e81c484319f2e44827a0491d8) | Make Rust SDK hashed-to-legacy fallback tests bindable, construct hashed endpoints in a safe runtime directory, and apply hosted formatting. | Tests no longer depend on an overlong legacy socket path or an unbound endpoint. Cross-language fallback, long-path, and hosted Rust verification remain required. | Revert the fallback test and formatting commits together. |
| [`8523b8f715`](https://github.com/manaflow-ai/cmux/commit/8523b8f7151bdb032d011cb512a32e878fc813da) | Give Zig fallback results an explicit `ResolvedConnection` type. | The connection and owned path contract is named at the API boundary. Zig allocator and cross-platform fallback tests remain required. | Revert the Zig type-naming change independently. |
| [`782fba0f2a`](https://github.com/manaflow-ai/cmux/commit/782fba0f2abe4f41c74a060caffa36a9c3efc73d) | Create missing parents for an explicit socket path and reject symlink or non-directory parents. | Explicit custom paths now work in a new nested directory without changing existing directory permissions. Parent replacement races and later bind authority checks remain open. | Revert explicit-parent preparation and its behavior test together. |
| [`f5fdf26ccd`](https://github.com/manaflow-ai/cmux/commit/f5fdf26ccd8f931623adabe711b898b47665d722) and [`80fd1621fa`](https://github.com/manaflow-ai/cmux/commit/80fd1621fa8dfa5b25b5767f9711c8afa15e5b65) | Unlink Unix sockets synchronously on server-wrapper drop, verify the published inode, and retain the path lease until the listener task drops. | A dropped wrapper no longer leaves a stale pathname while its accept task is pending, and replacement sockets are not unlinked by an old owner. Accepted-task shutdown and multi-process path races remain open. | Revert synchronous cleanup and lease retention together. |
| [`11c309d701`](https://github.com/manaflow-ai/cmux/commit/11c309d7013a5be96a9bc0d00a44f7b75e850399) | Preserve executable mode for npm relay and client launchers during packaging. | The package script restores execute bits in generated output, and checked-in launchers carry mode `100755`. Registry-install and offline smoke evidence remain required. | Revert the package-mode guard and launcher mode changes together. |
| [`c56afcad5f`](https://github.com/manaflow-ai/cmux/commit/c56afcad5fe8ba0c1583e9b8f53335faaeeb4e3a) and [`ace9e5f57f`](https://github.com/manaflow-ai/cmux/commit/ace9e5f57fb7e98d45aa8a22cdf2efa0fac09ec6) | Test and parse 8-bit C1 CSI and string introducers in cursor provenance, including split chunks and C1 ST termination. | C1 forms no longer pass through as ordinary payload, so cursor authorship and reset behavior match their 7-bit forms. Full ECMA-48, cross-platform rendering, and Ghostty parity remain unverified. | Revert the C1 parser and focused tests together. |

## Open user intents mined from `~/.claude` and `~/.codex`

These records are requests, not completion evidence. Every row remains open
unless its acceptance column says that a narrow implementation slice exists.

| Intent | Evidence path and lines | Acceptance and current status |
| --- | --- | --- |
| Session catalog, device identity, and one canonical session across devices. | `/Users/lawrence/.codex/history.jsonl:18409,18422,18428`; `/Users/lawrence/.claude/history.jsonl:20261,20280` | A fresh TUI starts with one session, workspace, screen, and terminal. A catalog exposes stable device and session IDs. macOS and iPhone attach to the same canonical session, and a multi-device rail can reorder without creating duplicates. Open. |
| Resize geometry must not leave blank space. | `/Users/lawrence/.codex/history.jsonl:2314,5160` | Reproduce resize and split transitions with scrollback, backing scale, and embedded web content. Prove point and pixel geometry stay consistent, with no blank terminal or web regions after repeated resize. The audit records a unit mismatch and repeated blank-space reports; this remains an open user request. |
| Same-cwd session-to-surface mapping and restoration. | `/Users/lawrence/.codex/history.jsonl:12793,1596` | Expose one diagnostic mapping for durable session, workspace, pane, surface, cwd, and session directory. Restore a session to its own cwd and surface, never a subagent's cwd or a stale surface. Current evidence asks for this mapping and shows runtime cwd/surface fields, but no end-to-end ownership proof. Open. |
| PTY ownership and persistence across cmux restart, plus one terminal worker per workspace. | `/Users/lawrence/.codex/sessions/2026/07/16/rollout-2026-07-16T21-13-34-019f6e47-9ae4-7073-a6b6-d441ebf6a707.jsonl:9,103,133,212,697,718,772`; `/Users/lawrence/.codex/history.jsonl:17607-17614` | A stable host or cmux-tui owner keeps the PTY and process alive across Swift or renderer restart. One helper process serves one workspace, with one terminal process per workspace as the ownership contract, not one shared PTY for unrelated sessions. No duplicate PTY readers, dropped startup commands, or output overtaking. Open. |
| cmux-tui backend IPC and state contract, with measured render and PTY isolation. | `/Users/lawrence/.codex/sessions/2026/07/16/rollout-2026-07-16T21-13-34-019f6e47-9ae4-7073-a6b6-d441ebf6a707.jsonl:617,943,1010,1596,1679,1828,2124,2142` | Define versioned input, resize, focus, semantic-state, frame-sequence, launch-token, and restart messages. Prove PID ownership, frame latency, CPU, and memory separately for renderer and PTY paths. The transcript reports a fallback worker and no valid performance result, so this is open. |
| Stale pane and surface self-heal. | `/Users/lawrence/.codex/history.jsonl:18517-18518,17151,17163,17176`; `/Users/lawrence/.claude/history.jsonl:88931,88938,89986`; `/Users/lawrence/.codex/sessions/2026/07/16/rollout-2026-07-16T21-13-34-019f6e47-9ae4-7073-a6b6-d441ebf6a707.jsonl:1828,2124,2142` | Detect missing or stale references, refresh the authoritative catalog, close dead viewers, and reattach without duplicate viewers or orphan PTYs. Reconnect must report a bounded, actionable error when the host or relay is stale. Open. |
| Journal-first persistence and restart recovery. | `/Users/lawrence/.codex/history.jsonl:17607-17614,17620,17623`; `/Users/lawrence/.claude/history.jsonl:89427,89528,89886` | Provider hooks append events. A deterministic reducer rebuilds projections and idempotency receipts in one SQLite transaction. The live PTY owner handles detach and mux restart. Host reboot recovery needs explicit policy and journaled intent and outcome. Do not treat a snapshot or a process restart as proof of recovery. Open. |
| npm and PyPI packaging with executable smoke checks. | `/Users/lawrence/.codex/history.jsonl:18401,18484,18569-18572`; `/Users/lawrence/.claude/history.jsonl:89295,89298`; `.github/workflows/cmux-tui-build-package.yml:625-750`; `tests/test_tui_npm_package_artifact.py:213-218` | Build npm directories and exactly six version-matched wheels, validate `RECORD` and hook mode, install offline, run `cmux --help`, and test Linux x64 and arm64 entrypoints. The validator is now called before wheel smoke checks. Hosted publish and registry-install proof remain open. |
| Versioned socket and WebSocket API. | `/Users/lawrence/.codex/history.jsonl:15355,15358-15360`; `/Users/lawrence/.claude/history.jsonl:87965`; `/Users/lawrence/.codex/sessions/2026/07/16/rollout-2026-07-16T18-27-37-019f6daf-ad64-7063-b9dd-af12d63e945b.jsonl:131` | Unix socket, SSH, WebSocket, and Iroh transports must share one authenticated workspace contract. Subscribe-before-snapshot, attach-surface, ordered events, bounded frames, reconnect, and close behavior must be tested on each transport. Open. |
| Remote attach and Iroh discovery. | `/Users/lawrence/.codex/history.jsonl:15355,16276,16290-16294,17151,17153,17163,17176`; `/Users/lawrence/.claude/history.jsonl:87548-87549,87765-87766,87776,87802` | Authenticated devices discover peers without a hidden polling dependency. Remote attach must prove PTY ownership, direct versus relay path, latency, reconnect, and cleanup. Existing Iroh preflight reports a closed host and missing socket, so no success claim is allowed. Open. |
| Cloud snapshot no-go for live PTY persistence. | `/Users/lawrence/.codex/history.jsonl:18564,18569-18572`; `/Users/lawrence/.claude/history.jsonl:87599,89270,89295,89298` | A provider snapshot may package cmux-tui and tools in a base image. It must not be treated as the journal, a live PTY owner, or a restart guarantee. Measure snapshot and resume times separately, and reject a cloud integration until provider restore semantics and secret boundaries are proven. Explicit no-go for inferring persistence from a snapshot. |
| Semantic colors and cross-platform parity. | `/Users/lawrence/.codex/history.jsonl:18402,18410,18423-18424,18461,18472`; `/Users/lawrence/.claude/history.jsonl:87551,87950,87970`; [PR #10612](https://github.com/manaflow-ai/cmux/pull/10612) | Compare semantic ANSI, OSC, theme-query, cursor, and font behavior against Ghostty on macOS, Linux, Windows, and remote clients. Include light and dark backgrounds, 256-color output, Kitty graphics, and screenshot or pixel evidence. The current review mismatch for `theme.chrome=auto` is unresolved. Open. |
| Multilingual and emoji glyph verification fixture. | `/Users/lawrence/.codex/transcription-history.jsonl:3`, record `ccc037fb-aff5-4bb0-909b-0979d129ee41` | Define a broad corpus, render it in the TUI, and assert screenshot or cell-width invariants that reproduce the Star Wars emoji failure. Open. |

## Residual risks after Wave 25 integration

- Several queues now have byte and count caps, but a workspace producer can
  still outlive its consumer across disconnect, retry, and shutdown. Ownership,
  cancellation, and permit release need an end-to-end behavior test.
- PTY output admission checks a complete frame at one boundary. Raw attach
  backlog overflow now emits `pty_error` code `overflow` and closes the
  affected attachment, but replay, process-group cleanup, client reattach, and
  loss reporting still need an end-to-end contract.
- Synchronous canonicalization and filesystem work can block a request path.
  Validation and later use still have a parent-directory TOCTOU window. The
  workspace path bounds do not make that parent immutable between check and use.
- Relative PTY cwd migration needs a documented absolute or home-relative
  contract. Existing rejection is safer, but it can break old callers.
- Iroh connection teardown can wait for a long pre-auth timeout. Tie link
  shutdown to connection cancellation before claiming prompt cleanup.
- The renderer transcript has no live worker PID or completed IOSurface proof.
  No render or PTY performance result is claimed.
- No local Rust compile or end-to-end hosted result is claimed in this board.
  Cross-language packaging, relay, restore, and remote attach remain open.
- Journal writer ownership and finalization now have explicit reservation,
  joining, self-join handoff, and shared-completion states. Hooks and providers
  still need one append boundary, one reducer owner, idempotency receipts, and
  explicit shutdown ordering. Late self-drop gaps remain best-effort, and the
  intent audit does not prove restart recovery.
- The new Java, Zig, Go, C++, TypeScript, and Rust SDK fallback changes have
  focused evidence only. No local Rust compile is claimed, and hosted SDK,
  MSRV, reconnect, packaging, and cross-language behavior results remain
  required.
- Unix socket cleanup now checks device and inode and retains the lease through
  listener-task drop. Parent-directory replacement, accepted-task shutdown,
  and multi-process races remain open.
- The C1 parser handles the covered CSI and string forms, but complete terminal
  control parity and measured renderer behavior remain open.
- Credential-command failures now reap children on all listed error paths.
  Generic relay and Git child timeout paths still need explicit cancellation
  and awaited process-group cleanup.
- The 25-file merge includes resolved TypeScript transport conflicts and broad
  native session/UI changes. Exact-head compile, protocol, and behavior review
  of that merge remains required; the merge itself is not acceptance evidence.
- Java connect-timeout and strict-tab cleanup are recorded as addressed in
  Wave 21. Do not re-list them as current defects without a new reproduction.
- Global CLI values now accept standard `--flag=value` syntax. Nested command
  options retain their previous grammar and need a separate compatibility decision.
- Preview target listeners are capped at 32 with LRU eviction, duplicate CDP
  request IDs no longer grow the order deque, and injected HTML is limited to
  8 MiB and 30 seconds. Hosted relay behavior still needs exact-head proof.
- Windows relay exec now uses a Job Object with kill-on-close and a bounded
  final wait. Hosted Windows compile and descendant cleanup evidence remain.
- Go and TypeScript no longer probe a raw `/tmp` socket when a fitting runtime
  path exists. TypeScript package compilation was unavailable locally because
  `tsc` is not installed; hosted SDK checks remain required.
- Python cleanup propagates cancellation of its shared task without spinning.
  The focused and full Python suites pass, but hosted cross-language checks
  remain required.
- Windows drive-prefix parent creation and platform-separated allowed-root
  parsing now have source-level tests. Hosted Windows execution remains the
  acceptance boundary.

The ledger remains an honest lower bound of at least 205 substantive agent
turns. It is not an exact session-file count. The requested 10,000-session
target is not reached, and no empty sessions were created to inflate it.

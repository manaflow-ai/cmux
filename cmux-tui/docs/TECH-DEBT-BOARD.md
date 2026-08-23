# cmux-tui technical-debt board

Last updated: 2026-08-23.
Audit base: `origin/main` at `17466308a52cb53e417e07085f108800efedd267`.
Integration branch: `feat-tui-tech-debt-wave1-clean`.
Current integration code tip: `14bf092017`.
The branch is pushed to `https://github.com/manaflow-ai/cmux/tree/feat-tui-tech-debt-wave1-clean`.
The combined review PR is `https://github.com/manaflow-ai/cmux/pull/10602`.

Subagent ledger: at least 120 substantive agent turns are complete in this
run. The count includes code audits, web research, session mining, fixes,
reviews, and merge gates. It excludes empty or duplicate turns. The requested
10,000-session target is not reached. I will not create empty sessions to
inflate the count. New turns must have a named deliverable.

## Current state

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
| Scoped attach mouse/cursor correctness | [PR 10428](https://github.com/manaflow-ai/cmux/pull/10428) | Complete through replay, reattach, and CI XCUITest. Focus forwarding and OSC 52 remain pre-existing gaps. |
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
| Cloud TUI | Build/auth/create/resume/enroll/attach, machine rail, provider-neutral status, lifecycle operations, reconnect, packaging, version rollback, accessibility. | Checklist remains unchecked in `plans/cmux-devboxes.md` (not copied into this worktree). |
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
| [#10428](https://github.com/manaflow-ai/cmux/pull/10428) | Lawrence Chen | Rebasing and cursor test landed at `076d648a2c`; hosted run `32634173482` pending. | Refresh checks and run the exact-head merge gate. |
| [#10513](https://github.com/manaflow-ai/cmux/pull/10513) | Lawrence Chen | Stacked head `55caae646e`; dedicated heartbeat fix `18b05775d8` and dead idle-state cleanup `d599fd89e0` are prepared on the in-org stack, but the branch is dirty. | Land the foundational stack with hosted coverage before merging the liveness fixes. |
| [#10521](https://github.com/manaflow-ai/cmux/pull/10521) | Lawrence Chen | Head `087bb3496a`; compile fixes pushed as `392bb50b92`, hosted run `32638928481` pending. Complexity and host-state race findings remain. | Do not merge until those findings have an explicit design resolution. |
| [#10537](https://github.com/manaflow-ai/cmux/pull/10537) | dkta0 | External author branch. Candidate fix `65d19bc694` cannot be pushed to the external fork. | Do not push outside `manaflow-ai`; use an in-org re-cut only if the semantic fix is redesigned. |
| [#10600](https://github.com/manaflow-ai/cmux/pull/10600) | Lawrence Chen | Merged at `1e1800db80` after exact-head checks and clean canonical review. | Done. |
| [#10601](https://github.com/manaflow-ai/cmux/pull/10601) | Lawrence Chen | Merged after exact-head checks and clean canonical autoreview. | Done. |
| [#10602](https://github.com/manaflow-ai/cmux/pull/10602) | Lawrence Chen | Combined branch, current tip `14bf092017`; exact hosted run `32640497665` is running. | After the run, run canonical review on the exact head and merge only if all gates are clean. |
| [#10603](https://github.com/manaflow-ai/cmux/pull/10603) | Lawrence Chen | Wording lint fixed at `9e0fe12be4`; protocol and inventory scripts pass, canonical review pending. | Merge only after required checks and canonical review pass. |
| [#10522](https://github.com/manaflow-ai/cmux/pull/10522) | Lawrence Chen | Head `c7d216507f`; configurable provider-menu action and focus-target correction are present, but protocol and inventory checks fail for missing `ProviderMenu` inventory. | Fix the contract inventory, rerun exact checks, then review. |
| [#10254](https://github.com/manaflow-ai/cmux/pull/10254) | Lawrence Chen | Head `7f94fc3826`; Rust, Go, TypeScript, Java, and Zig socket fallbacks now share the bounded SHA-256 contract. Checks and exact-head review are pending. | Do not merge until all SDK conformance checks and canonical review pass. |

Do not merge stale or high-risk branches [#10131](https://github.com/manaflow-ai/cmux/pull/10131), [#10571](https://github.com/manaflow-ai/cmux/pull/10571), [#9022](https://github.com/manaflow-ai/cmux/pull/9022), [#9003](https://github.com/manaflow-ai/cmux/pull/9003), [#8999](https://github.com/manaflow-ai/cmux/pull/8999), [#9061](https://github.com/manaflow-ai/cmux/pull/9061), [#9062](https://github.com/manaflow-ai/cmux/pull/9062), or superseded stacks [#9922](https://github.com/manaflow-ai/cmux/pull/9922), [#10249](https://github.com/manaflow-ai/cmux/pull/10249), [#10254](https://github.com/manaflow-ai/cmux/pull/10254), and [#10259](https://github.com/manaflow-ai/cmux/pull/10259) without a fresh rebase and exact-head review.

## User-request ledger from local sessions

| Evidence | Request | Status |
| --- | --- | --- |
| `~/.claude/.../01959d25-4114-42de-8cfc-f13b8076a541.jsonl`, 2026-08-19 | All cmux terminals backed by cmux-tui, restart-safe daemon, sidebar layout alignment, quiet close behavior, and no idle-shell prompt. | Partially implemented through PRs [#10408](https://github.com/manaflow-ai/cmux/pull/10408), [#10413](https://github.com/manaflow-ai/cmux/pull/10413), [#10428](https://github.com/manaflow-ai/cmux/pull/10428), and [#10501](https://github.com/manaflow-ai/cmux/pull/10501). Dogfood proof for quiet close is still missing. |
| `~/.claude/.../2e8f629a-9792-478b-a63c-197c62c27114.jsonl`, 2026-08-18 | Cloud TUI with Freestyle VMs, snapshots, package preinstall, provider lifecycle, and reconnect. | Unfinished product backlog. Duplicate session `85319d51-f5d6-4bb6-a499-769643679905.jsonl` is merged into this row. |
| `~/.claude/.../f4a24a6b-dce7-4384-93e5-b2f59e641b57.jsonl`, 2026-08-10 | Decouple PTY resources from layout so one terminal can appear in multiple workspaces and future clients. | Unfinished architecture request. Needs a state-owner design before code extraction. |
| `~/.claude/.../f759472e-9be3-4e5b-9933-3a044314ccd5.jsonl`, 2026-08-06 | Bundle cmux-tui in cmux-relay, auto-pair from iPhone, and preinstall in provider images. | Merge with the cloud snapshot row; no completion evidence. |
| `~/.codex/sessions/2026/08/07/rollout-2026-08-07T19-41-07-019fdf6a-eb48-7882-94f9-40afee69fc68.jsonl` | Hosted verification must require an exact pushed SHA, Blacksmith Linux/macOS, Windows coverage, focused filters, artifacts, and no local Rust or Zig. | Workflow and guardrails are implemented in this wave. Full release and Windows confidence remain blocked by hosted checks. |
| `~/.codex/sessions/2026/08/09/rollout-2026-08-09T16-23-14-019fe8d6-6e4c-7d53-8dde-4135e325a281.jsonl` | Azure startup benchmark and Windows GNU exact-head correction. | Historical incomplete benchmark. Keep as a release and CI follow-up, not a runtime patch. |
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

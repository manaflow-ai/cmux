# cmux-tui technical-debt board

Last updated: 2026-08-23.
Audit base: `origin/main` at `17466308a52cb53e417e07085f108800efedd267`.
Integration branch: `codex/chatmux-relay-techdebt`.
Current integration tip: `d3aa21a541` (PR head `d3aa21a54164ebfc50539c72e5f85835a11e6b92`).
The branch is pushed to `https://github.com/manaflow-ai/cmux/tree/codex/chatmux-relay-techdebt`.
The combined review PR is `https://github.com/manaflow-ai/cmux/pull/10603`.

Subagent ledger: at least 64 substantive agent turns are complete in this
run. The count includes code audits, web research, session mining, fixes,
reviews, and merge gates. It excludes empty or duplicate turns. The requested
10,000-session target is not reached. I will not create empty sessions to
inflate the count. New turns must have a named deliverable.

## Current state

The exact current tip is always available with `git rev-parse HEAD` in the
worktree. The shared primary checkout was dirty before this run, so all
changes are in isolated worktrees and no unrelated files were touched.

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

## Merge and review board

| PR | Author | State on 2026-08-23 | Required action |
| --- | --- | --- | --- |
| [#9935](https://github.com/manaflow-ai/cmux/pull/9935) | Lawrence Chen | Merged as `ab4633e5612280a348f8e9a0a9626a3bfb527fe1`; exact-head autoreview clean and all checks green. | Done. |
| [#10244](https://github.com/manaflow-ai/cmux/pull/10244) | Lawrence Chen | Fixes `42f7e93c55`, `c0b8dd5107`; autoreview clean. Seven-language conformance was still running when audited. | Wait for exact-head checks, then rerun merge gate. |
| [#10270](https://github.com/manaflow-ai/cmux/pull/10270) | Lawrence Chen | Head `fe31e6c6dc`; autoreview clean. Hosted full run `32634504590` was queued. | Confirm exact checks and merge only after the contract run is green. |
| [#10413](https://github.com/manaflow-ai/cmux/pull/10413) | Lawrence Chen | Head `891544e0ab`; autoreview clean. Hosted run `32634176420` later reported a conformance failure in the inventory audit. | Fix the exact failed check before merge. |
| [#10428](https://github.com/manaflow-ai/cmux/pull/10428) | Lawrence Chen | Rebasing and cursor test landed at `076d648a2c`; hosted run `32634173482` pending. | Refresh checks and run the exact-head merge gate. |
| [#10513](https://github.com/manaflow-ai/cmux/pull/10513) | Lawrence Chen | Progress-aware fix `55caae646e`; no targeted CI and the old branch was dirty. | Rebase, add deadline behavior coverage, and run hosted verification. |
| [#10521](https://github.com/manaflow-ai/cmux/pull/10521) | Lawrence Chen | Rebased head `087bb3496a`; larger journal-scan and durable-exit findings remain. | Do not merge until the remaining review findings are resolved. |
| [#10537](https://github.com/manaflow-ai/cmux/pull/10537) | dkta0 | External author branch. Candidate fix `65d19bc694` cannot be pushed to the external fork. | Do not push outside `manaflow-ai`; use an in-org re-cut only if the semantic fix is redesigned. |
| [#10600](https://github.com/manaflow-ai/cmux/pull/10600) | Lawrence Chen | SessionPort agent projection is included in this integration branch. | Treat as redundant unless its exact branch has a separate required artifact. |
| [#10601](https://github.com/manaflow-ai/cmux/pull/10601) | Lawrence Chen | CI trigger guard is included in this integration branch. | Treat as redundant unless its exact branch has a separate required artifact. |
| [#10602](https://github.com/manaflow-ai/cmux/pull/10602) | Lawrence Chen | Combined branch, current tip `31a8df3561`; `protocol contract` and `inventory` checks failed on the current head, while guard and review checks passed. | Fix the two failed checks, rerun exact-head verification, then merge only with the authorized merge directive. |

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

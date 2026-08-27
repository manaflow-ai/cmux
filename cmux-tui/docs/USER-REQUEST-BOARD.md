# cmux-tui user request board

Current snapshot: 2026-08-27T15:12:37Z, pinned to `origin/main`
[`08b43d87d1426c11aa879b37f79db9aeffed187d`](https://github.com/manaflow-ai/cmux/commit/08b43d87d1426c11aa879b37f79db9aeffed187d),
committed 2026-08-27T07:27:51-07:00 with subject
`Bound app event enqueue and wake blocked producers`. The prior
`5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` and earlier
`99bdc375e98eb9abddd3f54289bc16ef876e8095` snapshots are retained below.
Metadata-only scan: 587 Codex session files dated after the prior snapshot and
2,505 Codex/Claude files mentioning TUI. No transcript values or secrets were
copied. [#10736](https://github.com/manaflow-ai/cmux/pull/10736) is now closed; [#10742](https://github.com/manaflow-ai/cmux/pull/10742) remains open. Cloud resource projection [#10812](https://github.com/manaflow-ai/cmux/pull/10812) is closed and superseded by merged [#10887](https://github.com/manaflow-ai/cmux/pull/10887). Packaging duplicate [#10886](https://github.com/manaflow-ai/cmux/pull/10886) remains open and is superseded pending [#10891](https://github.com/manaflow-ai/cmux/pull/10891). The audit closes superseded [#10743](https://github.com/manaflow-ai/cmux/pull/10743), [#10744](https://github.com/manaflow-ai/cmux/pull/10744), and [#10750](https://github.com/manaflow-ai/cmux/pull/10750), keeps [#10513](https://github.com/manaflow-ai/cmux/pull/10513) blocked, keeps [#10612](https://github.com/manaflow-ai/cmux/pull/10612) canonical after its docs fix, and tracks residual cloud hardening after [#10800](https://github.com/manaflow-ai/cmux/pull/10800) and [#10812](https://github.com/manaflow-ai/cmux/pull/10812) were closed as superseded by merged [#10887](https://github.com/manaflow-ai/cmux/pull/10887).

The current merged tail includes [#10973](https://github.com/manaflow-ai/cmux/pull/10973), [#10929](https://github.com/manaflow-ai/cmux/pull/10929), and [#10974](https://github.com/manaflow-ai/cmux/pull/10974); their rollbacks are recorded below. The retained session receipt supports at least 263 named substantive turns, including five named turns from the preceding audit. This refresh adds named rows but no unverified session count. The figure is a verifiable lower bound, not a total session count, and no 10,000-session claim is made.

## Current audit additions

| Request | Evidence | Acceptance | State |
| --- | --- | --- | --- |
| Define completion subscription and terminal completion ownership. | Completion-subscription design note recorded in the 2026-08-27 audit. | Subscribe before work, deliver one typed completion result, and cover cancellation, timeout, and duplicate delivery. | Open, owner unassigned |
| Benchmark startup across platforms and lifecycle states. | Session archaeology, 2026-08-09. | Event-based cold, warm, restore, incompatible, and headless measurements on macOS, Linux, and Windows. | Open, owner unassigned |
| Decouple PTY resources from layout views and allow multi-view terminal attachment. | Session archaeology, current audit; reconcile [#9903](https://github.com/manaflow-ai/cmux/pull/9903). | One terminal resource attaches to multiple workspaces or views with explicit ownership and no duplicate readers. | Open, owner unassigned |
| Audit [#9903](https://github.com/manaflow-ai/cmux/pull/9903) dependency and integration ordering. | Current audit references [#8378](https://github.com/manaflow-ai/cmux/pull/8378), [#9785](https://github.com/manaflow-ai/cmux/pull/9785), [#9647](https://github.com/manaflow-ai/cmux/pull/9647), [#9682](https://github.com/manaflow-ai/cmux/pull/9682), [#9846](https://github.com/manaflow-ai/cmux/pull/9846), [#9933](https://github.com/manaflow-ai/cmux/pull/9933), and [#9806](https://github.com/manaflow-ai/cmux/pull/9806). | Publish the dependency graph, resolve conflicts, and land bottom-up with exact-head checks. | Open, owner unassigned |
| Claude resize and alternate-screen scroll. | Claude report at `~/.claude/history.jsonl:90798` says wheel input reaches Claude Code as arrow keys. Current path is `cmux-tui/crates/cmux-tui/src/app.rs:23053-23099`; crossterm classifies scroll and Ghostty receives wheel events when tracking is enabled, while the fallback emits arrows. Resize remains unproven after closed [#10201](https://github.com/manaflow-ai/cmux/pull/10201). | Preserve trailing blank rows, define a configurable scroll policy and modifier override, and add behavior proof. | Open and unmet |
| Configure alternate-screen wheel policy and modifier override. | Scroll audit at `cmux-tui/crates/cmux-tui/src/app.rs:23053-23099`; crossterm scroll classification and Ghostty wheel forwarding are recorded in the current audit. | Preserve existing fallback until compatibility tests pass. | Open, owner unassigned |
| Preserve blank space during terminal resize. | Current audit; closed [#10201](https://github.com/manaflow-ai/cmux/pull/10201) does not prove the invariant. | Resize a terminal with trailing empty rows and prove layout and PTY dimensions remain stable. | Open, owner unassigned |
| Wave65 bounded enqueue audit. | Merged [#10974](https://github.com/manaflow-ai/cmux/pull/10974), source `255c3293`, merge `08b43d87`; hosted run [`33080531391`](https://github.com/manaflow-ai/cmux/actions/runs/33080531391) passed. | Repeat enqueue, cancellation, and producer wake-up proof on the pinned head. | Merged; proof follow-up |

Current open PR evidence is bounded in `PR-INTENT-BOARD.md`; all bases are
`main`: [#10966](https://github.com/manaflow-ai/cmux/pull/10966) `0b2d3fc6` (CLEAN,
all observed checks pass), [#10975](https://github.com/manaflow-ai/cmux/pull/10975) `9720c41a` (UNSTABLE,
seven-language conformance pending), [#10976](https://github.com/manaflow-ai/cmux/pull/10976) `95906311` (CLEAN,
visible checks pass), [#10891](https://github.com/manaflow-ai/cmux/pull/10891) `49d6310e` (UNSTABLE,
four hosted checks failing), and [#10612](https://github.com/manaflow-ai/cmux/pull/10612) `dd8cea6d` (UNSTABLE,
seven-language conformance failed). Hosted checks and heads are provisional and do
not imply merge approval.

Closed superseded PRs in this snapshot: [#10736](https://github.com/manaflow-ai/cmux/pull/10736), [#10946](https://github.com/manaflow-ai/cmux/pull/10946), [#10800](https://github.com/manaflow-ai/cmux/pull/10800), [#10812](https://github.com/manaflow-ai/cmux/pull/10812), [#10252](https://github.com/manaflow-ai/cmux/pull/10252), [#10882](https://github.com/manaflow-ai/cmux/pull/10882), [#10213](https://github.com/manaflow-ai/cmux/pull/10213), and [#10201](https://github.com/manaflow-ai/cmux/pull/10201). Closure does not prove request completion.

Merged context for the current main tail is recorded here so request status is
not confused with code integration. A merge does not close a request without
behavior evidence.

| PR | Author | Source head | Merged at (UTC) | Merge SHA | Rollback |
| --- | --- | --- | --- | --- | --- |
| [#10944](https://github.com/manaflow-ai/cmux/pull/10944) | Lawrence Chen | `976b9d427b7e91b900fc8545aea6ea6e878b99c0` | 2026-08-27 09:13:59 | `99bdc375e98eb9abddd3f54289bc16ef876e8095` | `git revert 99bdc375e98eb9abddd3f54289bc16ef876e8095` |
| [#10950](https://github.com/manaflow-ai/cmux/pull/10950) | Lawrence Chen | `e6dd260ffb346b568aa3f6dabb8a68c7f72337f5` | 2026-08-27 09:31:39 | `5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` | `git revert 5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` |
| [#10936](https://github.com/manaflow-ai/cmux/pull/10936) | Lawrence Chen | `0f6bc912500c630921a6a74d86c09d5817e56278` | 2026-08-27 09:58:58 | `d65d6e6ccacf1d7300316451ce2830f05f889e14` | `git revert d65d6e6ccacf1d7300316451ce2830f05f889e14` |
| [#10951](https://github.com/manaflow-ai/cmux/pull/10951) | Lawrence Chen | `978655f95b56351c9d554d2bdd1be9ad6ec2c551` | 2026-08-27 12:04:42 | `de3902db48d2924c227b5acb26cbe1d89fe03cc0` | `git revert de3902db48d2924c227b5acb26cbe1d89fe03cc0` |
| [#10954](https://github.com/manaflow-ai/cmux/pull/10954) | Lawrence Chen | `cc1edc896dbf321da26e26e10fb71e5fbb22e57c` | 2026-08-27 11:23:26 | `a293eba98d6f4fafa4add823327c44deef8371ef` | `git revert a293eba98d6f4fafa4add823327c44deef8371ef` |
| [#10958](https://github.com/manaflow-ai/cmux/pull/10958) | Lawrence Chen | `c6de8f16b6390038225f87474f603b0ea157506e` | 2026-08-27 10:22:03 | `9cf920bb6b7a87bae3af721a0f98c989c45b9c4b` | `git revert 9cf920bb6b7a87bae3af721a0f98c989c45b9c4b` |
| [#10962](https://github.com/manaflow-ai/cmux/pull/10962) | Lawrence Chen | `ff719b6dc4e9f05358d0c77b7f49a9db021f72e7` | 2026-08-27 10:41:51 | `ef5e7434927d89996e2cd29b429823b8a716a08e` | `git revert ef5e7434927d89996e2cd29b429823b8a716a08e` |
| [#10970](https://github.com/manaflow-ai/cmux/pull/10970) | Lawrence Chen | `561ddccdc9da7d6389d90940f73e9ea30205fa26` | 2026-08-27 12:25:26 | `aa8ca45e0b3a140678c4a6ae588e201cb421ac50` | `git revert aa8ca45e0b3a140678c4a6ae588e201cb421ac50` |
| [#10972](https://github.com/manaflow-ai/cmux/pull/10972) | Lawrence Chen | `d41cac100d2488c41cbabff7c236166186b9deb4` | 2026-08-27 12:22:32 | `2f95b8760005047ff470afe4a00fd33783e4cf93` | `git revert 2f95b8760005047ff470afe4a00fd33783e4cf93` |
| [#10959](https://github.com/manaflow-ai/cmux/pull/10959) | Lawrence Chen | `8f74239c78a81352d69e8fe5512a688b0a9d7b7e` | 2026-08-27 12:49:58 | `87f31977237cbcbbf8b7f492718685d612fbb9b0` | `git revert 87f31977237cbcbbf8b7f492718685d612fbb9b0` |
| [#10973](https://github.com/manaflow-ai/cmux/pull/10973) | Lawrence Chen | `ed9497e9f00fdbb12ff7b412468d6ef9db8635b6` | 2026-08-27 13:26:49 | `d5ad6eb41426d0ab1b612f3b3fa7321365a6cb66` | `git revert d5ad6eb41426d0ab1b612f3b3fa7321365a6cb66` |
| [#10929](https://github.com/manaflow-ai/cmux/pull/10929) | Lawrence Chen | `8ba9a3869c83e1f1f1b83e1781d484490e2aea40` | 2026-08-27 13:56:43 | `31a74487e1f824b450eaf0c2b43f0d77fe51563c` | `git revert 31a74487e1f824b450eaf0c2b43f0d77fe51563c` |
| [#10974](https://github.com/manaflow-ai/cmux/pull/10974) | Lawrence Chen | `255c329337417ede7eb06cfcc18d62db17dc56bf` | 2026-08-27 14:27:51 | `08b43d87d1426c11aa879b37f79db9aeffed187d` | `git revert 08b43d87d1426c11aa879b37f79db9aeffed187d` |

## Historical snapshot retained: main `5c2ee1244e2d796c9e4be5307788b320ac2ee4ff`

The following request rows and scan receipt preserve the prior snapshot
captured at 2026-08-27T09:54:48Z. They are historical evidence, not a fresh
current-session inventory.

Historical snapshot: 2026-08-27T09:54:48Z, pinned to `origin/main`
[`5c2ee1244e2d796c9e4be5307788b320ac2ee4ff`](https://github.com/manaflow-ai/cmux/commit/5c2ee1244e2d796c9e4be5307788b320ac2ee4ff),
committed 2026-08-27T02:31:38-07:00 with subject
`fix(tui): zeroize oversized remote frames (#10950)`. The prior
`99bdc375e98eb9abddd3f54289bc16ef876e8095` snapshot, captured at
2026-08-27T09:25:01Z, is retained below. No new session scan was run, so the
existing evidence and lower-bound ledger remain unchanged.

Merged context for the current main tail is recorded here so request status is
not confused with code integration. A merge does not close a request without
behavior evidence.

| PR | Author | Source head | Merged at (UTC) | Merge SHA | Rollback |
| --- | --- | --- | --- | --- | --- |
| [#10944](https://github.com/manaflow-ai/cmux/pull/10944) | Lawrence Chen | `976b9d427b7e91b900fc8545aea6ea6e878b99c0` | 2026-08-27 09:13:59 | `99bdc375e98eb9abddd3f54289bc16ef876e8095` | `git revert 99bdc375e98eb9abddd3f54289bc16ef876e8095` |
| [#10950](https://github.com/manaflow-ai/cmux/pull/10950) | Lawrence Chen | `e6dd260ffb346b568aa3f6dabb8a68c7f72337f5` | 2026-08-27 09:31:39 | `5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` | `git revert 5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` |

## Historical snapshot retained: main `99bdc375e98eb9abddd3f54289bc16ef876e8095`

The following request rows and scan receipt preserve the prior snapshot. They
are historical evidence, not a fresh current-session inventory.

Historical snapshot: 2026-08-27T09:25:01Z, pinned to `origin/main`
[`99bdc375e98eb9abddd3f54289bc16ef876e8095`](https://github.com/manaflow-ai/cmux/commit/99bdc375e98eb9abddd3f54289bc16ef876e8095).
Evidence comes from local Codex and Claude session records. A request stays
open until its user-visible behavior has a focused test or a recorded dogfood
result. The previous rows are preserved; this section adds only the current
audit delta.

## Historical 2026-08-27 audit additions at main `99bdc375e98eb9abddd3f54289bc16ef876e8095`

The scan receipt is 174 parsed Claude records and 42 session IDs from
`~/.claude/history.jsonl:90614-end`, plus 47 parsed Codex records and 17 IDs
from `~/.codex/history.jsonl:18787-end`. Only 26 Claude records and two Codex
records matched the selected TUI terms. Credentials, secret values, emails,
pasted payloads, encrypted inter-agent content, and unrelated records were not
copied into this board.

| Request | Evidence | Acceptance | State |
| --- | --- | --- | --- |
| Authenticate account-scoped discovery before an Iroh dial and keep transport choice explicit. | `~/.claude/history.jsonl:90614-90626,90736-90745,90751,90756-90758,90772-90774,90779` | Pair authorized accounts, reject endpoint probing and unauthenticated discovery, and prove bounded reconnect on the selected transport. | Open, security design |
| Model terminals, VNC screens, and workspaces as per-machine resources with authoritative open/closed state. | `~/.claude/history.jsonl:90630-90631,90664-90673,90734-90735,90763,90777` | Open, close, and reconnect from two clients while preserving one revisioned catalog and stable resource IDs. | Open, product and protocol design |
| Keep direct Ghostty-compatible I/O, parser, tunnel, and rendering ownership in cmux-tui. | `~/.claude/history.jsonl:90634,90639-90641,90657,90761` | Compare raw I/O and ANSI/OSC/cursor rendering against Ghostty without a frontend parser or background shim. | Open, architecture and behavior proof |
| Make sandbox access capability-based and shared by authorized threads without strict conversation binding. | `~/.claude/history.jsonl:90780-90781` | Enumerate an allowlist, reject arbitrary targets, and prove separate PTY/session ownership for two authorized threads. | Open, security design |
| Make restore failure, CPU, and latency visible without freezing a leader or client. | `~/.claude/history.jsonl:90660-90670,90697-90699` | Interrupt restore and sustained output, report one actionable outcome, and assert bounded CPU, latency, and cancellation. | Open, behavior proof |

| Request | Evidence | Acceptance | State |
| --- | --- | --- | --- |
| Remove stale surface references from `uvx cmux` attach output. | `~/.codex/history.jsonl`, session `019ffdb7-825e-7f81-87b2-2cc81b9e43c7` | Preserve the active surface ID while filtering, publish one revisioned catalog/tree snapshot, then prove attach, switch, reconnect, active removal, and empty-pane behavior use live surface IDs only. | Open, [#10743](https://github.com/manaflow-ai/cmux/pull/10743) needs follow-up |
| Put cmux-tui in the base snapshot. Do not require freestyle PTYs. | `~/.codex/history.jsonl`, session `01a0132d-85cd-7031-94e5-728512bf833a` | Build the base image, install the pinned TUI binary, launch it from the documented command, and verify upgrade and rollback. | Open, infrastructure |
| Simplify relay onboarding commands for Codex and opencode. | `~/.codex/history.jsonl`, session `019fe97c-493a-7172-967e-c24fe087b763` | One copyable command must refresh credentials for both clients, report safe errors, and never print tokens. | Open, product design |
| Define relay as a token provider for GPU and employee organizations. | Same relay onboarding session | Document trust boundaries, tenant ownership, rotation, revocation, and audit events before implementation. | Open, security design |
| Provide encrypted Codex account onboarding through relay/chatmux. | `~/.codex/history.jsonl`, session `019ffd81-0445-7111-93d5-14d1404c548e` | Prove encrypted upload, Azure Postgres persistence, Durable Object outbound verification, cache invalidation, and round-robin selection with failure recovery. | Open, security review |
| Remove replaceable sleeps and runtime clocks from PTY and relay paths. | `~/.codex/history.jsonl`, PR references 9647 and 9682 | Replace timing guesses with signals or injected clocks; add cancellation and timeout tests. | Open |
| Preserve prompt and output order during rapid remote resize. | Claude transcripts `ses_256686860ffejWnBv90WeuMlsR.jsonl` and siblings | Exercise `session.resize -> TIOCSWINSZ -> PTY output` under rapid changes and prove no prompt disappearance or stale size. | Open, behavior proof needed |
| Make attach-or-create idempotent. | UX simplification audit wave 45 | Repeating the command focuses the existing session, and only creates when no matching session exists. | Proposed |
| Add resume-last and direct in-session switching. | UX simplification audit wave 45 | One action restores the last session or switches by stable name without an intermediate menu. | Proposed |
| Use stable human-readable session names with owner and branch metadata. | UX simplification audit wave 45 | Names remain stable across reconnect and disambiguate collisions without hiding machine IDs. | Proposed |
| Add read-only observe mode and bounded reconnect. | UX simplification audit wave 45 | Observe mode cannot write PTY input; reconnect stops at a documented deadline and reports the next action. | Proposed |
| Keep CLI, palette, shortcut, and context-menu actions on one path. | Existing architecture decision in `TECH-DEBT-BOARD.md` | Each entry point invokes the same action and has one behavior test. | In progress |
| Preview sidebar targets before committing selection. | `~/.codex/sessions/2026/08/25/rollout-2026-08-25T03-02-37-01a0385f-30fe-7920-9019-35bbe25039d8.jsonl`, session `01a0385f-30fe-7920-9019-35bbe25039d8` | H/J/K/L or hover previews without committing; Esc restores prior selection; Enter and preview clicks share one focus/selection action. | Open, behavior proof needed |
| Fresh-start topology must be deterministic. | `~/.codex/sessions/2026/08/14/rollout-2026-08-14T15-18-20-01a0025a-cd4e-7100-b313-d1a1bf98a50a.jsonl`, session `01a0025a-cd4e-7100-b313-d1a1bf98a50a` | After a clean daemon start, exactly one session, workspace, screen, and terminal exist; attach/reconnect preserves identity. | Open, dogfood needed |
| Two-rail cloud TUI information architecture. | Sessions `01a0025a-cd4e-7100-b313-d1a1bf98a50a` and `01a0132d-85cd-7031-94e5-728512bf833a` | Machine rail lists local and remote hosts with New VM; workspace rail follows selected machine; reorder persists; cross-device attach works. | Open, product and security design |
| Cross-platform standalone TUI boundary. | `~/.codex/sessions/2026/08/14/rollout-2026-08-14T22-01-23-01a003cb-cc3f-7d82-940f-2eda42c167f7.jsonl`, session `01a003cb-cc3f-7d82-940f-2eda42c167f7` | Core TUI and daemon build and run without the macOS app, with attach/create/session operations on a supported non-macOS target. | Open, platform proof needed |
| Terminal color parity. | Same session `01a003cb-cc3f-7d82-940f-2eda42c167f7` | Compare ANSI palette, truecolor, default colors, OSC overrides, and reconnect against the reference without washed output. | Partial, behavior proof needed |
| Familiar server lifecycle CLI. | `~/.codex/sessions/2026/08/06/rollout-2026-08-06T16-54-11-019fd97f-ab5e-7f12-8f58-7edbf78530f6.jsonl`, session `019fd97f-ab5e-7f12-8f58-7edbf78530f6` | `server start/status/stop/attach` works, help exposes it, stop is idempotent and scoped, and old routes explain compatibility. | Partial, behavior proof needed |

## Wave-48 pattern notes

Official [Tokio channels](https://tokio.rs/tokio/tutorial/channels),
[`watch`](https://docs.rs/tokio/latest/tokio/sync/watch/),
[`select!`](https://docs.rs/tokio/latest/tokio/macro.select.html),
[Ratatui `Terminal`](https://docs.rs/ratatui/latest/ratatui/struct.Terminal.html),
and [Crossterm events](https://docs.rs/crossterm/latest/crossterm/event/enum.Event.html)
support one state-owner task for typed actions, immutable revisioned snapshots
for derived UI state, and sequenced resize claims. They do not support using a
latest-value watcher for ordered PTY bytes or protocol events. Cancellation must
close admission, stop I/O, release ownership, and join or reap children.

## Current simplification rule

Remove a prompt, duplicate state, or separate command when the same intent can
be expressed by one typed action with a stable result. Keep an extra step only
when it protects authorization, destructive-action safety, or protocol
compatibility. Record that reason beside the action.

## Evidence limits

Session records show intent, not completion. Paths above identify evidence
without copying unrelated private transcript content. The technical-debt board
and changelog record code changes, exact commits, hosted checks, and revert
commands.

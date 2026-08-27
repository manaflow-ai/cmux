# cmux-tui user-intent board

Current audit snapshot: 2026-08-27T12:20:00Z. The source baseline is
`origin/main` at [`de3902db48d2924c227b5acb26cbe1d89fe03cc0`](https://github.com/manaflow-ai/cmux/commit/de3902db48d2924c227b5acb26cbe1d89fe03cc0),
committed 2026-08-27T02:58:58-07:00 with subject
`Fix workspace RPC unknown response hangs (#10936)`. The prior
`5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` and earlier
`99bdc375e98eb9abddd3f54289bc16ef876e8095` snapshots are retained below as
historical evidence. No new session scan was run, so the existing scan receipt
and honest lower-bound ledger remain unchanged.

The current main tail includes [#10936](https://github.com/manaflow-ai/cmux/pull/10936),
[#10944](https://github.com/manaflow-ai/cmux/pull/10944), and
[#10950](https://github.com/manaflow-ai/cmux/pull/10950), [#10951](https://github.com/manaflow-ai/cmux/pull/10951), [#10954](https://github.com/manaflow-ai/cmux/pull/10954), [#10958](https://github.com/manaflow-ai/cmux/pull/10958), and [#10962](https://github.com/manaflow-ai/cmux/pull/10962). Their exact source
heads, authors, merge times, merge SHAs, and rollback commands are recorded in
[`TECH-DEBT-CHANGELOG.md`](TECH-DEBT-CHANGELOG.md).

The retained session receipt supports at least 258 named substantive turns.
This is a verifiable lower bound, not a total session count, and no
10,000-session claim is made.

| PR | Author | Source head | Merged at (UTC) | Merge SHA | Rollback |
| --- | --- | --- | --- | --- | --- |
| [#10944](https://github.com/manaflow-ai/cmux/pull/10944) | Lawrence Chen | `976b9d427b7e91b900fc8545aea6ea6e878b99c0` | 2026-08-27 09:13:59 | `99bdc375e98eb9abddd3f54289bc16ef876e8095` | `git revert 99bdc375e98eb9abddd3f54289bc16ef876e8095` |
| [#10950](https://github.com/manaflow-ai/cmux/pull/10950) | Lawrence Chen | `e6dd260ffb346b568aa3f6dabb8a68c7f72337f5` | 2026-08-27 09:31:39 | `5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` | `git revert 5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` |
| [#10936](https://github.com/manaflow-ai/cmux/pull/10936) | Lawrence Chen | `0f6bc912500c630921a6a74d86c09d5817e56278` | 2026-08-27 09:58:58 | `d65d6e6ccacf1d7300316451ce2830f05f889e14` | `git revert d65d6e6ccacf1d7300316451ce2830f05f889e14` |

## Historical snapshot retained: main `5c2ee1244e2d796c9e4be5307788b320ac2ee4ff`

The following intent delta and status labels preserve the prior snapshot
captured at 2026-08-27T09:54:48Z. They are historical evidence, not a claim
that the same rows were rescanned.

Historical audit snapshot: 2026-08-27T09:54:48Z. The source baseline was
`origin/main` at [`5c2ee1244e2d796c9e4be5307788b320ac2ee4ff`](https://github.com/manaflow-ai/cmux/commit/5c2ee1244e2d796c9e4be5307788b320ac2ee4ff),
committed 2026-08-27T02:31:38-07:00 with subject
`fix(tui): zeroize oversized remote frames (#10950)`. The previous
`99bdc375e98eb9abddd3f54289bc16ef876e8095` snapshot, captured at
2026-08-27T09:25:01Z, is retained below as historical evidence. No new session
scan was run for this metadata refresh, so the existing scan receipt and honest
lower-bound ledger remain unchanged.

The current main tail includes [#10944](https://github.com/manaflow-ai/cmux/pull/10944)
and [#10950](https://github.com/manaflow-ai/cmux/pull/10950). Their exact source
heads, authors, merge times, merge SHAs, and rollback commands are recorded in
[`TECH-DEBT-CHANGELOG.md`](TECH-DEBT-CHANGELOG.md).

| PR | Author | Source head | Merged at (UTC) | Merge SHA | Rollback |
| --- | --- | --- | --- | --- | --- |
| [#10944](https://github.com/manaflow-ai/cmux/pull/10944) | Lawrence Chen | `976b9d427b7e91b900fc8545aea6ea6e878b99c0` | 2026-08-27 09:13:59 | `99bdc375e98eb9abddd3f54289bc16ef876e8095` | `git revert 99bdc375e98eb9abddd3f54289bc16ef876e8095` |
| [#10950](https://github.com/manaflow-ai/cmux/pull/10950) | Lawrence Chen | `e6dd260ffb346b568aa3f6dabb8a68c7f72337f5` | 2026-08-27 09:31:39 | `5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` | `git revert 5c2ee1244e2d796c9e4be5307788b320ac2ee4ff` |

## Historical snapshot retained: main `99bdc375e98eb9abddd3f54289bc16ef876e8095`

The following intent delta and status labels preserve the prior snapshot. They
are historical evidence, not a claim that the same rows were rescanned.

Historical audit snapshot: 2026-08-27T09:25:01Z. The source baseline was
`origin/main` at [`99bdc375e98eb9abddd3f54289bc16ef876e8095`](https://github.com/manaflow-ai/cmux/commit/99bdc375e98eb9abddd3f54289bc16ef876e8095).
This document records explicit user requests found in local session history. A
merged code change does not close a row without behavior evidence. The prior
aggregate tip and all older status labels remain historical below. For code
changes, open PR dispositions, and rollback commands, see
[`TECH-DEBT-BOARD.md`](TECH-DEBT-BOARD.md) and
[`PR-INTENT-BOARD.md`](PR-INTENT-BOARD.md).

The historical main tail included merged PRs [#10941](https://github.com/manaflow-ai/cmux/pull/10941),
[#10940](https://github.com/manaflow-ai/cmux/pull/10940),
[#10938](https://github.com/manaflow-ai/cmux/pull/10938),
[#10935](https://github.com/manaflow-ai/cmux/pull/10935),
[#10932](https://github.com/manaflow-ai/cmux/pull/10932),
[#10937](https://github.com/manaflow-ai/cmux/pull/10937),
[#10939](https://github.com/manaflow-ai/cmux/pull/10939),
[#10934](https://github.com/manaflow-ai/cmux/pull/10934), and
[#10949](https://github.com/manaflow-ai/cmux/pull/10949). The subsequent
[#10944](https://github.com/manaflow-ai/cmux/pull/10944) merge also reached the
baseline. Their merge SHAs and
individual revert commands are recorded in the changelog. None of these merges
proves full restore, cloud lifecycle, direct-I/O ownership, or end-to-end
transport acceptance.

## Historical 2026-08-27 intent-audit delta at main `99bdc375e98eb9abddd3f54289bc16ef876e8095`

The tail scan covered 174 parsed Claude records across 42 session IDs from
`~/.claude/history.jsonl:90614-end`; 26 records across 12 IDs matched the
TUI/relay/PTY/journal/surface terms. It covered 47 parsed Codex records across
17 session IDs from `~/.codex/history.jsonl:18787-end`; two records across two
IDs matched the narrow TUI terms. These are scan receipts, not a count of
substantive requests. Credentials, secret values, emails, pasted payloads,
encrypted inter-agent content, and unrelated records were excluded.

New explicit intent clusters remain open:

- Account-scoped Iroh discovery must authenticate and pair at the relay before
  dialing. The requested policy rejects endpoint-ID probing and hidden fallback,
  and keeps the chosen Tailscale TCP or Iroh transport explicit. Evidence:
  `~/.claude/history.jsonl:90614-90626,90736-90745,90751,90756-90758,90772-90774,90779`.
- A compact machine rail should own a per-machine catalog of terminals, VNC
  screens, and remote workspaces. Agents need authoritative open/closed state,
  live mirror, and close semantics. Evidence:
  `~/.claude/history.jsonl:90630-90631,90664-90673,90734-90735,90763,90777`.
- Ghostty parity work must keep direct manual I/O and tunnel ownership in
  cmux-tui, with parser/rendering behavior compared against Ghostty and no
  unrequested startup privacy prompts. Evidence:
  `~/.claude/history.jsonl:90634,90639-90641,90657,90761`.
- Restore and performance work must classify failed restore, bound CPU and
  latency, and prevent a frozen leader or client. Evidence:
  `~/.claude/history.jsonl:90660-90670,90697-90699`.
- Every authorized thread should inspect or use every permitted sandbox under
  respectful ownership; strict conversation binding is not the requested
  policy. Evidence: `~/.claude/history.jsonl:90780-90781`.

| ID | New explicit ask and evidence | Status at historical `origin/main` `99bdc375e9` | Acceptance test |
| --- | --- | --- | --- |
| UI-26 | Account-scoped discovery and relay-side pairing before Iroh dialing; no endpoint probing or implicit transport fallback. Evidence: `~/.claude/history.jsonl:90614-90626,90736-90745`. | Open. | Pair two authorized accounts, reject unauthenticated discovery and endpoint probing, and record the selected transport and bounded reconnect result. |
| UI-27 | Per-machine catalog with terminals, VNC screens, and remote workspaces as resources or pointers; agent-visible open/closed state. Evidence: `~/.claude/history.jsonl:90630-90631,90664-90673,90734-90735`. | Open. | Add two machines, open and close resources from separate clients, and prove one revisioned catalog, live mirror, and no stale resource after reconnect. |
| UI-28 | Cloud resource topology needs New terminal, workspace, and display controls plus explicit close semantics across many remote screens. Evidence: `~/.claude/history.jsonl:90763,90777` and `~/.codex/history.jsonl:18795-18812`. | Open. | Create multiple remote workspaces and screens, close one, reopen the app, and verify stable IDs, ownership, and bounded list/attach latency. |
| UI-29 | Keep direct Ghostty-compatible I/O, tunnel, parser, and rendering ownership in cmux-tui. Evidence: `~/.claude/history.jsonl:90634,90639-90641,90657,90761`. | Open. | Compare raw I/O, ANSI/OSC rendering, cursor behavior, and reconnect against Ghostty without a frontend parser or background shim. |
| UI-30 | Sandbox access should follow authenticated capability and respectful ownership, not strict conversation binding. Evidence: `~/.claude/history.jsonl:90780-90781`. | Open. | Enumerate an allowlisted sandbox capability, attach from two authorized threads, reject arbitrary targets, and prove independent PTY/session ownership. |
| UI-31 | Restore failure, CPU, and latency must be visible and bounded without freezing a leader or client. Evidence: `~/.claude/history.jsonl:90660-90670,90697-90699`. | Open. | Interrupt restore and sustained output, report one actionable outcome, and assert bounded CPU, latency, and cancellation with no frozen client. |

## Historical 2026-08-25 intent-audit delta

The session audit found no new independent product row, but it added concrete
acceptance evidence for existing rows:

- `~/.claude/history.jsonl:90357` records fresh `uvx cmux` failures because the
  `machine-provider` executable is missing. This keeps UI-06 open.
- `~/.codex/history.jsonl:18517-18518` and the same-day Claude records report a
  missing pane surface reference. This keeps UI-13 open and is a fresh-package
  repro requirement.
- Repeated resize and peer-death reports require proof that one client's
  resize or exit cannot kill another client. This strengthens UI-03 and UI-15.
- The user explicitly requests Ghostty manual-I/O ownership, reconnect state,
  and remote-process recovery, and rejects attach-command workarounds. This
  strengthens UI-01, UI-02, UI-04, and UI-07.
- A new interaction acceptance asks for left-sidebar `hjkl` preview, `Esc`
  return, and `Enter` focus. This strengthens UI-22.
- Fresh-install checks must stop any old daemon before testing `uvx cmux`, and
  standalone cross-platform runs must not require `bun install` or provider
  PTYs. These are constraints on UI-05 and UI-06, not completion evidence.

The audit also found that detached-owner commit `01bbc358e2` is not an ancestor
of this branch, so its create-or-attach behavior is not documented as current.

## Status key

- **Open**: no acceptance evidence at the audit base.
- **Partial**: an implementation slice exists, but the requested behavior is
  not proven end to end.
- **Implemented, proof open**: the aggregate records a matching code change;
  hosted or runtime proof is still required.
- **No-go**: the request contains a constraint that the current aggregate does
  not satisfy, so completion must not be inferred.

## Deduplicated requests

| ID | Explicit ask and evidence | Status at historical tip `31fc5df2b4` | Acceptance test |
| --- | --- | --- | --- |
| UI-01 | Make every cmux terminal use a separate cmux-tui owner, keep the CLI path coherent, preserve terminals across Swift restart, and define the Swift layout projection. Evidence: `~/.claude/history.jsonl:89411,89422-89442`, 2026-08-19T03:49:41Z to 04:29:21Z UTC; follow-up `~/.claude/history.jsonl:89568`, 2026-08-20T02:57:08Z UTC. | Partial. The aggregate has relay/TUI integration, but the technical-debt board says manual-IO replacement, full restore, and layout ownership remain open. | Start a terminal, quit and reopen the Swift shell, and prove the same PTY, scrollback, cwd, and session ID remain. Exercise the CLI and a right-sidebar projection without creating a second owner. |
| UI-02 | Use journal-first recovery for both a normal cmux restart and a host reboot, with explicit recovery intent and outcome. Evidence: `~/.claude/history.jsonl:89427,89568`, 2026-08-19T04:04:18Z and 2026-08-20T02:57:08Z UTC; `~/.codex/history.jsonl:17612-17614`, 2026-08-07T07:58:12Z to 08:00:03Z UTC. | Open. The aggregate explicitly says reboot checkpoints, full agent restore, and policy-controlled resume are not implemented. | Run clean mux restart with a live host, then host-crash/reboot simulation. The first preserves the live PTY; the second classifies the session interrupted and records one journaled recovery intent and outcome. No secrets or live capabilities enter the journal. |
| UI-03 | Decouple PTYs from layout so one terminal can appear in multiple workspaces and future clients. Evidence: `~/.claude/history.jsonl:89020-89021`, 2026-08-10T04:30:32Z UTC; `~/.codex/history.jsonl:15084`, 2026-07-17T08:05:35Z UTC. | Open. The board still lists PTY ownership and one-worker-per-workspace as an architecture request. | Attach two projections to one terminal, resize and close either projection, and prove one PTY owner, ordered output, no duplicate readers, and no orphan after both detach. |
| UI-04 | Attach to a remote cmux-tui from the machine rail or SSH, and retain per-machine and per-window focus. Evidence: `~/.claude/history.jsonl:87449`, 2026-07-08T05:46:37Z UTC; the related remote-attach request is listed in `TECH-DEBT-BOARD.md` with the 2026-08-04 Codex rollout. | Open. Secure host add/edit, authenticated attach, reconnect, and focus ownership remain acceptance gaps. | Add a host without exposing credentials, attach one remote terminal, reconnect after transport loss, and verify focus state is isolated per machine and cmux window. |
| UI-05 | Build cloud VMs from snapshots containing cmux-tui and common tools, use a two-sidebar machine/workspace layout, and do not use a provider PTY. Evidence: `~/.claude/history.jsonl:87599`, 2026-07-08T21:20:50Z UTC; `89270,89295,89297-89298,89302`, 2026-08-18T04:17:14Z to 06:47:42Z UTC; `~/.codex/history.jsonl:18599-18618`, 2026-08-18T05:44:25Z to 06:37:21Z UTC. | No-go. The aggregate says Cloud TUI and Durable Objects lifecycle are not complete; a snapshot is not proof of live PTY persistence. | Create fresh Daytona, E2B, and Freestyle instances. Verify cmux-tui is present in the base image, owns the PTY, starts with the requested machine/workspace columns, and reports separate snapshot and resume timings. |
| UI-06 | Publish cmux-tui and its SDK so `npx cmux` and `uvx cmux` work, including the Linux binary. Evidence: `~/.claude/history.jsonl:87544`, 2026-07-08T19:50:47Z UTC; `89415`, 2026-08-19T03:53:08Z UTC; the package request is also recorded in `TECH-DEBT-BOARD.md`. | Partial. Packaging and artifact guards exist, but registry-install and executable smoke proof remain open. | Build the exact npm package and six version-matched wheels, install offline on Linux x64 and arm64, verify `RECORD` and executable mode, then run `cmux --help` and an attach/input/resize/reconnect smoke. |
| UI-07 | Expose a stable socket and WebSocket API for custom cmux-tui frontends and the future Swift app. Evidence: `~/.claude/history.jsonl:87839`, 2026-07-10T07:13:46Z UTC. | Partial. Socket contract and fallback hardening landed in the aggregate; cross-transport behavior and custom-client proof remain open. | Use one client for Unix, SSH, WebSocket, and Iroh paths. Subscribe before snapshot, replay ordered events, attach a surface, reconnect, and close with bounded frames and one authenticated workspace contract. |
| UI-08 | Connect a single terminal in cmux-tui through cmux-relay instead of embedding the full TUI screen. Evidence: `~/.claude/history.jsonl:88949`, 2026-08-09T01:49:06Z UTC; `89946`, 2026-08-21T06:16:29Z UTC. | Partial. Single-terminal resources and relay cleanup have code slices, but duplicate-resource and reconnect acceptance is still open. | Attach one existing terminal twice, verify one resource identity and preserved cwd/focus, reconnect after relay loss, then close without an orphan or full-TUI chrome. |
| UI-09 | Stream agent events from cmux-tui to a Durable Object so Pi can subscribe and query history, with no polling and machine identity on each event. Evidence: `~/.claude/history.jsonl:88780`, 2026-08-06T07:35:18Z UTC; `89982,89995`, 2026-08-21T08:25:41Z to 08:46:13Z UTC. | Open. The aggregate explicitly says Durable Objects integration is not implemented. | Emit monotonic event IDs with authenticated machine/session identity, reconnect from a cursor without loss or duplication, bound replay, and reject secrets or live capabilities. Verify event delivery without polling. |
| UI-10 | Make cmux-tui transport work over Iroh for the iOS app. Evidence: `~/.claude/history.jsonl:88576`, 2026-07-30T09:07:25Z UTC; related discovery questions in `~/.codex/history.jsonl:16276-16280`, 2026-07-29T03:33:42Z to 03:45:40Z UTC. | Open. Iroh result delivery has bounds, but authenticated discovery, reconnect, and end-to-end iOS attach are not proven. | Pair two authenticated devices, discover without hidden polling, attach the same session, interrupt the link, reconnect from a cursor, and verify cleanup and focus ownership. |
| UI-11 | Match Ghostty colors and cursor settings, and prove the difference with raw screenshots. Evidence: `~/.claude/history.jsonl:89543,89548-89550`, 2026-08-19T10:55:56Z to 11:01:47Z UTC; `~/.codex/history.jsonl:18402-18403`, 2026-08-15T01:48:02Z UTC. | Partial. Color protocol work exists, but the board records unresolved semantic-color parity and no end-to-end screenshot proof. | Render identical ANSI, OSC, theme-query, and cursor cases in Ghostty and cmux-tui on light and dark backgrounds. Compare screenshots or pixels, including line-cursor configuration, and cover 256-color output. |
| UI-12 | Start a fresh cmux-tui with one session, one workspace, one screen, and one terminal, then support multiple columns for machines and workspaces. Evidence: `~/.codex/history.jsonl:18409`, 2026-08-15T02:57:08Z UTC; `18599-18618`, 2026-08-18T05:44:25Z to 06:37:21Z UTC. | Open. The requested initial-state and cloud multi-column behavior has no complete acceptance evidence. | Launch from a clean state and assert the exact 1/1/1/1 topology. Add a second machine and workspace column, reorder it, reopen the app, and verify stable IDs without duplicate sessions. |
| UI-13 | Prevent stale pane or surface references and self-heal instead of emitting “missing surface” errors. Evidence: `~/.claude/history.jsonl:89203,89205`, 2026-08-17T23:12:13Z to 23:19:18Z UTC. | Open. The aggregate records stale-reference and catalog-refresh work as an open intent. | Delete or replace a surface while an old client holds its reference. The client refreshes the authoritative catalog, closes the dead viewer, and reattaches once with an actionable bounded error if the host is gone. |
| UI-14 | Make cmux-tui usable as an ecosystem with zellij/tmux-level customization and agent launch support. Evidence: `~/.claude/history.jsonl:89374`, 2026-08-19T03:17:21Z UTC; `88261-88262`, 2026-07-27T03:25:20Z to 03:32:03Z UTC. | Open. This is a product backlog, not a completed aggregate behavior. | Define versioned extension and configuration boundaries, launch Codex, Claude, OpenCode, and Pi in separate sessions, and prove that custom layouts and hooks cannot bypass auth or PTY ownership. |
| UI-15 | Keep terminal output responsive under load and avoid TUI freezes. Evidence: `~/.claude/history.jsonl:89921`, 2026-08-21T05:28:16Z UTC; the aggregate board's backpressure and queue blockers apply. | Partial. Queue and frame bounds landed, but sustained-output and disconnect behavior still require hosted proof. | Drive sustained output and resize while attaching multiple clients. Assert bounded memory, fair input, no frozen btop or dropped accepted bytes, explicit overload, and deterministic shutdown. |
| UI-16 | Eliminate persistent blank space after Claude Code TUI resize or split. Evidence: `~/.claude/transcripts/ses_2a8f488aa0ffekX6csDX94egh16.jsonl:1`, 2026-04-04T05:50:49Z UTC; follow-up `ses_2a8f48aa0ffekX6csDX94egh16.jsonl:1`, 2026-04-04T05:51:01Z UTC. | Open. The request reports repeated failures after six attempted fixes; no aggregate closure is recorded. | Reproduce window drag and Cmd-D split with Claude Code TUI, capture grid, scroll-view document height, offset, and frame on every resize, and prove no blank rows across repeated transitions. |
| UI-17 | Map a freshly spawned Codex TUI session to its exact cmux surface, including two same-cwd launches under 10 ms, then restore it after reopen. Evidence: `~/.claude/transcripts/ses_25cee6607ffebXFO2sT2wguI3w.jsonl:1`, 2026-04-19T00:09:01Z UTC. | Open. The transcript states that TUI mode does not expose the ID on stdout; no exact ownership proof is recorded. | Launch two same-cwd sessions less than 10 ms apart, record each durable session ID before surface association, kill and reopen cmux, and assert each session resumes only in its original surface. |
| UI-18 | Add a multilingual and emoji glyph-rendering fixture for the Star Wars failure. Evidence: `~/.codex/transcription-history.jsonl:3`, record `ccc037fb-aff5-4bb0-909b-0979d129ee41`. | Open. No runnable corpus or cell-width/screenshot assertion is recorded. | Render broad multilingual and emoji input in the TUI, capture cell widths and pixels, and assert stable glyph placement across resize and redraw. |
| UI-19 | Keep the cmux-relay and cmux-tui boundary narrow while deciding where machine event monitoring belongs. Evidence: `~/.claude/history.jsonl:90021`, 2026-08-21T09:50:13Z UTC; the request explicitly raises attack-surface risk. | Open. No documented threat model or ownership decision records which event, alarm, and monitoring capabilities belong in relay versus TUI. | Write the capability boundary and threat model. Prove that untrusted machine events cannot gain TUI control-plane or PTY authority, and that relay authentication and authorization remain enforced. |
| UI-20 | Support diffs.com and trees.software-style editing and tree workflows in the cmux ecosystem, while deciding what belongs in snapshots, cmux-tui, or cmux-relay. Evidence: `~/.claude/history.jsonl:90028`, 2026-08-21T10:08:43Z UTC; related cmux-tui ownership question at `90036`. | Open. This is a broad product request with no scoped feature contract, snapshot inventory, or security review. | Define a smallest feature slice and ownership matrix first. Reject arbitrary snapshot software and relay capabilities until trust boundaries, package provenance, and PTY ownership are specified and tested. |
| UI-21 | Provide secure `tui-use` tools for Pi and codemode to talk to only the sandboxes returned by the list-sandbox capability, using cmux-tui instead of tmux and reusing cmux journal hooks where appropriate. Evidence: `~/.codex/history.jsonl:18183`, 2026-08-12T07:50:27Z UTC (embedded session transcript request). | Open. No scoped tool contract, sandbox capability binding, cmux-tui transport proof, or journal-hook readiness evidence is recorded. | Enumerate sandboxes through an authenticated capability, bind each tool call to an allowlisted sandbox and cmux-tui session, reject arbitrary targets and tmux fallbacks, and prove Pi and codemode attach/input/exit behavior plus journal hook privacy and reconnect semantics. |
| UI-22 | Fix terminal resize, show an empty/action screen instead of forcing a new conversation when opening an empty space, clarify libghostty-web/Atlas renderer use and direct cmux-tui connectivity, and support left-sidebar `hjkl` preview with `Esc` return and `Enter` focus. Evidence: `~/.codex/sessions/2026/08/24/rollout-2026-08-24T15-02-29-01a035cb-e2ca-7c42-9fb0-421942de9005.jsonl`, 2026-08-24T22:02:35.904Z UTC; `~/.codex/history.jsonl:18749`, 2026-08-24 UTC. | Open. No end-to-end resize proof, empty-space state contract, renderer ownership statement, direct transport proof, or keyboard-preview proof is recorded. | Resize both directions repeatedly, open an empty space and verify only the intended actions or existing content, exercise `hjkl` preview, `Esc`, and `Enter`, then document and test the renderer and cmux-tui transport path. |
| UI-23 | Let Chatmux spawn isolated sandboxes and start Claude Code or Codex inside cmux-tui, with lifecycle hooks, stop detection, and provider authentication. Evidence: `~/.claude/history.jsonl:90216`, 2026-08-24T22:13:18Z UTC. | Open. No sandbox-to-session binding, agent launch contract, stop hook, or Bedrock/CodeRouter authentication proof is recorded. | Create two isolated sandboxes, launch Claude Code and Codex with their approved providers, observe start/stop events, and prove each TUI session maps to its sandbox without cross-target access or orphan processes. |
| UI-24 | Give products built on cmux-tui their own isolated TUI sessions, and evaluate rebuilding Firstmate on the cmux-tui primitives. Evidence: `~/.claude/history.jsonl:90220`, 2026-08-24T22:19:40Z UTC. | Open. No product-session namespace, isolation policy, or Firstmate feasibility scope is documented. | Launch two product sessions with independent IDs, layouts, PTYs, and auth capabilities. Write a bounded Firstmate feasibility slice and reject any design that shares a PTY owner or bypasses the cmux-tui control boundary. |

## Aggregate residuals that affect these asks

UI-25: workflow selector and CLI workflow controls must share one stable action path, preserve provider/workflow identity, and report unavailable selectors. This remains open pending interactive-selector and CLI behavior proof.

The linked technical-debt board is authoritative for implementation status. At
this audit base it records no local Rust compile or test evidence, incomplete
generic relay child cancellation and reaping, no Durable Objects integration,
open manual-IO and full-restore work, and open Cloud TUI acceptance. These
residuals prevent a green source diff from being treated as user-visible proof.

## Audit method and limitations

- I searched only targeted records in `~/.claude/history.jsonl`, selected
  `~/.claude/transcripts/*.jsonl`, `~/.codex/history.jsonl`, and selected dated
  Codex rollout files. Patterns were limited to `cmux-tui`, `cmux tui`, `TUI`,
  `PTY`, `journal`, `snapshot`, `relay`, `surface`, and related request terms.
- Repeated prompts were grouped by requested outcome. A row is not evidence
  that the user accepted an implementation.
- Timestamps are UTC. History files can receive new records after this audit;
  line numbers and statuses can therefore become stale.
- Encrypted inter-agent payloads, tool output, credentials, secret-file
  contents, and unrelated repositories were excluded. The board records only
  paths, timestamps, and short summaries.
- This is a narrow intent audit, not an exhaustive search of every session.
  Requests phrased without the selected terms, requests hidden in transferred
  context, and requests in capped candidate lists may be missing.

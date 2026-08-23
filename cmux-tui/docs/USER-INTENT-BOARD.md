# cmux TUI user-intent board

Last audited: 2026-08-23. This is an evidence board, not completion proof.
Searches used narrow `cmux`, `TUI`, terminal, session, resize, restore, and
rendering terms in local `~/.claude` and `~/.codex` records. A missing match is
an evidence gap, not proof that no request exists.

| Intent | Evidence | Acceptance gap | Status |
| --- | --- | --- | --- |
| Keep one canonical session and stable device/session identity across macOS and iPhone. | `~/.codex/history.jsonl`, `~/.claude/history.jsonl` | Catalog stable IDs, attach both devices to one session, and prove reorder does not duplicate viewers. | Open |
| Restore PTY ownership across cmux or renderer restart. | `~/.codex/sessions/2026/07/16/` rollout record | Prove one owner per workspace, no duplicate readers, no dropped startup input, and ordered replay after restart. | Open |
| Map a Codex or Claude session to its exact workspace, pane, surface, cwd, and session directory. | `~/.codex/history.jsonl`; `~/.claude/transcripts/ses_25cee6607ffebXFO2sT2wguI3w.jsonl` | Require hook session identity plus surface binding. Never use cwd alone when same-cwd sessions start close together. | Partial, diagnostic bindings exist |
| Remove blank geometry after TUI resize, window drag, or split changes. | `~/.claude/transcripts/ses_2a8f488aa0ffekX6csDX94egh16.jsonl`; `~/.codex/history.jsonl` | Reproduce repeated resize with scrollback, backing scale, and web content. Assert terminal and web bounds have no blank region. | Open |
| Make journal-first persistence restore projections, receipts, PTY intent, and reboot outcomes. | `~/.codex/history.jsonl`; `~/.claude/history.jsonl` | Run reducer and restart tests with idempotency receipts and explicit host-reboot policy. A snapshot is not restore proof. | Open |
| Make socket, WebSocket, SSH, and Iroh transports share one ordered, bounded, authenticated contract. | Local socket-contract records and rollout logs | Test subscribe-before-snapshot, reconnect, close, frame bounds, and ownership on every transport. | Open |
| Keep npm and PyPI packages installable offline with executable smoke checks. | `.github/workflows/cmux-tui-build-package.yml`; `tests/test_tui_npm_package_artifact.py` | Validate wheel records and modes, install offline, run help, and cover Linux x64 and arm64 entrypoints. | Partial |
| Preserve Ghostty semantic color, cursor, font, graphics, and theme-query behavior across platforms. | Local history; [PR #10612](https://github.com/manaflow-ai/cmux/pull/10612) | Capture light/dark, 256-color, OSC, Kitty, cursor, and font evidence on macOS, Linux, Windows, and remote clients. | Open |
| Add a multilingual and emoji visual verification fixture for glyph rendering. | `~/.codex/transcription-history.jsonl:3`, record `ccc037fb-aff5-4bb0-909b-0979d129ee41` | Define a broad corpus, render it in the TUI, and assert screenshot or cell-width invariants that reproduce the Star Wars emoji failure. | Open |
| Do not infer live PTY persistence from cloud snapshots. | `~/.codex/history.jsonl`; `~/.claude/history.jsonl` | Treat snapshots as packaging only. Require provider restore semantics, secret boundaries, and separate snapshot/resume timing evidence. | Explicit no-go |

## Audit limits

The board records high-confidence evidence found in the searched local records.
It does not claim that every historical session was searched or that an intent
is complete because a related code path exists. Each open row needs a behavior
fixture or hosted evidence before it can move to done.

Current code tip is available with `git -C /private/tmp/cmux-tui-aggregate-wave18 rev-parse HEAD`.

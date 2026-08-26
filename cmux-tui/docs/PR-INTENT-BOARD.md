# cmux TUI PR intent and merge board

Current snapshot: 2026-08-25. The aggregate branch is
`codex/tui-techdebt-aggregate-wave39`; its audited local tip is
`75ddb6fbe84fb37ee8bcc75d0d96c39ec782e3e9` (code), based on `origin/main`
`bd985bddcded04ed849e3484dbcb645b32a32cb6`, 811 commits ahead and 0 behind
before this documentation update. Query `git rev-parse HEAD` for the exact
metadata commit. PR [#10708](https://github.com/manaflow-ai/cmux/pull/10708)
points to the latest pushed head. Focused hosted run
[`32851303914`](https://github.com/manaflow-ai/cmux/actions/runs/32851303914)
passed on the earlier quota source tip and is stale after the latest fixes. Run
focused and full hosted checks on
the new exact head, then run final exact-head autoreview. A mergeable label is
not acceptance proof.

The prior 2026-08-24 values are historical. The aggregate includes the
cross-platform hardening, PTY generation and delivery gates, bounded readers,
stale-close identity checks, owned no-clobber SSH staging, and the merged web
determinism fix [#10718](https://github.com/manaflow-ai/cmux/pull/10718), plus
the current-main PyPI project-description metadata fix.
All URLs point to `manaflow-ai/cmux`; authors are included for merge decisions.

The dated snapshot recorded a clean in-scope autoreview with two remote-tmux
findings ignored as out of scope. The wave also includes
the Go canonical fallback correction, C++ exact-parent/CMake include fix,
bounded Rust workspace reads, watcher sink termination, and preview/shell
ownership fixes. These are documented with full commit SHAs and exact revert
commands in `TECH-DEBT-CHANGELOG.md`.

The current inventory found 105 open PRs mentioning `cmux-tui`, 64 of the
newest 300 open PRs changing a `cmux-tui/` path, and 52 sharing a path with
[#10708](https://github.com/manaflow-ai/cmux/pull/10708). Stacked or
conflicting branches remain ordered work. Green inherited checks do not replace
an exact-head review.

Session-mined unfinished requests and the simplification backlog are in
[`USER-REQUEST-BOARD.md`](USER-REQUEST-BOARD.md). They remain open until a
behavior test or dogfood result proves completion.

Final aggregate commits include the merge of current main
[`0560bae72c`](https://github.com/manaflow-ai/cmux/commit/0560bae72c17ccf2da139fdf44f1907523fc82cc),
 the PTY generation and delivery gate fixes through `77b51e368a`, the per-entry
legacy socket scan fix `ae2fa91709`, the Go write-progress fixes through
`4a50dd64b2`, the Java path test `3e85c7dd05`, and scoped remote-daemon upload
cleanup through `4fffdfc128`, followed by the PID-marker, terminal-lookup,
wire-contract, selector, and Kitty quota fixes recorded at the audited tip.
The latest tail also includes protocol-v7 PTY error gating, partial-write
cancellation retirement, bounded Git stderr drains for both status and diff,
child reaping on missing diff stdout, and stale-overflow generation gating. Do
not infer hosted or review-green status from commits alone.

## Live PR state

This table is authoritative. Older tables below preserve historical snapshots.

| PR | Author | State and head on 2026-08-25 | Decision |
| --- | --- | --- | --- |
| [#10708](https://github.com/manaflow-ai/cmux/pull/10708) | Lawrence Chen | Open, source head `75ddb6fbe8`; exact-head hosted checks and local autoreview are pending. | Run focused and full exact-head hosted checks, run local autoreview, then merge. |
| [#10736](https://github.com/manaflow-ai/cmux/pull/10736) | Lawrence Chen | Open, head `2fed9d4c6d0d548ee20751afedb2d53b4598b09c`, mergeable, all listed checks pass. Prior preview and localization findings are addressed; local autoreview needs a clean engine run. | Keep separate from #10708, run local autoreview, then merge if exact gates stay green. |
| [#10734](https://github.com/manaflow-ai/cmux/pull/10734) | Lawrence Chen | Open, head `64ae7f91f0`; exact review found a compile error in `owner_spawn_failed`, dropped startup options, and GitHub reports seven-language conformance failure. | Do not merge. Fix P0/P1 findings and rerun exact-head checks. |
| [#10743](https://github.com/manaflow-ai/cmux/pull/10743) | Lawrence Chen | Open, head `470252914f`, stale-surface follow-up. Active identity and publication-race findings remain. | Rework, rebase after [#10708](https://github.com/manaflow-ai/cmux/pull/10708), then rerun exact-head checks. |
| [#10747](https://github.com/manaflow-ai/cmux/pull/10747) | Lawrence Chen | Open, head `35ef21fa3b`, follow-up to #10743. Review found it removes valid lazy/unattached server tabs and still lacks atomic pair publication. | Do not merge. Rework against authoritative server state and add refresh-level tests. |
| [#10744](https://github.com/manaflow-ai/cmux/pull/10744) | Lawrence Chen | Open, head `45f208fb98`, watch replacement generation gate. | Review exact head and integrate only after hosted proof. |
| [#10745](https://github.com/manaflow-ai/cmux/pull/10745) | Lawrence Chen | Open, head `ee8f3d00ea`, Git process-group cleanup. | Review Unix and Windows cleanup, then integrate only after hosted proof. |
| [#10746](https://github.com/manaflow-ai/cmux/pull/10746) | Lawrence Chen | Open, head `9fa4c14977`, run_spec detached waitpid reaper. Review found PID/PGID reuse and unbounded detached-thread risks. | Do not merge. Prefer the existing owned timeout supervisor and add cancellation/reap behavior tests. |
| [#10603](https://github.com/manaflow-ai/cmux/pull/10603) | Lawrence Chen | Merged as `7ddd04f2c1879cb38868292987aae1f1dfa2b139`. | Already merged. |
| [#10604](https://github.com/manaflow-ai/cmux/pull/10604) | Lawrence Chen | Merged as `1956d7f440add80ba35e585d83697d9dae44d3e2`. | Already merged. |
| [#10602](https://github.com/manaflow-ai/cmux/pull/10602) | Lawrence Chen | Open, conflicting, unchanged head `67b7e6814f8355235e3930a6f3360a58dc0ba3c0`; superseded. | Close after [#10708](https://github.com/manaflow-ai/cmux/pull/10708) merges, after rechecking the head. |
| [#10609](https://github.com/manaflow-ai/cmux/pull/10609) | Lawrence Chen | Open, conflicting, unchanged head `bdcbb8c8049eb552a0d646cdce78d58d294b7b82`; superseded. | Close after [#10708](https://github.com/manaflow-ai/cmux/pull/10708) merges, after rechecking the head. |

## Aggregate

| PR | Author | Intent | Decision |
| --- | --- | --- | --- |
| [#10603](https://github.com/manaflow-ai/cmux/pull/10603) | Lawrence Chen | Umbrella relay, SDK, TUI lifecycle, protocol, and tech-debt integration. | This branch supersedes the overlapping slices. Merge only after exact-head hosted checks and local autoreview pass. |
| [#10602](https://github.com/manaflow-ai/cmux/pull/10602) | Lawrence Chen | Earlier relay tech-debt wave. | Superseded by #10603. It remains open; do not merge. Its Rust SDK MSRV, Rust consumer, and Rust package checks failed in run `32644656010`. |
| [#10571](https://github.com/manaflow-ai/cmux/pull/10571) | Lawrence Chen | Earlier chatmux-relay slices 2 and 3. | Closed as superseded by #10603. |

## Dependency chains that are not safe to merge blindly

| PR | Author | Intent and required order |
| --- | --- | --- |
| [#10413](https://github.com/manaflow-ai/cmux/pull/10413) | Lawrence Chen | Journal topology restore. Merge only after an exact rebase and hosted checks. |
| [#10521](https://github.com/manaflow-ai/cmux/pull/10521) | Lawrence Chen | Journal restore apply v1, dependent on #10413. Rebase after the base lands, then prove lifecycle, atomic exit state, replay performance, and metadata privacy. |
| [#10428](https://github.com/manaflow-ai/cmux/pull/10428) | Lawrence Chen | Scoped attach passthrough. It is conflicting and its diagnostic PTY tap has blocking-I/O and process-group risks. Rebase and remove or repair the tap before merge. |
| [#10513](https://github.com/manaflow-ai/cmux/pull/10513) | Lawrence Chen | Host and daemon death reporting. It depends on #10428 and needs a rebase plus focused hosted tests. |
| [#10253](https://github.com/manaflow-ai/cmux/pull/10253), [#10267](https://github.com/manaflow-ai/cmux/pull/10267), [#10268](https://github.com/manaflow-ai/cmux/pull/10268), [#10269](https://github.com/manaflow-ai/cmux/pull/10269) | Lawrence Chen | Release and wheel verification stack. Merge bottom-up only after each exact head passes. |
| [#10261](https://github.com/manaflow-ai/cmux/pull/10261), [#10262](https://github.com/manaflow-ai/cmux/pull/10262), [#10264](https://github.com/manaflow-ai/cmux/pull/10264), [#10265](https://github.com/manaflow-ai/cmux/pull/10265) | Lawrence Chen | SDK integration stack. Merge bottom-up, then rerun all language consumers. |

## Independent candidates

These PRs were mergeable or near-ready in the audit, but they are not part of
the aggregate branch. Merge them separately only after checking the current
head and overlap with #10603.

[#10681](https://github.com/manaflow-ai/cmux/pull/10681), Austin Wang, is
independent and has wrapper, quoting, and Emacs-mode fixes at `ff7685ddcd`.
The existing `env -S "nvim --clean"` detector path still needs a parser fix;
then it needs hosted Swift proof and exact-head autoreview.

- [#10607](https://github.com/manaflow-ai/cmux/pull/10607), Lawrence Chen, identity and protocol preflight.
- [#10537](https://github.com/manaflow-ai/cmux/pull/10537), dkta0, client-local host colors.
- [#10318](https://github.com/manaflow-ai/cmux/pull/10318), Lawrence Chen, pane-context New-column action.
- [#10302](https://github.com/manaflow-ai/cmux/pull/10302), Lawrence Chen, multiple machine providers.
- [#10271](https://github.com/manaflow-ai/cmux/pull/10271), Lawrence Chen, explicit skipped-TUI coverage.
- [#10249](https://github.com/manaflow-ai/cmux/pull/10249), Lawrence Chen, SDK session validation.
- [#10239](https://github.com/manaflow-ai/cmux/pull/10239), Lawrence Chen, unsafe session-name rejection.

## Defer or rebase

- [#10321](https://github.com/manaflow-ai/cmux/pull/10321), Lawrence Chen, cloud TUI. Large and conflicting, so it needs a product and security review.
- [#10270](https://github.com/manaflow-ai/cmux/pull/10270), Lawrence Chen, long socket hashing. Checks passed but the branch conflicts and overlaps #10249.
- [#10243](https://github.com/manaflow-ai/cmux/pull/10243), Lawrence Chen, release orchestration. Conflicting and outside this aggregate's safe scope.
- [#10136](https://github.com/manaflow-ai/cmux/pull/10136), Lawrence Chen, journal restore. Use the current recut [#10259](https://github.com/manaflow-ai/cmux/pull/10259) instead.
- [#10214](https://github.com/manaflow-ai/cmux/pull/10214), Lawrence Chen, Windows launch. Functionally superseded by [#10266](https://github.com/manaflow-ai/cmux/pull/10266).
- [#9515](https://github.com/manaflow-ai/cmux/pull/9515), Abdulaziz Albahar, Iroh transport. Experimental and requires an independent protocol/security review.
- [#9524](https://github.com/manaflow-ai/cmux/pull/9524), Abdulaziz Albahar, Iroh transport follow-up. Same defer rule.
- [#9593](https://github.com/manaflow-ai/cmux/pull/9593), Abdulaziz Albahar, Iroh transport stack. Same defer rule.

## Audit limits

The search used GitHub TUI title/body filters plus known dependency links. It
can miss work that never says TUI or cmux in its title or body. The board does
not close or merge unrelated experimental work. A PR with a green old check is
not current-head evidence; conflicting branches require a rebase first.

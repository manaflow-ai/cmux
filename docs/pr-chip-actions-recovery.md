# PR chip action recovery checkpoint

This is unfinished recovery of PR #38507, owned by `gcp-codex-swarm-05/pr-chip-fix-and-merge`.
The recovery lane has permission to edit and commit locally. Publishing, CI at a new head,
and merging await a successful broker ownership-transfer receipt. Issue
https://github.com/manaflow-ai/cmuxterm-hq/issues/14903 owns the remaining execution work.

The checkpoint reconciles the original branch at b10625de45ea115f8ea9c5d8a50fd95ec7e3d5cd
with NEXT at 0e6e7019af7cbc6d8d0d39c18bca2d8b327b0430. Review the feature against that
second parent, not the old original branch.

Implemented locally: bounded Rust PR state/log-tail/review reads, verification of the chat's
own branch and displayed full head, shared DOM/native actions, and same-chat prompt submission.
No watch is armed. `arm` returns `pr.watch_unavailable`; this is not delivery of the requested flow.
The normal existing immediate Merge action is preserved.

## Remaining dependency

The platform worktree at 26dce32f5a4107946a30dc4843fdb55703c74bd0 documents an inert GitHub
feed adapter in `docs/github-feed-recovery.md`: no authenticated event endpoint, Worker route,
binding, webhook secret, or activation. An event-driven watch needs that service plus an atomic
head-bound merge authority. `gh pr merge --auto --match-head-commit` checks the head when enabling
ordinary auto-merge, but does not pin a future automatic merge. Cancelling it upon a push event
leaves a race. Do not claim that this meets the requested disarm-on-push guarantee, add polling,
bypass protection, or silently change repository policy.

## Verification and next owner action

The targeted React compiler check passes for the new hook/component. Rust source has been
formatted. Tests and gallery fixtures are authored, not executed or captured. A direct TypeScript
check found an untyped empty action array (fixed) and a ReadableStream async-iterator error in
`test/support/realAcpmux.ts`; the latter has not been attributed to base by a separate check.
No final whole-web, Rust build, UI, or full-flow success is claimed. Translations inherited from
original feature keys remain needs_review and require completion before landing.

After ownership transfer, publish a WIP head, run protocol generation through `cmux-ci` on that
exact head, and retrieve generated files as artifacts. The source-prescribed generation is
`ACPMUX_PROTOCOL_BLESS=1 cargo test -p acpmux protocol_ir_is_current` in `cmux-tui`, followed by
`bun run acpmux-protocol:codegen` in `webviews`. The committed protocol JSON is currently stale;
do not hand-edit the generated artifact. Push generated results and run focused Rust
`server::pull_request_actions` tests, web `pullRequestActionView.test.ts`, the full required
path checks, and three gallery captures. Use the existing cmux live procedure to prove the
person's flow only after the missing watcher and backend are implemented.

The class of UI failure is a delayed result outliving its initiating selection, plus native menu
IDs changing meaning when conditional entries disappear. The detectors are the view tests for
A→B→A invalidation, duplicate clicks, stale native menu invocation, reactivation, and unrelated
header reconstruction. Both menu surfaces consume one operation state. The wider durable-authority
and event-activation gap remains with issue #14903; enable-time verification is not a future pin.

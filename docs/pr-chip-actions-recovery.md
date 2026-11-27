# PR chip actions and authority boundaries

The chip uses Rust to read the chat branch's pull request, failed GitHub Actions log tails,
and unresolved review threads. DOM and native headers share the action view and send adapter.
This implementation is incomplete: `arm` returns `pr.watch_unavailable`; there is no merge watch.
The existing immediate Merge action remains available.

## Bind delayed context to its initiating chat

A context read must not outlive the click's target. Both transport submission and response
handling compare the selected session and selection generation, so leaving and returning to
the same chat does not revive an old request. The native prompt ticket is reserved before the
read; the response cannot manufacture fresh person authorization. Rust verifies the branch's
canonical PR URL and full displayed head before and after reading context. Incomplete review
pages, unsupported log sources, oversized context, and changed heads return errors.

Native action IDs include the controller generation and semantic action name. Removing Fix
checks from a refreshed menu must never turn its old index into Address comments or Arm.
Reconstructing an otherwise identical header must not reset its authoritative read state.

Detectors: `pullRequestActionView.test.ts` exercises disposal, reactivation, duplicate clicks,
A→B→A selection changes, stale native actions, and header reconstruction.
`pullRequestActionPrompt.test.ts` checks click-ticket ordering, same-chat submission, late
responses, mismatched heads, and empty context. Rust `server::pull_request_actions` tests cover
head/repository checks, review completeness, bounded output, and process-group lifetime.

The hook is named `usePullRequestActions.ts` rather than sharing an extensionless basename
with `PullRequestActions.tsx`. Case-folded extensionless resolution can otherwise choose a
nonexistent mixed-case path during bundling. The shipped agent-pane bundle is the detector.

## A displayed SHA is not a future merge authorization

The requested watch must disarm on **any push**, including A→B→A. Its merge authority therefore
needs an atomic check of both the armed SHA and the ref's mutation generation at the merge.
An authoritative read of the current SHA cannot detect a change that returned to the same SHA.

Ordinary GitHub auto-merge checks an expected head when it is enabled, but can subsequently
merge another head. Cancelling it after a webhook arrives leaves a race. A direct merge with
`sha` / `expectedHeadOid` prevents merging a different current SHA, but cannot reject A→B→A
while the push events are delayed. An event journal is useful for invalidation after delivery;
it does not turn asynchronous delivery into a merge-time guard. Queue entry also requires
immediate eligibility and does not itself enable auto-merge.

Do not claim a delivered-event watcher enforces this invariant, introduce polling, bypass
protection, or silently change branch protection to manufacture it. The missing merge authority
and event activation are tracked in
[manaflow-ai/cmuxterm-hq#14903](https://github.com/manaflow-ai/cmuxterm-hq/issues/14903).

## Verification

Run the focused Rust tests through `cmux-ci` from `cmux-tui`, and run each named web test in its
own process from `webviews`. The gallery entry `agent-pane.pr-actions` has ready, reading, and
error states for both themes and narrow/normal widths. Fixtures and unit tests do not prove the
full failing-check → same-chat prompts → push → arm → merge flow in an installed app.

Protocol source changes must regenerate `cmux-tui/crates/acpmux/spec/acpmux-protocol.json`
through `ACPMUX_PROTOCOL_BLESS=1 cargo test -p acpmux protocol_ir_is_current`, followed by
`bun run acpmux-protocol:codegen` in `webviews`; do not edit generated protocol output by hand.

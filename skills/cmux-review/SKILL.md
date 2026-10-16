---
name: cmux-review
description: "Review agent-written changes before merge, after substantial edits, or when re-reviewing a repair. Use the adversarial protocol for high-risk changes or an explicitly requested deep review."
---

# cmux Review

Review to reduce developer attention. Surface concrete correctness defects;
suppress style, nits and speculative improvements unless requested.

## Default pre-merge review

1. Give a review subagent the task intent, base/head SHAs and exact diff.
   Ask for correctness first, then repository rules; keep discovery independent
   of the author's reasoning. Review policy edits against the base-branch rules.
2. Verify concrete findings, fix them when authorized, and push. Re-run the
   original discriminator after repair. A green test counts only if it exercises
   the asserted failure; prefer red-before/green-after evidence.
3. If fixes were non-trivial, obtain a fresh subagent review of the repair delta.
4. Merge when the checks that judge the change pass and the approval rule below
   is met. Report findings with evidence, verification performed and coverage gaps.

Use subagents in the current runtime, not a second model or external review
service as a gate. Keep review read-only until an authorized repair.
Do not commit review receipts, scratch reproductions or generated logs.

## Dogfood and merge

For implementation handoff or merge, read [dogfood and merge](references/dogfood-and-merge.md)
for per-change verification, first-pass completion, re-dogfood and merge receipts.
The main agent owns dogfood, approval, mergeability and every pushed fix.
App/runtime/UI merges require the user's explicit approval after dogfood **or a
direct merge directive** (`merge`, `merge it`, `auto-merge`; not `finish`, `lgtm`
or `ship it`). `main` is nightly: stack fixes, do not revert.

## Adversarial review

For security, persistence, concurrency, data-loss risks, or a requested deep
review, use the full protocol:

- Before discovery or mutation, read [source identity and receipt requirements](references/review-receipts.md#7-persist-a-review-receipt)
  and capture the original candidate and policy coordinates.
- [Discovery and triage](references/review-discovery.md): source identity,
  intent compliance, independent reviewers, severity and evidence provenance.
- [Challenge, verification and repair](references/review-verification.md):
  counterevidence, executable checks and bounded repair attempts.
- After verification, persist the [receipt and report](references/review-receipts.md)
  with separate pre/post-repair source coordinates and evidence.

These stages retain the advanced evidence protocol; ordinary reviews use the
short default pass above.

---
name: cmux-review
description: "Adversarial code review workflow for agent-written changes: build a change map, run independent discovery, suppress low-value noise, challenge credible findings, gather executable evidence, and produce a compact review receipt. Use before opening a PR, after substantial agent edits, or when re-reviewing a repair."
---

# cmux Review

Review code to reduce developer attention, not to maximize comment count.

> Spend compute freely on investigation; spend developer attention reluctantly.

The final output should be small enough that every surfaced finding deserves attention.

## Start

1. Resolve the repository root with `git rev-parse --show-toplevel`.
2. Resolve a comparison base:
   - use the base supplied by the user when present;
   - otherwise prefer `origin/main` when available;
   - fall back to the repository's default branch or the merge base implied by the current task.
3. Capture:
   - base commit;
   - current HEAD;
   - working-tree status;
   - changed files;
   - diff stat;
   - full diff.
4. If cmux is available, set the current workspace to review while the run is active:

```bash
cmux workspace status set review
```

Keep the review read-only through discovery and challenge.

## 1. Build a review brief

Before looking for defects, explain the change.

Produce:

- **Intent** — the requested behavior, using the current task when available.
- **Behavior changed** — concrete observable or ownership/lifecycle changes.
- **Risk areas** — security, persistence, concurrency, lifecycle, API compatibility, data loss, performance, UI state, etc.
- **Logical file groups** — files that implement one behavior together.
- **Suggested reading order** — start with the core behavior, then callers/consumers, then tests.
- **Existing safeguards** — relevant tests, guards, invariants, type constraints, authorization checks, or validation.
- **Missing coverage** — important paths with no obvious executable check.

Keep this brief useful even when the review finds zero defects.

## 1.5. Check intent compliance

Many agent failures come from implementing the wrong behavior cleanly. Treat task compliance as a first-class review dimension before local bug hunting.

Turn the requested task into concrete requirements and constraints. For each one, record:

- `satisfied` — implementation and/or tests give direct evidence;
- `missing` — the requested behavior is absent or contradicted;
- `uncertain` — intent or implementation evidence is ambiguous.

Also call out material **out-of-scope changes**: behavior, dependencies, permissions, APIs, persistence, or refactors that the task did not require and that increase review surface.

A requirement mismatch is a real finding even when every changed line is locally valid. Prefer observable task language over assumptions about what the author meant.

## 2. Independent discovery

Prefer independent reviewer contexts.

When the agent runtime supports subagents or fresh review sessions, run at least two discovery passes without showing them each other's findings. Give initial reviewers:

- task/intent;
- base and head source state;
- diff;
- repository instructions and review rules;
- relevant code/tests they retrieve themselves.

Avoid feeding the author's conversational justification into initial discovery. Fresh reviewers should evaluate the result rather than inherit the reasoning that produced it.

Suggested roles:

### Correctness reviewer

Look for concrete regressions, broken edge cases, lifecycle errors, races, stale state, incorrect assumptions, missing cleanup, bad error handling, and data-loss paths.

### Impact reviewer

Trace changed APIs and state across callers, consumers, persistence, tests, configuration, and platform boundaries. Look beyond changed lines.

### Repository-rules reviewer

Apply repo-local guidance such as `AGENTS.md`, `CLAUDE.md`, and `.github/review-bot-rules/`.

If only one reviewer context is available, run these as separate passes and clear previous candidate findings from the prompt between passes where practical.

## 3. Triage before challenge

Normalize candidate findings into one list and merge semantic duplicates.

Each candidate needs:

- id;
- title;
- severity;
- claim;
- affected code;
- failure mode;
- discovery source(s);
- proposed verification.

Severity guidance:

- **P0** — catastrophic/security-critical/data-loss issue requiring immediate attention.
- **P1** — likely serious production regression, authorization failure, corruption, crash, or major correctness bug.
- **P2** — real defect with bounded impact.
- **P3** — low-impact issue, maintainability concern, style, or speculative improvement.

Default publication policy:

- P0/P1: challenge and verify aggressively.
- P2: continue when the claim is concrete and evidence looks obtainable.
- P3: suppress from the main report unless the user explicitly asks for exhaustive review.

A vague concern is a hypothesis, not a finding.

### Preserve epistemic provenance

Use the repository-evidence vocabulary already exercised by Cultist:

- `PROVEN` — exact machine fact or guarantee established by direct evidence;
- `DERIVED` — deterministic conclusion from explicit facts;
- `OBSERVED` — empirical repository pattern or supplied observation;
- `INFERRED` — plausible interpretation that still depends on reasoning;
- `UNKNOWN` — the available evidence cannot establish the answer.

A semantic concern emitted by an LLM starts as `INFERRED`. Do not mutate that claim into `PROVEN` merely because a later test passes. Preserve the original inferred claim and add a separate proven/derived claim describing exactly what the executable evidence establishes.

Likewise, a successful challenge adds counterevidence or a counterclaim; it does not erase the original hypothesis from the receipt. This keeps later evaluation able to distinguish:

```text
model hypothesis
+ deterministic support
+ counterevidence
+ final disposition
```

from a single flattened confidence label.

## 4. Challenge credible findings

For every candidate that survives triage, run an adversarial pass whose job is to prove the claim wrong.

The challenger should:

- trace the relevant call/data/state path;
- search for guards and invariants;
- inspect nearby and cross-file behavior;
- inspect existing tests;
- identify assumptions in the reviewer claim;
- construct counterexamples.

Disposition:

- `refuted` — concrete code or behavior defeats the claim;
- `survives_challenge` — the claim remains plausible after adversarial inspection;
- `uncertain` — competing interpretations remain.

Record the challenger evidence even for refuted findings. Refutations are useful training/eval data.

## 5. Verify with executable evidence

For findings that survive challenge, seek the cheapest convincing evidence.

Prefer, in roughly this order:

1. existing focused test;
2. build/typecheck/lint/static checker;
3. minimal deterministic reproduction;
4. targeted temporary regression test;
5. runtime trace or UI automation;
6. broader integration test.

A verification result is one of:

- `reproduced`;
- `supported_static`;
- `not_reproduced`;
- `blocked`;
- `human_judgment`.

Never convert a failed attempt to reproduce into proof that the code is safe. Record what was attempted.

Treat generated tests as claims that also need review. A green generated test only counts as strong evidence when it actually exercises the asserted failure condition. For a regression repair, prefer proving the test/check fails on the defective state and passes after the repair, or otherwise demonstrate why the check discriminates between the two behaviors.

Avoid leaving generated tests or scratch files in the working tree unless they are genuinely valuable additions. Use temp files, disposable worktrees, or a checkpoint/fork for destructive experiments.

## 6. Repair only after evidence

When the user requested repair, or the workflow explicitly allows it:

1. create a checkpoint before mutation when cmux Vault is available;
2. repair one verified finding at a time;
3. prefer the smallest change that removes the demonstrated failure;
4. capture the resulting exact source identity;
5. rerun the exact verification that established the defect and retain its post-repair evidence;
6. review the repair delta in a fresh context;
7. cap autonomous repair loops at two attempts per finding.

Useful cmux primitives:

```bash
cmux vault checkpoint --name "pre-review-repair"
cmux vault checkpoints --agent <agent> --session <session>
cmux vault fork --agent <agent> --session <session> --checkpoint <id> --open
```

If the exact Vault identifiers are unavailable, preserve the current Git state through a normal worktree/branch workflow instead of guessing.

## 7. Persist a review receipt

Store the receipt outside source control.

Use:

```bash
git rev-parse --git-path cmux/reviews
```

Create the directory if needed. Name receipts with a stable source-state identifier, for example:

```text
<base-short>-<tree-short>-<receipt-hash>.json
```

The receipt should conform to:

`skills/cmux-review/references/review-receipt.schema.json`

The receipt records source identity, policy version, review brief, candidate counts, findings, evidence, and dispositions. It is a local artifact under Git metadata and must never be added to source control.

The top-level `source` is the exact code state against which discovery, challenge, and pre-repair verification ran. Use full Git object ids; never abbreviate `base_sha`, `head_sha`, or `tree_sha`.

`repository_id` binds Git object identities to the repository they came from. Prefer a credential-free provider identity such as `github:owner/repo` when it can be recovered safely. For a local-only or unrecognized remote, use a local opaque identifier derived from the canonical Git common-dir path rather than storing a credential-bearing remote URL.

`tree_sha` is the canonical candidate-content identity. For a clean commit, use its tree object. For a working tree, snapshot the full candidate with a temporary Git index so staged, unstaged, and non-ignored untracked files all participate without mutating the real index:

```bash
tmp_index="$(mktemp)"
rm -f "$tmp_index"
GIT_INDEX_FILE="$tmp_index" git read-tree HEAD
GIT_INDEX_FILE="$tmp_index" git add -A
tree_sha="$(GIT_INDEX_FILE="$tmp_index" git write-tree)"
rm -f "$tmp_index"
```

This may write ordinary Git blob/tree objects to the repository object database, while leaving the user's real index untouched.

Record `working_tree_dirty: true` when the candidate differs from HEAD. `patch_sha256` is optional audit evidence for the exact rendered patch bytes supplied to a reviewer; use `null` when those bytes were not retained canonically. Review applicability must use the Git source coordinate, not a renderer-dependent patch digest.

Keep review-policy identity separate from code identity. `policy_version` identifies this review protocol; top-level `ruleset_sha256` hashes the exact repository guidance/rule bundle supplied to reviewers, or is `null` when no repository rule bundle was supplied. Do not put the ruleset hash inside `source`.

A successful repair crosses into a new source state. Record that state as `repair.after_source` and record the replay of the original discriminator under `repair.verification`. Do not let post-repair evidence inherit the pre-repair source coordinate implicitly.

A later review of the same source state may reuse a receipt only when the relevant policy/ruleset identity also matches.

Any source change creates a new review coordinate. A repair does not upgrade the pre-repair receipt into a clean review of the repaired patch. After successful post-repair verification, run a fresh clean-room review against `repair.after_source` and persist a separate receipt for that source. Keep the earlier receipt as prior-head evidence for continuity, false-positive evaluation, and repair provenance.

The exact reviewed disposition is reusable only for its exact candidate coordinate. Exact reuse starts from matching `repository_id + base_sha + tree_sha`; `head_sha` is lineage metadata, and a byte-identical tree should not be re-reviewed solely because the commit object changed. Historical claims may still be useful after the source moves, but they require explicit applicability/refresh reasoning instead of silent inheritance.

## 8. Final report

Lead with the review brief, then the surviving findings.

Preferred ending:

```text
Review complete

12 hypotheses investigated
8 refuted or suppressed
3 verified/repaired
1 needs human judgment
```

For each surfaced finding, show evidence rather than an opaque confidence percentage:

```text
AUTH-03 · P1 · cross-tenant access possible

Discovery       2 independent reviewers
Challenge       survived
Call path       verified
Existing guard  none found
Reproduction    reproduced
Repair          available
```

If no credible findings survive:

```text
No verified defects found in this review.
```

Then state the strongest verification actually performed and any important coverage gaps.

## Existing cmux review inputs

Human comments saved in the diff viewer can be inspected with:

```bash
cmux comments list --json
```

Treat these as candidate findings or reviewer intent. Verify them through the same protocol instead of assuming they are correct.

Repository review rules under `.github/review-bot-rules/` are evidence-bearing policy inputs. A PR that edits review rules should be reviewed against the base-branch version of those rules.

## Hard rules

- Keep independent discovery independent.
- Deduplicate before spending verification compute.
- Prefer reproducible behavior over model consensus.
- Keep style/nits out of the primary report by default.
- Preserve failed and refuted hypotheses in the receipt.
- Re-run the original verification after a repair.
- Review the repair from a fresh context.
- Never commit review receipts, scratch repro artifacts, or generated logs.

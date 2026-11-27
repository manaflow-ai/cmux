# Adversarial review: discovery

Use for high-risk changes or an explicitly requested deep review.

## Start

Read [source identity and receipt requirements](review-receipts.md#7-persist-a-review-receipt)
before capturing the candidate below. Preserve its original tree (including dirty
and untracked content) and policy coordinates before discovery or any repair.

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

Use the repository-evidence vocabulary:

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


Continue with [challenge, verification and repair](review-verification.md).

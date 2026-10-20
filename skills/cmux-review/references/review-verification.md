# Adversarial review: verification and repair

After [discovery and triage](review-discovery.md), challenge surviving candidates.

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
cmux vault checkpoint --agent <agent> --session <session> --name "pre-review-repair"
cmux vault checkpoints --agent <agent> --session <session>
cmux vault fork --agent <agent> --session <session> --checkpoint <id> --open
```

If the exact Vault identifiers are unavailable, preserve the current Git state through a normal worktree/branch workflow instead of guessing.


Persist the evidence and report using [review receipts](review-receipts.md).

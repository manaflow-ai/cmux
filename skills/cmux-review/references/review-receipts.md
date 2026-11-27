# Adversarial review: receipts and reporting

Read the source/policy identity requirements before discovery or mutation.
Persist the receipt and report after [verification and repair](review-verification.md).

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

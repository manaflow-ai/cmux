# CMUX verification handoff, first slice

[Owner #83](https://github.com/teamleaderleo/Tact/issues/83), coordinated with
[rollout reporting #82](https://github.com/teamleaderleo/Tact/issues/82).
Python 3 standard library; no service, scheduler, GitHub token, Glaeda or Stensibly
needed to replay the committed evidence. From the CMUX repository root:

```sh
python3 tests/test_verification_receipt.py
python3 scripts/verification_receipt.py replay-ci tests/fixtures/verification_receipt/examples/ci-input.json
python3 scripts/verification_receipt.py local > /tmp/cmux-verification.json
```

The last command executes CMUX's existing supported recipe, unchanged:
`python3 tests/test_docs_deploy_auth_guard.py`. It checks the docs deployment
workflow's pinned CLI/auth policy, docs-only Vercel configuration, and daily auth
health workflow. It does **not** call Vercel or validate credentials. Use a trusted
CMUX checkout: this executes its test file. Python 3 and Git must be available.
The adapter invokes this single recipe, not arbitrary caller-supplied shell code.
Pass `--repo /path/to/cmux` to observe another checkout. Local receipt output contains no checkout path, diff contents, environment dump,
or raw failure traceback. A failure can be investigated by rerunning the original
CMUX command. The adapter exit status reports this tests scope, never merge readiness.

## Observed examples

- `tests/fixtures/verification_receipt/examples/local.json`: actual Mac arm64/Python recipe, three tests executed,
  zero skipped, exit 0, observed HEAD `2889b72b866edfef0ac260f922fd2cf9f88906a3`.
  Before/after HEADs matched, with dirty source observations; exact source throughout execution is still
  **not established**. Repository identity is caller-supplied, not remote-attested.
- `tests/fixtures/verification_receipt/examples/ci-input.json`: content-minimised REST run/job records plus a bounded
  checkout/step log excerpt from [run 35523305193, job 106111086646](https://github.com/manaflow-ai/cmux/actions/runs/35523305193/job/106111086646),
  attempt 1, September 20, 2026. `tests/fixtures/verification_receipt/examples/ci.json` is deterministically derived.
  Three docs-auth tests passed; job success and **workflow failure** are preserved.
  PR head `e0deb0e897e58de722015e714700b2ec6c220bc6` differs from checkout merge
  `25930fe8a91012ad178343016774d6850d5fd3db`. The log identifies the checkout,
  but has no post-test source observation. Neither workflow revision nor clean
  execution throughout is inferred from the run API's head SHA.

Both receipts explicitly say no artifact was produced or launched. There is no
runnable Mac app associated with these Python checks. The native artifact case
is a synthetic fixture, not a claim of real UI verification.

To import another result of this same CI recipe, use GitHub's existing records:

```sh
gh api repos/manaflow-ai/cmux/actions/runs/RUN_ID > /tmp/run.json
gh api repos/manaflow-ai/cmux/actions/jobs/JOB_ID > /tmp/job.json
gh api --allow-escape-sequences repos/manaflow-ai/cmux/actions/jobs/JOB_ID/logs > /tmp/job.log
python3 scripts/verification_receipt.py ci --run /tmp/run.json --job /tmp/job.json --log /tmp/job.log
```

Keep raw downloads private. The adapter emits only allowlisted summary lines,
identities, statuses and hashes. `log_sha256` hashes the supplied log bytes (the
committed example hashes the minimised excerpt, not the original full log).
Provider records/logs are caller-supplied evidence, not authenticated attestations;
the importer checks run/job linkage and one exact recipe step, not log authenticity.
Expired/inaccessible logs cannot be replaced by a bare green job conclusion.

## Small contract shared with #82

The existing `workflow-guard-tests` job runs `python3 tests/test_verification_receipt.py`.

`schema_version: cmux-verification/v1` describes evidence, with no acceptance,
dispatch, cache-reuse or merge authority. Null means unknown/not observed, never zero.

| Field | Meaning |
| --- | --- |
| `recipe` | Existing argv, named claim class, recipe content hash locally or observed checkout SHA in CI. |
| `source` | Repository, PR/head/base/merge/tree when known, execution semantics, before/after observations, exact materialised identity when established. |
| `checks` | Separate preparation, parsing, typechecking, tests, packaging, live phases; status plus whether execution was observed and its evidence reference. |
| `tests` | Selection expressions, selected/discovered/executed counts, unittest runner total and skips, baseline references. |
| `evidence` | Existing provider run/attempt/job/step identities, original conclusions, bounded summaries/log hashes. |
| `environment` | Platform/architecture/toolchain/configuration/build-input identity; unknown values stay null. CI runner labels do not imply an observed architecture/toolchain. |
| `artifacts` | Separate produced/launched identities; content hash, tag, bundle ID and source identity must all match for a positive match. |
| `review` | Provider availability/status, reviewed head, separately observed current head and evidence. |
| `integrations` | Reserved existing Glaeda request/run and Stensibly run/settlement references, never newly invented executions. |
| `assessment` | Derived source/review/artifact qualifications; not an authoritative acceptance verdict. |

Statuses are `passed`, `failed`, `skipped`, `unsupported`, `interrupted`.
`executed` is a separate boolean. Skipped phases were not requested by this
recipe; unsupported means this adapter/provider cannot establish that evidence.
An incomplete/cancelled/timed-out CI step stays interrupted. Provider conclusions
are retained even when a purported success lacks a usable test summary.

Unittest's `Ran N tests` counts runner invocations, including skipped tests;
`executed = N - skipped`. This recipe supplies no separate discovery/selection
inventory, so `selected` and `discovered` remain null. A selected file is not a
selected test count. An OK exit with zero executed tests is a failed tests claim.
Counts also remain unknown if a summary is missing, inconsistent or ambiguous.

Source observations reuse Glaeda's `commit`/`clean` vocabulary and add Git tree,
tracked-diff/status hashes locally. They are sequential observations, not an
atomic snapshot or source lock. Untracked content, ignored files, submodules,
reverted transient edits and external dependencies are not fully attested.
Even clean equal HEADs retain `exact_snapshot_not_established`.
This adapter cannot establish `exact_snapshot`; `exact_verification` is always
false in this slice. An exact-source adapter needs a separate validated immutable
materialisation boundary, not a flag that promotes matching HEADs.

## Fixtures and integration boundaries

`tests/fixtures/verification_receipt/fixtures/` contains explicit synthetic inputs for zero tests, source drift,
stale review head, and a different tagged artifact being launched. Inspect one:

```sh
python3 scripts/verification_receipt.py assess tests/fixtures/verification_receipt/fixtures/wrong-artifact.json
```

Tests also exercise actual temporary-Git source mutation with unchanged HEAD,
skipped counts, cancellation, unavailable evidence, preparation/parsing versus
failed typechecking, and the real CI merge-head mismatch. Synthetic `passed`
inputs remain reported inputs; derived qualifications expose their contradictions.

Inspection before implementation covered CMUX `check-native.sh`, tagged
reload/debug commands, the workflow-guard-tests CI recipe, and Glaeda
`last-run.json` (`source_before/after`, `validation`, `authority`, `state`, `run_id`).
[Glaeda #1048](https://github.com/teamleaderleo/glaeda/pull/1048) keeps latest-checkout
on-demand/coalescing semantics and developer-observation authority.
[Stensibly #1834](https://github.com/teamleaderleo/stensibly/issues/1834) keeps its
existing reservation/receipt/settlement ownership. Their execution adapters are
not implemented here; references are reserved for future evidence imports.
Native execution remains with the existing machine/build owner. #79 and #80
were informed that #83 reserved no slot and executed no native build.

Remaining #83 acceptance: real tagged build plus content-bound launch evidence;
immutable exact-source execution; real selected/discovered test inventory;
submission-to-execution branch switch; physical worker-interruption reconciliation;
provider review import/current-head refresh; authoritative merge-group integration;
and the five-change second-contributor product experiment. Fixtures demonstrate
qualifications, not completion of those physical cases. #82 retains its separate
cohort/cache/cost report. Existing CI and merge owners retain authority.

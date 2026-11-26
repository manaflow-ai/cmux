# nightly.yml `find-nightly-next-recovery`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `environment:`

The owned pick mints the routing token (GLAEDA_ROUTE_APP_KEY), so the key is read in the
routing environment, as pick-nightly-sign-runner does.

## 2

Above: `sign_owned: ${{ steps.sign-owned.outputs.owned }}`

A drained owned Mac for recover-nightly-next-notarization (glaeda's exclusive class) and
verify-recovered-nightly-next, as the JSON runs-on array scripts/ci/signing_runner.py prints, or
empty. They read it only while `attempt` is the run's own attempt.

## 3

Above: `- name: Pick a drained owned Mac for the recovery jobs`

As pick-nightly-sign-runner's sign-owned: a drained owned Mac, never Blacksmith. Any failure leaves it
empty and the recovery jobs take the signer's label.

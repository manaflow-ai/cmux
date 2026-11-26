# nightly.yml `build-nightly-deltas`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `build-nightly-deltas:`

The deltas' slow part, BinaryDelta (494 s of generate-nightly-deltas' 15-min whole-Mac hold on run
42149108998), needs no key. This job builds the delta files with no secret, on a light nightly-only
runner of the nightly mini, so the keyed job below only reuses and signs them. Optional like the deltas:
a failure leaves every delta to the keyed job, which builds what it lacks as before.

## 2

Above: `- *github-token-for-git`

Publication tooling at the workflow commit: it has the keyless mode even when the build commit predates
it, and it ships no source (only scripts/, into .publish-tooling).

## 3

Above: `- name: Select Xcode`

BinaryDelta runs with the Xcode the keyed job selects; the script reads .xcode-version and the pins from
its own checkout (cone mode keeps the root files).

## 4

Above: `path: ${{ runner.temp }}/nightly-delta/input`

Under the runner's temp directory: the checkout above cleans only .publish-tooling, and this
mini keeps its workspace between jobs.

## 5

Above: `- name: Yield the signer Mac to the nightly-next build loop`

Before the keyed job asks for the signer Mac; scripts/ci/nightly_deltas_yield.py. Two signers (ultra1, cmux15)
do not wait for the loop (a build may still wait; see the script); one-mini mode or NIGHTLY_NEXT_SIGNERS=1 waits.

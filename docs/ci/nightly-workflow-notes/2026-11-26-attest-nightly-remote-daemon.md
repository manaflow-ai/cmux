# nightly.yml `attest-nightly-remote-daemon`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `needs: [decide, build-nightly-app, build-nightly-remote-daemon, nightly-next-one]`

Provenance is advisory, as it was inside the app job. No publishing job
needs this job: a quota wait must not delay the feed.

## 2

Above: `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '' && vars.CI_NIGHTLY`

The owned nightly-only Mac pool first (the all-nightly reservation, as route-visual-gate-nightly),
then the nightly-only pool variable or label, never Blacksmith (nightlies never use Blacksmith). Its OIDC token only
writes provenance for these assets; the pool already builds the nightly app those assets ship in.

## 3

Above: `- name: Put the pinned Node on PATH`

Provenance is for `gh attestation verify`; no nightly step reads it. Signed here with no GitHub REST call
(sign.mjs: OIDC, Fulcio, Rekor) and kept as an artifact, so the shared installation budget never holds
this job: its --reserve 200 wait took 17.6 minutes in run 45562645699. The attestations API gets one try;
a refusal is a warning, and the kept bundle still verifies with `gh attestation verify FILE --bundle`.

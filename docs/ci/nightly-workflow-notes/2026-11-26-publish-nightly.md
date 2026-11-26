# nightly.yml `publish-nightly`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `environment: ${{ needs.decide.outputs.environment }}`

Production secrets: GitHub releases them only to protected refs (the
environment's deployment branch policy: main, tags v*). The nightly-next
track uses `release-next`, whose policy allows only branch nightly-next.

## 2

Above: `concurrency:`

rc/** branches share one release. Serialize its mutable aliases and feeds
by channel, even when workflow-level groups have different branch names.
nightly-next takes a group of its own run and the R2 lease below instead:
a shared group cancelled run 41436891188's pending publish for a newer one.

## 3

Above: `already_published: ${{ steps.recheck.outputs.already_published == 'true' || steps.gate.outputs.refused == 'true' }}`

Another run already published the recovered build, or the final gate
refused (see refused): this run published nothing.

## 4

Above: `refused: ${{ steps.gate.outputs.refused == 'true' || steps.recheck.outputs.superseded == 'true' || steps.upload_next_app`

The final gate refused: a recovered build failed its lineage check, or
this pipeline is not the nightly-next writer (NIGHTLY_NEXT_WRITER read
live is not mac, or is unreadable).
A superseded build (recheck or feed CAS) publishes nothing and is no failure: every job that would
republish it reads refused, and report-nightly-failure reads refusal_reason, which it leaves empty.

## 5

Above: `variant_pattern: ${{ steps.source.outputs.variant_pattern }}`

For publish-nightly-next-github: what to publish and the release body's parts.
feed_written is false when a newer build was already on the feed.

## 6

Above: `if: "always() && !cancelled() && needs.decide.result == 'success' && needs.decide.outputs.should_build == 'true' && need`

Visual coverage is advisory: route, capture, and verdict jobs still report findings, but
neither a display queue nor an enforce-mode verdict can hold publication.

## 7

Above: `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI_PUBLISHER == 'ubuntu-24.`

The release App key remains scoped to this protected environment. Publication uploads and writes feeds
at about one core (publish-nightly 64 s on 32 vCPU at 1.39 cores, .github/runners.json): with no owned
pool it takes the signing picker's Linux label, as keep-published-dsyms does, else the Linux 4 vCPU pool.

## 8

Above: `OWN_VERIFIED: ${{ needs.verify-signed-nightly.result }}`

verify-signed-nightly verified the macOS signer's app and verify-final-dmg-nightly the final DMG
(and its fresh-home launch smoke, which fails that job).

## 9

Above: `CEF_ON_DEMAND: ${{ vars.CMUX_NEXT_CEF_ON_DEMAND }}`

Chromium on demand and the source offer: the switches as they are now, except that a
republished build publishes the pack its source signed with (the app's pin names it), and
no source archive when its source made none.

## 10

Above: `- &gh-app-token-write`

Release App first, github.token as the fallback (scripts/ci/gh_app_token.sh): the App is
its own actor, so a limit that every workflow's github.token shares does not refuse it.

## 11

Above: `run: if [ -f .publish-tooling/scripts/ci/gh_budget_wait.sh ]; then bash .publish-tooling/scripts/ci/gh_budget_wait.sh --`

scripts/ci/gh_budget_wait.sh puts a gh first on PATH that waits for the shared budget's
reset (at most an hour per job, each wait logged) when a call is refused for the rate
limit, instead of failing the publish path. timeout-minutes leaves room for that hour.

## 12

Above: `- name: Download verified DMG digests`

Publish only the bytes that a job without secrets verified:
verify-final-dmg-nightly for this run's build, verify-recovered-nightly-next
for a continued one.

## 13

Above: `- &x81`

One nightly-next feed writer at a time across runs (publish-lease.sh), from the first
feed read to the read-back. TTL 15 minutes, renewed every minute by a heartbeat that
dies with the job, so a dead holder blocks the feed one TTL, inside its 30-minute
freshness bound; publish-release-notes passes the same TTL, since a waiter judges
expiry by its own. Max hold: this job's 180-minute timeout. The wait (60 minutes) is
added to the timeout.

## 14

Above: `- &x87`

cx-f76kf: decide reads NIGHTLY_NEXT_WRITER only when the run starts, and
the HQ Linux pipeline publishes nightly-next while it is linux, so the
gate reads it again live. vars.* is fixed at run start and GITHUB_TOKEN
cannot read variables: the release App reads it (Variables: read).
A failed mint leaves the token empty, and the gate refuses.

## 15

Above: `NIGHTLY_COMPONENT_GATES: ${{ vars.NIGHTLY_COMPONENT_GATES }}`

The webview and App Store shelf checks run beside the build and report after it (report-nightly-fix-forward,
report-nightly-shelf-red); the gate reads the webview job in this run, waiting only under block (Leo, 2026-11-25).

## 16

Above: `app-id: ${{ secrets.CMUX_RELEASE_APP_ID }}`

The release App (Contents + Workflows write only); its id and key
live only in the release and release-next environments.

## 17

Above: `- name: Write the build manifest for this app-input digest`

Clean-sheet CI RFD hq#26225: a write-once manifest per app-input digest beside the build. Nothing reads it yet;
it cannot fail or change the publish (the script exits 0 on any error, each call is time-bounded).

## 18

Above: `- name: Download the language packs`

Languages download on first use (CMUX-570): the packs the app's pin names, from this run
(own or republished build) or the recovered build's run, published before the appcast.

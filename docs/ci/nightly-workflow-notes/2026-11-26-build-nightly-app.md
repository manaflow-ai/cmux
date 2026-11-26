# nightly.yml `build-nightly-app`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `concurrency:`

One build slot per run: a newer push builds beside an older one and never
replaces it (a shared slot evicted waiting builds, 2026-10-19). publish-nightly's
recheck refuses a build no newer than both feeds.

## 2

Above: `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || vars.CI_NIGHTLY_MINI != '' && vars.CI_NIGHTLY_MIN`

nightly-next: pick-nightly-build-runner's dedicated builder, else an idle owned
label, else the moving Blacksmith label; never one label with no fallback. Main's
ci-cache-writer environment never follows NEXT onto that worker.

## 3

Above: `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 270 || 150 }}`

The cloud cache is scoped per branch and also drops main's own
entry (runs 35179030871 and 35182663752 restored nothing and were
cancelled at 45 minutes mid-compile), so the budget must fit a cold
build, not only a warm one.

## 4

Above: `NIGHTLY_PUBLISH_PEERS: resolve-nightly-ghostty-cli-helper build-nightly-ghostty-cli-helper build-nightly-remote-daemon`

Jobs publish-nightly needs that run beside this one; derived from the
needs graph by tests/test_nightly_stop_if_publish_doomed.py.

## 5

Above: `- name: Mint the glaeda read token for the unsigned restore`

The routing App's own budget, github.token as the fallback: every workflow's github.token shares
one hourly limit, and its 403s failed this restore in sign runs 43129190893 and 43139032769.

## 6

Above: `CMUX_ARTIFACT_RETRY_BUDGET_SECONDS: "1800"`

This restore is the only way a finished build reaches the feed: a refused artifact call waits
up to 30 minutes for the token's quota to come back instead of failing in seconds. Runs
43129190893 and 43139032769 (2026-11-12) threw away finished builds on one 403 each.

## 7

Above: `FETCH_TOKEN: ${{ steps.warm-fetch-token.outputs.token || github.token }}`

The release App's read-only token, minted for this checkout alone (nightly-next-one's "Mint the
release App token for the warm checkout"): never the shared cmux-bot token, never the job's
GITHUB_TOKEN, never anonymous. Run 45744507889 failed on GitHub's unauthenticated per-IP limit
(raw.githubusercontent.com 429 four times, then git fetch 403). Where no step mints it
(build-nightly-app, whose environment holds no release App key) the job's own token: never anonymous.

## 8

Above: `- &x11`

A persistent owned mini keeps the workspace between jobs. Checkout's
clean drops untracked output; remove the daemon handoff here too.

## 9

Above: `if: inputs.nightly_next_unsigned_run == ''`

scripts/ci/gh_budget_wait.sh puts a gh first on PATH that waits for the shared budget's
reset (at most an hour per job, each wait logged) when a call is refused for the rate
limit, instead of failing the publish path. timeout-minutes leaves room for that hour.

## 10

Above: `- name: Look up the nightly app compiled on the same inputs`

Reuse the unsigned app of an earlier nightly-next build on the same inputs
(scripts/ci/nightly_release_product_reuse.py has the key and trust rules). A hit skips the
steps that only feed xcodebuild; stamping, signing and notarization always run.
vars.CI_NIGHTLY_NEXT_PRODUCT_REUSE=0 switches the lookup and the record off.

## 11

Above: `if: (inputs.nightly_next_unsigned_run == '' && (needs.decide.outputs.track != 'nightly-next' || steps.release-derived-da`

A cold measurement run skips the restore; every gate below treats the
missing output like a cache miss, so the cold build still saves.

## 12

Above: `- name: Restore the acpmux and OptChat Chief dependency builds (cmux-next)`

The cmux-next Rust helpers below (acpmux, the OptChat Chief) compiled
every dependency from scratch on each nightly: about 150 s of the
serial build path (2026-10-09). Their target dirs keep the dependency
builds between nightly-next runs; cargo still rebuilds what changed.

## 13

Above: `- name: Install Zig for fast cmux-tui client`

A fast branch dogfood build only needs the arm64 client that is bundled
in this macOS app. Building it here avoids waiting for the full
cross-platform R2 artifact matrix. Main and release keep the immutable
manifest path below, so their machine and distribution artifacts stay
complete.

## 14

Above: `ZIG_FORCE_LOCAL_INSTALL: "1"`

Job-local install: this warm mini also runs classic jobs that need
the Zig 0.16.0 in /usr/local/bin, so never replace it from here.

## 15

Above: `CARGO_PROFILE_RELEASE_DEBUG: line-tables-only`

Line tables in a separate .dSYM next to each binary, for Sentry:
the bundled binary is stripped (strip-release-bundle.sh), so without these a
crash in cmux-tui, its host or acpmux (linked into the same binary) shows no
function, file or line. The shipped binary does not grow.

## 16

Above: `- name: Sanitize Swift package cache`

Only after the restore above. The warm builder's kept checkouts carry this workspace's own
paths; dropping their state re-fetched every package (32-222 s, runs 41444184160, 41439348303).

## 17

Above: `- name: Restore pinned Node 24.22.1 from the CI cache bucket`

The webviews app's `vp build` must run on node: on bun it emits
different bytes (build-web-bundles.sh).

## 18

Above: `- &x29`

build-nightly-inputs can start after this step (run 41570134320 queued it 7.6 min, so the
bundles built here for 106 s); feat-cmux-next's pushes publish them to R2 by source key.

## 19

Above: `- name: Download the web bundles built beside the app (cmux-next)`

A pattern, not a name: an artifact that is not there yet downloads
nothing instead of failing.

## 20

Above: `- name: Stop when the run can no longer publish (before the compile)`

The run cannot publish once a job publish-nightly needs, running beside
this one, has failed (run 40460194731 compiled and uploaded for 65 min
after its Ghostty helper failed): stop and give the Mac back. One read
of this attempt's jobs; a read error carries on. NIGHTLY_PUBLISH_PEERS
is derived from the needs graph by tests/test_nightly_stop_if_publish_doomed.py.

## 21

Above: `- name: Stop when the run can no longer publish (before the upload)`

The run cannot publish once a job publish-nightly needs, running beside
this one, has failed (run 40460194731 compiled and uploaded for 65 min
after its Ghostty helper failed): stop and give the Mac back. One read
of this attempt's jobs; a read error carries on. NIGHTLY_PUBLISH_PEERS
is derived from the needs graph by tests/test_nightly_stop_if_publish_doomed.py.

## 22

Above: `- &x48`

Every nightly-next build's dSYMs: sentry-dsyms-nightly uploads them, and keep-published-dsyms
keeps a published build's on R2 (Sentry reads 403'd, nightly 38005665577). 21 days: an
unsigned resume (7) plus notarization recovery (14). resume-unsigned-nightly.py reads
this artifact's name as the build's source commit.

## 23

Above: `- name: Pack the nightly app for reuse`

A failed or cancelled job leaves no background helper build running.
The record a later build looks up; record=true only on a fresh VM that started clean.

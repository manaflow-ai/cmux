# nightly.yml `pick-nightly-sign-runner`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `pick-nightly-sign-runner:`

The owned Macs the verify jobs (`owned`) and the signing and publication jobs (`sign_owned`,
`sign_owned_pool`) take, read right before they queue. Nightlies run only on our own minis
(Lawrence, 2026-10-30): every pick is a glaeda label, and an empty pick falls to the nightly pools.

## 2

Above: `environment:`

The owned pick mints the routing token (GLAEDA_ROUTE_APP_KEY), so the key is read in the
routing environment, as pick-nightly-build-runner does (tests/test_supplychain_security.py).

## 3

Above: `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 137 || 17 }}`

Room for every step budget in turn (the read token mint 1, the owned pick's token mints 1 + 1, the verify picker 2,
the signing picker 2 and the overtaken check 1) plus checkout, so the job is never cut off before its outputs.

## 4

Above: `sign_owned: ${{ (github.event_name == 'push' && github.run_attempt == 1 || steps.upload-marker.outcome == 'success') && `

A drained (or draining) owned Mac for the release signing jobs, as the JSON runs-on
array scripts/ci/signing_runner.py prints, or empty, under the same marker and `attempt` rules as `owned`.

## 5

Above: `- name: Mint the owned-pool routing token`

As cmux-next-dev-daily.yml: idle owned runners read live with the routing App's own
budget. Any failure leaves the token empty, and the pick below then finds no owned Mac.

## 6

Above: `UNREAD_OWNED_FALLBACK: ${{ vars.CI_PR_POOL_OWNED == '1' && (vars.CI_OWNED_POOL_RESCUE || '1') != '0' && '1' || '' }}`

As the build pick: unread runners (run 41335987427's 403 rate limit on the routing App) queue the
verify jobs on the watched owned pool, not blind on Blacksmith macOS.

## 7

Above: `DRAIN_ANYWAY: "1"`

Drain the mini that frees up soonest even past the 2 min horizon, never Blacksmith first
(signing_runner.py DRAIN_ANYWAY; Leo, 2026-10-30).

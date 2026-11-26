# nightly.yml `refresh-compilation-cache`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `if: github.event_name == 'schedule' && github.event.schedule == '17 */6 * * *' && vars.CI_PR_POOL_OWNED != '1' || github`

The schedule skips this cloud warmer while owned pools serve pull
requests (CI_PR_POOL_OWNED is 1). build-nightly-app saves the same key on
every published main push, so the remaining cloud readers (main's
full-suite dispatch, nightly's hosted fallback) restore at worst an
older entry by prefix. It runs on Blacksmith macOS, never a hosted Mac
(tests/test_ci_nightly_no_hosted_mac.py). A seed_only dispatch still warms it on demand.

## 2

Above: `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 210 || 90 }}`

This job rebuilds the cache after the store drops it, so it runs cold
by design; scheduled run 35134963192 was cancelled at 45 minutes.

## 3

Above: `- &clear-stale-git-locks-self-hos`

Steps repeated byte for byte across jobs are written once (a YAML anchor, `&name`) and
reused (`*name`): GitHub refuses a workflow file over 512,000 bytes before any job starts.
Edit the anchored copy; every alias follows it. tests/test_nightly_workflow_size.py keeps the limit.

## 4

Above: `- name: Install compilation dependencies`

The default Zig (PATH, CMUX_ZIG) is the classic ghostty tree's; the
acpmux build's libghostty-vt (ghostty-vt-sys, ghostty-next) takes
CMUX_VT_ZIG, a local install beside it, as the helper job does.

## 5

Above: `GHOSTTYKIT_R2_ACCESS_KEY_ID: ${{ secrets.CI_CACHE_R2_ACCESS_KEY_ID }}`

A GitHub download stores the pinned archive in the CI cache bucket, which
download-prebuilt-ghosttykit.sh reads when GitHub refuses (2026-11-26 403s).

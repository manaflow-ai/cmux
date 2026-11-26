# nightly.yml `pick-nightly-build-runner`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `needs: [decide]`

Beside resolve-nightly-cmux-tui-client, not after it: the pick reads only decide's outputs, and build-nightly-app
still needs both. One runner pickup off the path to the app build (nightly-30min; run 41941610932 waited 5.9 min
here after resolve). It keeps resolve's gate, so it runs only when resolve does.

## 2

Above: `UNREAD_OWNED_FALLBACK: ${{ vars.CI_PR_POOL_OWNED == '1' && (vars.CI_OWNED_POOL_RESCUE || '1') != '0' && '1' || '' }}`

Unread runners (a 403 on /actions/runners) still queue on the watched owned pool, which the
owned-pool rescue moves; only while the CI_PR_POOL_OWNED kill switch is on and the rescue itself is
(ci-owned-pool-rescue.yml runs only while CI_OWNED_POOL_RESCUE is not '0').

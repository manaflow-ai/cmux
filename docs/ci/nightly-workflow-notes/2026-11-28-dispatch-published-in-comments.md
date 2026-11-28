# `dispatch-published-in`: the comments that were inline

Moved out of `.github/workflows/nightly.yml` on 2026-11-28 to keep the file under the size guard
(tests/test_ci_workflow_file_size.py). Each note names the line it sat above.

- Above `needs: [decide, build-nightly-ghostty-cli-helper, build-nightly-app, build-sign-notarize-nightly, resolve-nightly-cmux-t`: The build jobs too: the record says whether any of them failed (push_clean).
- Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-gcp-nightly-jit-x64' }}`: The one-job JIT VM (published-in's), not the mini or a PR-shared Linux runner: the job holds App keys (wake-nightly-next-tick's).
- Above `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 190 || 70 }}`: Room for gh_budget_wait.sh's wait through a rate limit, and for glaeda's capacity wait on the mini.
- Above `- name: Read the feed back before saying published`: A run that says published reads the live feeds first: an unmoved feed fails here, red, and a refused build (nightly-next-one reds a real refusal) asks for no post-publication run (2026-11-25, run 45607031207).
- Above `- name: Upload the record`: The tail run reads the record only from here (published-build), never from its input.
- Above `env: *dispatch-pools`: A 422 "twirp error resource_exhausted" is GitHub failing to read the workflow file (45798252585): tried again like a 5xx.

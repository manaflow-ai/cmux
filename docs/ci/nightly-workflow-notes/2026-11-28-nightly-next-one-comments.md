# `nightly-next-one`: the comments that were inline

Moved out of `.github/workflows/nightly.yml` on 2026-11-28 to keep the file under the size guard
(tests/test_ci_workflow_file_size.py). Each note names the line it sat above.

- Above `nightly-next-one:`: nightly-next on one Mac, end to end. Why: docs/ci/nightly-workflow-notes.md#note-18
- Above `concurrency:`: The push slot, one per signer Mac, never cancelled. Why: docs/ci/nightly-workflow-notes.md#note-19, #note-33
- Above `timeout-minutes: 300`: Build, sign, notarize (40m wait), then the publish lease's 60m wait.
- Above `actions: write`: The tick ask at notarization. Why: docs/ci/nightly-workflow-notes.md#note-26
- Above `compile_red: ${{ steps.chief-build.outcome == 'failure' || steps.mobile-host-build.outcome == 'failure' || steps.app-rel`: A red compile on this tree: the retry rebuilds the same tree (45556730650: 1 h of the slot); the next push restarts the loop.
- Above `deltas: ${{ steps.deltas-inputs.outcome == 'success' }}`: nightly-next-deltas' inputs: the deltas follow the feed in their own job.
- Above `left_pending: ${{ steps.one-leave.outputs.pending }}`: Left before nightly-next moved: wake-nightly-next-tick retries this commit unless it moves.
- Above `CMUX_NIGHTLY_KEEP_STATE: "1"`: Warm in one tree per Mac under $HOME, by flag (nightly_build_state.py); no shared compiler store or host root.
- Above `ZIG_DOWNLOAD_BUDGET_SECONDS: "1800"`: A cold 54 MB Zig transfer on the signer can take over 8 minutes (run 45512239356).
- Above `NIGHTLY_COMPONENT_GATES: ${{ vars.NIGHTLY_COMPONENT_GATES }}`: Unset (default): the webview checks and the iPhone host fall back and publish with a stale-part note.
- Above `- name: Wait through GitHub API rate limits in this job's gh calls`: Install the budget wrapper from this workflow's trusted tooling checkout before any gh call.
- Above `run: bash .publish-tooling/scripts/ci/gh_budget_wait.sh --install`: This job has checked out the workflow's trusted publication tooling above. The split build job keeps its source-tree fallback because it has no .publish-tooling checkout.
- Above `- name: Mint the release App token for the warm checkout`: Mint only after the claim (signing rule 7a). Only the checkout receives the read-only token. Its App quota avoids the shared unauthenticated limit hit in run 45744507889.
- Above `- name: Leave the push slot to a newer nightly-next push`: Before the leave step's gh calls (tests/test_publish_app_token_workflow.py).
- Above `GH_DOWNLOAD_TOKEN: ${{ github.token }}`: The Zig package mirror is a github.com release; the Macs get 403 on anonymous downloads.
- Above `continue-on-error: ${{ vars.NIGHTLY_COMPONENT_GATES != 'block' }}`: A red check is a stale part, not a hold (the gate notes it), unless vars.NIGHTLY_COMPONENT_GATES is 'block'.
- Above `- name: Hand a type error with no machine fix to fixit-handoff`: A type error fixit-compile could not fix wrote its record: the fixit-handoff job dispatches its revert.
- Above `- name: Fetch the published Chromium framework`: After the check above: "Codesign apps" joins it (sign-fetch-published-chromium.sh, sign-cef.sh reuse).
- Above `CMUX_STAPLE_APP_IN_DMG: "false"`: As the notarize step: the app has no ticket of its own (verify-dmg-artifact.sh --app-ticket-online).
- Above `ASSETS_OUTCOME: skipped`: publish-nightly-next-github's steps, after the feed.
- Above `- name: Hand the Mac to a newer nightly-next push after the feed`: Leo: "Just keep the train going like 24/7". Why: docs/ci/nightly-workflow-notes.md#note-53
- Above `- name: Bundle size budget`: A report that gates nothing (85-101 s): after the feed, not before it (ask-c0123d25e8).
- Above `- name: Upload nightly variant artifacts`: Not the rolling-name DMG, a second copy of the build's DMG. Why: docs/ci/nightly-workflow-notes.md#note-32
- Above `- name: Hand the deltas job its inputs`: The deltas follow the feed in their own job (nightly-next-deltas), so published-build and the GitHub release no longer wait the ~5 min they took here (run 45575194160: 283 s build, 17 s upload; ask-c0123d25e8). This step only hands it the names and the floor it reads from the signed app; no secret, no bundle code. A newer nightly-next push waiting skips it, so the deltas job skips too and the signing Mac moves on.
- Above `- name: Fail when this build's publication was refused`: A refused publication is red, not green: run 45607031207 built and signed, its shelf check died (ENOSPC), the gate refused, and the job showed green with nothing published, so a 3.5 h stall read as healthy (2026-11-25). A stand-down (writer linux or none, a known-bad commit), a superseded build and a left slot publish nothing on purpose and stay green.
- Above `- name: Wipe this job's credentials and temp files`: The workspace stays (the next build fetches into it); this job's tokens and temp files do not.

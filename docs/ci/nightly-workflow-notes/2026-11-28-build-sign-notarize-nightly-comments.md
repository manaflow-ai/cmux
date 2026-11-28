# nightly.yml build-sign-notarize-nightly: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `environment: ${{ needs.decide.outputs.environment }}`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly.md

Above `needs: [decide, build-nightly-app, resolve-nightly-cmux-tui-client, prepare-nightly-variant, pick-ni`:

    # The only nightly signer: the Linux release-signer pool is retired (nightlies run on our own minis).

Above `notary_pending: ${{ steps.notarize-nightly.outputs.submission_pending }}`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly-4.md

Above `stapled_app_fallback_id: ${{ steps.notarize-nightly.outputs.stapled_app_fallback == 'true' && steps.`:

    # The 6 h stapled-app fallback (notarize-nightly-dmg.sh) shipped the first DMG.

Above `permissions:`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly-3.md

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || vars.CI_NIGHTLY_MINI != '' &&`:

    # Why: docs/ci/nightly-workflow-notes.md#note-42

Above `timeout-minutes: ${{ needs.decide.outputs.notary_test == 'true' && 235 || 160 }}`:

    # Why: docs/ci/nightly-workflow-notes.md#note-4

Above `strategy:`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly-5.md

Above `CHANNEL_APP_PATH: build-universal/Build/Products/Release/${{ needs.decide.outputs.app_name }}.app`:

    # Signed app path for every step after "Prepare channel identity".

Above `- *hold-the-whole-mac`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly-2.md

Above `submodules: false`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly-checkout-build-ref.md

Above `- name: Checkout trusted signing controls`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly-1.md

Above `- name: Claim the whole Mac for signing`:

    # Before any secret: the same check again, and a signing keychain a killed job left is removed.

Above `- &x55`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly-2.md

Above `- name: Download prepared app (parallel)`:

    # Why: docs/ci/nightly-workflow-notes.md#note-8

Above `- name: Restore pinned Node 22.23.4 from the CI cache bucket`:

    # Why: docs/ci/nightly-workflow-notes.md#note-7

Above `if: needs.decide.outputs.notary_probe != 'true' && !env.LEFT_SLOT`:

    # The production probe carries no Sparkle key, so it can never update.

Above `NIGHTLY_SPARKLE_KEY: ${{ vars.NIGHTLY_SPARKLE_KEY }}`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly-restore-pinned-node-22-23-4-from-7.md

Above `SHARED_SPARKLE_PRIVATE_KEY: ${{ needs.decide.outputs.track != 'nightly-next' && secrets.SPARKLE_PRIV`:

    # The nightly-next track gets only its own key; the others never see it.

Above `- &x60`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly-restore-pinned-node-22-23-4-from-4.md

Above `- &x61`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly-restore-pinned-node-22-23-4-from-3.md

Above `- &x62`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly-restore-pinned-node-22-23-4-from-6.md

Above `CMUX_NEXT_CEF_ON_DEMAND: ${{ needs.decide.outputs.track == 'nightly-next' && vars.CMUX_NEXT_CEF_ON_D`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly-restore-pinned-node-22-23-4-from-5.md

Above `CMUX_NEXT_LANGUAGE_PACKS: ${{ needs.decide.outputs.track == 'nightly-next' && (vars.CMUX_NEXT_LANGUA`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly-3.md

Above `CMUX_NEXT_TOOL_PACKS: ${{ needs.decide.outputs.track == 'nightly-next' && (vars.CMUX_NEXT_LANGUAGE_P`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly-4.md

Above `CMUX_CEF_REUSE_FRAMEWORK: ${{ runner.temp }}/cef-reuse/Chromium Embedded Framework.framework`:

    # sign-cef.sh reuses it when it is the same code and signer, so deltas leave Chromium out.

Above `- name: Upload the Chromium runtime pack`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly-upload-the-chromium-runtime-pack.md

Above `- name: Upload the language packs`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly-upload-the-language-packs.md

Above `- &x67`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly-stop-before-notarization-nightly.md

Above `timeout-minutes: ${{ needs.decide.outputs.notary_test == 'true' && 205 || 130 }}`:

    # Why: docs/ci/nightly-workflow-notes.md#note-1

Above `APPLE_CERTIFICATE_BASE64: ${{ secrets.APPLE_CERTIFICATE_BASE64 }}`:

    # The DMG around the stapled app is signed after Apple's wait.

Above `CMUX_STAPLE_APP_IN_DMG: ${{ needs.decide.outputs.notary_test == 'true' && 'false' || 'true' }}`:

    # A notary test publishes nothing and keeps its one DMG submission.

Above `CMUX_NOTARY_PENDING_ON_TIMEOUT: ${{ needs.decide.outputs.track == 'nightly-next' && needs.decide.out`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly-notarize-app-ticket-through-fina.md

Above `CMUX_DEFER_LAUNCH_SMOKES: "true"`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly-notarize-app-ticket-through-fina-2.md

Above `SIGN_CHANNEL: ${{ needs.decide.outputs.sign_channel }}`:

    # The state file records the signing channel (cmux NEXT signs as `next`).

Above `- name: Download the cmux-next source archive for recovery`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly-download-the-cmux-next-source-ar.md

Above `SHARED_SPARKLE_PRIVATE_KEY: ${{ needs.decide.outputs.track != 'nightly-next' && secrets.SPARKLE_PRIV`:

    # The nightly-next track gets only its own key; the others never see it.

Above `SPARKLE_CHANNEL: ${{ needs.decide.outputs.track == 'nightly-next' && (vars.NIGHTLY_NEXT_DEV_RING == `:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-sign-notarize-nightly-5.md

Above `NIGHTLY_NEXT_DELTAS_AFTER_FEED: ${{ needs.decide.outputs.one_job == 'true' && needs.decide.outputs.t`:

    # nightly-next-one writes the item full-only and builds the deltas after the feed. Why: docs/ci/nightly-workflow-notes.md#note-31

Above `- name: Write notary test receipt`:

    # cx-f58x: text receipts only (notary-test-receipt.sh).

Above `run: s=scripts/ci/nightly-steps/notary-test-receipt.sh; [ -f "$s" ] || s=".nightly-signing-control/$`:

    # An unsigned resume of an older tree may predate the script: the workflow commit's copy.

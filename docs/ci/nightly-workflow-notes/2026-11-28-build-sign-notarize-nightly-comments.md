# `build-sign-notarize-nightly`: the comments that were inline

Moved out of `.github/workflows/nightly.yml` on 2026-11-28 to keep the file under the size guard
(tests/test_ci_workflow_file_size.py). Each note names the line it sat above.

- Above `needs: [decide, build-nightly-app, resolve-nightly-cmux-tui-client, prepare-nightly-variant, pick-nightly-sign-runner]`: The only nightly signer: the Linux release-signer pool is retired (nightlies run on our own minis).
- Above `stapled_app_fallback_id: ${{ steps.notarize-nightly.outputs.stapled_app_fallback == 'true' && steps.notarize-nightly.out`: The 6 h stapled-app fallback (notarize-nightly-dmg.sh) shipped the first DMG.
- Above `CHANNEL_APP_PATH: build-universal/Build/Products/Release/${{ needs.decide.outputs.app_name }}.app`: Signed app path for every step after "Prepare channel identity".
- Above `- name: Claim the whole Mac for signing`: Before any secret: the same check again, and a signing keychain a killed job left is removed.
- Above `if: needs.decide.outputs.notary_probe != 'true' && !env.LEFT_SLOT`: The production probe carries no Sparkle key, so it can never update.
- Above `SHARED_SPARKLE_PRIVATE_KEY: ${{ needs.decide.outputs.track != 'nightly-next' && secrets.SPARKLE_PRIVATE_KEY || '' }}`: The nightly-next track gets only its own key; the others never see it.
- Above `CMUX_CEF_REUSE_FRAMEWORK: ${{ runner.temp }}/cef-reuse/Chromium Embedded Framework.framework`: sign-cef.sh reuses it when it is the same code and signer, so deltas leave Chromium out.
- Above `APPLE_CERTIFICATE_BASE64: ${{ secrets.APPLE_CERTIFICATE_BASE64 }}`: The DMG around the stapled app is signed after Apple's wait.
- Above `CMUX_STAPLE_APP_IN_DMG: ${{ needs.decide.outputs.notary_test == 'true' && 'false' || 'true' }}`: A notary test publishes nothing and keeps its one DMG submission.
- Above `SIGN_CHANNEL: ${{ needs.decide.outputs.sign_channel }}`: The state file records the signing channel (cmux NEXT signs as `next`).
- Above `SHARED_SPARKLE_PRIVATE_KEY: ${{ needs.decide.outputs.track != 'nightly-next' && secrets.SPARKLE_PRIVATE_KEY || '' }}`: The nightly-next track gets only its own key; the others never see it.
- Above `NIGHTLY_NEXT_DELTAS_AFTER_FEED: ${{ needs.decide.outputs.one_job == 'true' && needs.decide.outputs.track == 'nightly-nex`: nightly-next-one writes the item full-only and builds the deltas after the feed. Why: docs/ci/nightly-workflow-notes.md#note-31
- Above `- name: Write notary test receipt`: cx-f58x: text receipts only (notary-test-receipt.sh).
- Above `run: s=scripts/ci/nightly-steps/notary-test-receipt.sh; [ -f "$s" ] || s=".nightly-signing-control/$s"; bash "$s"`: An unsigned resume of an older tree may predate the script: the workflow commit's copy.

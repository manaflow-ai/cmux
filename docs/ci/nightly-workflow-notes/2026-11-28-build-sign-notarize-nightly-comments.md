# nightly.yml build-sign-notarize-nightly: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `needs: [decide, build-nightly-app, resolve-nightly-cmux-tui-client, prepare-nightly-variant, pick-ni`:

    # The only nightly signer: the Linux release-signer pool is retired (nightlies run on our own minis).

Above `stapled_app_fallback_id: ${{ steps.notarize-nightly.outputs.stapled_app_fallback == 'true' && steps.`:

    # The 6 h stapled-app fallback (notarize-nightly-dmg.sh) shipped the first DMG.

Above `CHANNEL_APP_PATH: build-universal/Build/Products/Release/${{ needs.decide.outputs.app_name }}.app`:

    # Signed app path for every step after "Prepare channel identity".

Above `- name: Claim the whole Mac for signing`:

    # Before any secret: the same check again, and a signing keychain a killed job left is removed.

Above `if: needs.decide.outputs.notary_probe != 'true' && !env.LEFT_SLOT`:

    # The production probe carries no Sparkle key, so it can never update.

Above `SHARED_SPARKLE_PRIVATE_KEY: ${{ needs.decide.outputs.track != 'nightly-next' && secrets.SPARKLE_PRIV`:

    # The nightly-next track gets only its own key; the others never see it.

Above `CMUX_CEF_REUSE_FRAMEWORK: ${{ runner.temp }}/cef-reuse/Chromium Embedded Framework.framework`:

    # sign-cef.sh reuses it when it is the same code and signer, so deltas leave Chromium out.

Above `APPLE_CERTIFICATE_BASE64: ${{ secrets.APPLE_CERTIFICATE_BASE64 }}`:

    # The DMG around the stapled app is signed after Apple's wait.

Above `CMUX_STAPLE_APP_IN_DMG: ${{ needs.decide.outputs.notary_test == 'true' && 'false' || 'true' }}`:

    # A notary test publishes nothing and keeps its one DMG submission.

Above `SIGN_CHANNEL: ${{ needs.decide.outputs.sign_channel }}`:

    # The state file records the signing channel (cmux NEXT signs as `next`).

Above `SHARED_SPARKLE_PRIVATE_KEY: ${{ needs.decide.outputs.track != 'nightly-next' && secrets.SPARKLE_PRIV`:

    # The nightly-next track gets only its own key; the others never see it.

Above `- name: Write notary test receipt`:

    # cx-f58x: text receipts only (notary-test-receipt.sh).

Above `run: s=scripts/ci/nightly-steps/notary-test-receipt.sh; [ -f "$s" ] || s=".nightly-signing-control/$`:

    # An unsigned resume of an older tree may predate the script: the workflow commit's copy.

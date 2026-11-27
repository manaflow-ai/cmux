# 2026-11-27-publish-nightly-3

Above `if: "always() && !cancelled() && needs.decide.result == 'success' && needs.decide.outputs.should_build == 'true' && needs.decide.outputs.fast_build != 'true' && needs.decide.outputs.build_only != 'true' && (github.event_name != 'schedule' || github.event.schedule == '47 8 * * *') && needs.resolve-nightly-cmux-tui-client.outputs.already_published != 'true' && needs.decide.outputs.no_publish != 'true' && ((needs.build-sign-notarize-nightly.result == 'success' && needs.build-sign-notarize-nightly.outputs.notary_pending != 'true' && needs.verify-signed-nightly.result == 'success' && needs.verify-final-dmg-nightly.result == 'success') || (needs.recover-nightly-next-notarization.outputs.accepted == 'true' && needs.verify-recovered-nightly-next.result == 'success') || needs.republish-nightly-next.result == 'success')"` (job `publish-nightly`) in `.github/workflows/nightly.yml`.

Visual coverage is advisory: route, capture, and verdict jobs still report findings, but
neither a display queue nor an enforce-mode verdict can hold publication.

# publish-nightly: if: "always() && !cancelled() && needs.decide.result == 'success' && needs.decid

Where: the `publish-nightly` job in `.github/workflows/nightly.yml`, above `if: "always() && !cancelled() && needs.decide.result == 'success' && needs.decide.outputs.should_bui…`.

Visual coverage is advisory: route, capture, and verdict jobs still report findings, but
neither a display queue nor an enforce-mode verdict can hold publication.

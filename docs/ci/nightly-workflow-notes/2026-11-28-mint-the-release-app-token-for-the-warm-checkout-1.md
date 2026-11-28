# 2026-11-28-mint-the-release-app-token-for-the-warm-checkout-1

Where: `.github/workflows/nightly.yml`, Mint the release App token for the warm checkout.

Mint only after the claim (signing rule 7a). Only the checkout receives the read-only token. Its App quota avoids the shared unauthenticated limit hit in run 45744507889.

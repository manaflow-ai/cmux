# 2026-11-28-build-nightly-app-bundle-the-cmux-tui-client

Where: `.github/workflows/nightly.yml`, job `build-nightly-app`, step "Bundle the cmux-tui client": above `GH_TOKEN_SPARES: ${{ secrets.CI_POOL_TOKEN_1 }} ${{ secrets.CI_POOL_TOKEN_2 }}`.

RATE_LIMIT_MOVES_TO_A_SPARE (pin-cmux-tui.sh github_get): the tree wait's runs reads move to the CI pool's tokens when the installation's hour is spent (nightly 46095639816).

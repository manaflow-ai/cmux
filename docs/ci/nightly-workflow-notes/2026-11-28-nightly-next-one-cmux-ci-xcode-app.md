# 2026-11-28-nightly-next-one-cmux-ci-xcode-app

Where: `.github/workflows/nightly.yml`, job `nightly-next-one`: above `CMUX_CI_XCODE_APP: ${{ vars.CMUX_CI_XCODE_APP_MACOS_26 }}`.

GH_TOKEN_SPARES (c-bedbdb1917) sits on this job's github.token gh steps, not here: a signing job holds no secret at job level, or every bundle step sees the pool tokens (test_ci_signing_keychain_is_deleted_before_bundle_code.py).

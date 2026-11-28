# 2026-11-27-nightly-next-one-2

Above `- name: Mint the release App token for the warm checkout` (job `nightly-next-one`) in `.github/workflows/nightly.yml`.

After the claim (the release App key comes after it, rule 7a of
tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py): the key reaches only the action, the
read-only token only the warm checkout's env, which keeps .publish-tooling through its clean. One installation token for this checkout, so its GitHub reads spend the App's own
quota (5,000+ an hour) and never the Mac's shared unauthenticated per-IP limit (run 45744507889).

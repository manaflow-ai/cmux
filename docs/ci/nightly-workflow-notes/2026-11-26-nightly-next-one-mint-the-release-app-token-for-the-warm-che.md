# nightly.yml: job `nightly-next-one`, step "Mint the release App token for the warm checkout"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

After the claim (the release App key comes after it, rule 7a of
tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py): the key reaches only the action, the
read-only token only the warm checkout's env, which keeps .publish-tooling through its clean. One installation token for this checkout, so its GitHub reads spend the App's own
quota (5,000+ an hour) and never the Mac's shared unauthenticated per-IP limit (run 45744507889).

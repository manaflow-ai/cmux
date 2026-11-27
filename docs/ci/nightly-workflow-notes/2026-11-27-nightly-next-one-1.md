# 2026-11-27-nightly-next-one-1

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || vars.CI_NIGHTLY_MINI != '' && 'glaeda-trusted-next-signing' || needs.pick-nightly-next-signer.outputs.attempt == github.run_attempt && needs.pick-nightly-next-signer.outputs.pin && fromJSON(needs.pick-nightly-next-signer.outputs.pin) || 'glaeda-trusted-next-signing' }}` (job `nightly-next-one`) in `.github/workflows/nightly.yml`.

The signer label, a literal (one-mini mode too): no variable picks where signing secrets go. The pick only
narrows it to one signer runner; its pin always starts with the label. Why: docs/ci/nightly-workflow-notes.md#note-33

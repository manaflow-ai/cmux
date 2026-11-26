# 2026-11-26-pick-nightly-next-signer-1

Above `- name: Mint a spare read token for the pick` (job `pick-nightly-next-signer`) in `.github/workflows/nightly.yml`.

The glaeda-route App's read-only token, as decide mints it on the same runner: its own hourly budget. With
github.token alone the shared budget ran dry and the pick fell back to cmux15 (run 45575194160: HTTP 403), so
a second build waited 10.5 min behind the first. Optional: the pick falls back to github.token without it.

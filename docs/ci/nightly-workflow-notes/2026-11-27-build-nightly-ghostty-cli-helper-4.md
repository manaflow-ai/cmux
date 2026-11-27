# 2026-11-27-build-nightly-ghostty-cli-helper-4

Above `- name: Upload cmux-next license trees` (job `build-nightly-ghostty-cli-helper`) in `.github/workflows/nightly.yml`.

Signing only embeds the license trees. Keep that handoff separate from
the optional source offer so each signing leg does not download the
complete source archive just to copy a few notices into the app.

# build-nightly-ghostty-cli-helper: Upload cmux-next license trees

Where: the `build-nightly-ghostty-cli-helper` job in `.github/workflows/nightly.yml`, above `- name: Upload cmux-next license trees`.

Signing only embeds the license trees. Keep that handoff separate from
the optional source offer so each signing leg does not download the
complete source archive just to copy a few notices into the app.

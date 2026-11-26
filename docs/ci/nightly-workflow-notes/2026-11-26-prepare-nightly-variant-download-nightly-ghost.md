# prepare-nightly-variant: *download-nightly-ghostty-license-trees

Where: the `prepare-nightly-variant` job in `.github/workflows/nightly.yml`, above `- *download-nightly-ghostty-license-trees`.

Blocking, like the step that builds it: a nightly-next app always
ships the Ghostty license tree. This is a small artifact containing
only the trees, rather than the complete source offer archive.

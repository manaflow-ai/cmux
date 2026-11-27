# 2026-11-27-prepare-nightly-variant-primary-3

Above `- &download-nightly-ghostty-license-trees` (job `prepare-nightly-variant-primary`) in `.github/workflows/nightly.yml`.

Blocking, like the step that builds it: a nightly-next app always
ships the Ghostty license tree. This is a small artifact containing
only the trees, rather than the complete source offer archive.

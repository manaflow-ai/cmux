# 2026-11-26-build-nightly-ghostty-cli-helper-1

Above `- name: Strip the Ghostty CLI helper` (job `build-nightly-ghostty-cli-helper`) in `.github/workflows/nightly.yml`.

The strip-release-bundle.sh pass that prepare-nightly-variant ran on
the injected helper (helpers keep their global symbols). That job is on
Linux now, where only Apple's strip gives these bytes; a fast build's
prepare never stripped it.

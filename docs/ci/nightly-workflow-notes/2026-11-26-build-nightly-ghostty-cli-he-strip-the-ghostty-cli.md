# build-nightly-ghostty-cli-helper: Strip the Ghostty CLI helper

Where: the `build-nightly-ghostty-cli-helper` job in `.github/workflows/nightly.yml`, above `- name: Strip the Ghostty CLI helper`.

The strip-release-bundle.sh pass that prepare-nightly-variant ran on
the injected helper (helpers keep their global symbols). That job is on
Linux now, where only Apple's strip gives these bytes; a fast build's
prepare never stripped it.

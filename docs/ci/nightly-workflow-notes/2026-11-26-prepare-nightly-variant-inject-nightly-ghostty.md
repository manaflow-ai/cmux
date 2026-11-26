# prepare-nightly-variant: *inject-nightly-ghostty-licenses

Where: the `prepare-nightly-variant` job in `.github/workflows/nightly.yml`, above `- *inject-nightly-ghostty-licenses`.

The Ghostty dependency license tree (collect-ghostty-licenses.py, checked
by verify-ghostty-license-bundle.py) ships in the app, with the MPL-2.0
source offer that names this release's cmux-next source archive and tag.

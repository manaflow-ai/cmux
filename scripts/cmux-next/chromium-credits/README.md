# Chromium credits (INTERIM)

`<chromium version>.html.gz` is `CREDITS.html` from the stock CEF binary
distribution for that Chromium version (Chromium's `tools/licenses/licenses.py
credits`: Chromium and every third-party component in it, with their license
texts), `gzip -9 -n`.

The manaflow-ai/cef fork release (cef-manifest.json) does not ship a
`CREDITS.html` up to cmux.17. Until it does (cmux.18), `install-cef-credits.sh`
puts this stock file, with an INTERIM header comment, at
`Contents/Frameworks/Chromium Embedded Framework.framework/Resources/CREDITS.html`.
When the artifact carries its own `CREDITS.html`, that file is used and this
copy is not. `check-cef-credits.sh` is the release-bundle gate.

- `154.0.8037.58.html.gz` (sha256 9c8b10b7eb62cd4be22d6fd534552b653823d507541e6e3f29578b038fd694d2;
  decompressed sha256 3714c02897a1e3bf73fc6273017ce611b01a621d796ec73e52acf83893b44270):
  from `cef_binary_154.0.28+g564dd6c+chromium-154.0.8037.58_macosarm64_minimal.tar.bz2`
  (https://cef-builds.spotifycdn.com/index.html, CEF 154.0.28, the base of our
  fork releases cef-154.0.28-cmux.*). Same bytes as manaflow-ai/cmux-gpui
  3e22322 `third_party/chromium-credits/154.0.8037.58.html.gz`.

This assumes the fork's patches add no third-party code (not checked); the
fork's generated file replaces this one.

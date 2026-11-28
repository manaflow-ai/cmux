# CEF license text

`LICENSE.txt` is CEF's own license (BSD-3-Clause; Marshall A. Greenblatt,
portions Google Inc.), byte for byte from the stock CEF binary distribution
that the manaflow-ai/cef fork releases (cef-154.0.28-cmux.*) are based on.
The fork artifact ships no `LICENSE.txt` up to cmux.17, so
`install-cef-license.sh` puts this copy at
`Contents/Frameworks/Chromium Embedded Framework.framework/Resources/LICENSE.txt`.
When the artifact carries its own `LICENSE.txt`, that file is used instead.
`scripts/cmux-next/notices/bundle-map.json` requires the file for every CEF
binary. Do not edit it.

- `LICENSE.txt`, sha256 058c3827ffb827ff3edda471ae7e1bb1d1aa5931985f0126043ccd33409e792f
  (1662 bytes), from `cef_binary_154.0.28+g564dd6c+chromium-154.0.8037.58_macosarm64_minimal/LICENSE.txt`.

Byte proof (2026-10-04): downloaded
https://cef-builds.spotifycdn.com/cef_binary_154.0.28%2Bg564dd6c%2Bchromium-154.0.8037.58_macosarm64_minimal.tar.bz2
(132,225,032 bytes, sha256 fbdb08cd675c39ce9d5877e34331bc5c29a6c62897bb8358a9eab8100bf21230, equal
to the published `.sha256`). Its `LICENSE.txt` has the sha256 above. Its `CREDITS.html`
(3714c028...) is the file in `../chromium-credits/`, so both come from the same distribution.

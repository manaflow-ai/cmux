# Chromium vector icons

The cmux-next browser chrome (toolbar, address bar, find bar, extension buttons and menus, media
controls, side panel header) draws Chrome's own icons.

- `src/` holds the upstream `.icon` files unchanged, at the paths they have in
  [chromium/src](https://chromium.googlesource.com/chromium/src), plus Chromium's `LICENSE`
  (BSD-3-Clause, The Chromium Authors).
- `manifest.json` pins the upstream revision and maps each cmux pack name (`browser.toolbar.back`)
  to its file and the canvas representation to use. These are Chrome's shipping icons: at the
  pinned revision `features::IsRoundedIconsEnabled()` is off by default, so Chrome draws the
  `*_chrome_refresh_old` set.
- `scripts/icons/chromium_icons.py` converts them into `design/icons/source/chromium.json`
  (`--check` fails when it is stale); `scripts/icons/build_pack.py` then puts them into the one pack
  the native app and the web views draw. Catalog entries carry `"source": "chromium"`.
- `scripts/cmux-next/lint-browser-chrome-icons.py` fails when browser chrome code uses an SF Symbol
  or a non-Chromium pack icon; a line that must keep one says `// chrome-icons: allow <reason>`.
- The license notice is the "Chromium vector icons" section of `THIRD_PARTY_LICENSES.md`
  (hand-written input: `scripts/cmux-next/notices/hand-written.md`).

Sizes follow Chrome's layout constants: toolbar icons 20 pt (`kToolbarButtonIconSize`), the site
icon left of the URL 16 pt (`kLocationBarLeadingIconSize`), the star 20 pt
(`kLocationBarTrailingIconSize`). Toolbar buttons highlight in a circle, as Chrome's ink drop does.

To add an icon: fetch the file at the pinned revision into `src/`, add a manifest row, run
`python3 scripts/icons/chromium_icons.py && python3 scripts/icons/build_pack.py`.

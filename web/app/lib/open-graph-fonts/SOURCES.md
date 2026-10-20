# Open Graph font subsets

These files contain only the glyphs used by the localized Open Graph taglines.
They were generated with fonttools `pyftsubset` while preserving all layout
features. `web/tests/opengraph-image-route.test.ts` renders every configured
locale, verifies visible tagline pixels, and checks every non-whitespace tagline
code point against the bundled fonts' cmap tables.

Sources:

- Geist Regular and SemiBold: Google Fonts `geist`
- Noto Sans CJK JP, SC, TC, and KR: `notofonts/noto-cjk`
- Noto Sans, Noto Sans Thai, and Noto Sans Khmer: `notofonts`
- Tajawal: Google Fonts `tajawal`

All source fonts use the SIL Open Font License included in `OFL.txt`.

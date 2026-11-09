# Neko candidate art notices

These files are gallery candidates only. They are not imported by the shipped icon pack and are not
approved production artwork. The three third-party representatives are unmodified SVGs fetched at the
pinned commits in `manifest.json`; the neighboring `LICENSE.txt` and `README.md` files are the complete
license and upstream README captured at that same commit.

- `noto-emoji/cat.svg` is `2D/svg/emoji_u1f431.svg` from Google Noto Emoji at commit
  `99701e07d3d1fe1bdbcdb14964547f0fd592966f`. The 2D SVG artwork is Apache-2.0 under the upstream
  `2D/svg/LICENSE` (the full canonical text is `noto-emoji/APACHE-2.0.txt`). Noto's font files have
  a separate OFL-1.1 license; no font file is included here.
- `fluent-emoji/cat-flat.svg` is `assets/Cat/Flat/cat_flat.svg` from Microsoft Fluent Emoji at
  commit `1ffb34c752ecf5d402f04cfb4b392c77f57c54bc`, under the captured MIT license.
- `lucide/cat.svg` is `icons/cat.svg` from Lucide at commit
  `1980e3d59b0fa1a2aeb566d5902b25ee98204001`, under the captured ISC license.

The two authored cmux Neko fill-ins (`action.copy` and `action.pin`) are generated separately by
`scripts/icons/build_pack.py`; they are original cmux geometry and have no third-party provenance.
No candidate SVG has been transformed, recolored, or combined into those fill-ins. SHA-256 hashes,
source paths, byte counts, and repository URLs are recorded in `manifest.json`.

Round 2's nine original monochrome experiments in `round2/` reuse first-party cmux action
silhouettes, as recorded in that directory's manifest. They are not derived from a third-party cat
asset and remain gallery-only. No production theme imports these experiments.

# Chat interface font candidates

The faces `chatUiFont.ts` offers besides the system font, the default (`Settings > Agent Chat > Interface
Font`, `agentPane.display.font.ui`). Each is the Latin subset of the font's variable weight axis,
unmodified, from Fontsource `@fontsource-variable/<name>` 5.x (`files/<name>-latin-wght-normal.woff2`).
A character outside Latin falls back to the system font. The licence notices are in `OFL.txt`.

| File                                        | Font                       | sha256                                                             |
| ------------------------------------------- | -------------------------- | ------------------------------------------------------------------ |
| `Inter-latin-wght.woff2`                    | Inter (5.2.8)              | `3100e775e8616cd2611beecfa23a4263d7037586789b43f035236a2e6fbd4c62` |
| `Roboto-latin-wght.woff2`                   | Roboto                     | `1404ca348bd75ef836f4dd8b6f2cc719458642d1237c368296b2fc652dca47dc` |
| `IBMPlexSans-latin-wght.woff2`              | IBM Plex Sans              | `e2291e842cf5af167122a22881a740c7f2dda7716f1e8cd76680264f4a859470` |
| `SourceSans3-latin-wght.woff2`              | Source Sans 3              | `19143dca075972bc84e3fd9eab7416dd40cc565dccb2435a044bdfabe060c7d5` |
| `Geist-latin-wght.woff2`                    | Geist                      | `19f9c92546aa300c312235e3125af1b81394d8db9a4bc4a425cd5b641d2d54e1` |
| `HankenGrotesk-latin-wght.woff2`            | Hanken Grotesk             | `e9201eddf1d41d0b62253295d869ce3cf65768f7102b797f02c7f8c876b4a9d5` |
| `AtkinsonHyperlegibleNext-latin-wght.woff2` | Atkinson Hyperlegible Next | `18b2a1a39a2fa298b0ba5390aca68462669826c90925656f1c1f6796e0e1bbaf` |
| `cmuxSans-latin-wght.woff2`                 | cmux Sans                  | `ef16f0da63bd8946187083e17cb5e89909735f6bae3f159fc04b94ebf9a5d8a9` |
| `cmuxSansSquat-latin-wght.woff2`            | cmux Sans Squat            | `141a246b968d230228f44a47dc2aaf00f152b9e9d0e1c5b7c2e753fce4f92364` |
| `cmuxSansCandy-latin-wght.woff2`            | cmux Sans Candy            | `d69bb5a89d81737869c12ef385c7da94ca2115b6526d811bea3fd6357f14fd74` |
| `cmuxSansOpen-latin-wght.woff2`             | cmux Sans Open             | `8a00bcfb95972dd55410f7b19c7669d71186f8cca78bf04cf0347b41d881622b` |

cmux Sans is ours: Source Sans 3 3.052R (Adobe's variable font, sha256-checked) with its lowercase 8 %
taller at Source's own size, cut to the same Latin range and features, built by
`python3 scripts/fonts/cmux-sans/build.py --preset c --subset latin --release --out DIR` (fontTools; the
file is reproducible). The OFL reserves the name "Source", so its family is "cmux Sans". The font
study (webviews/src/gallery/fontStudy) ranked it with Source Sans 3 above Inter, the app's UI font until 2026-11-07,, and picked
Hanken Grotesk and Atkinson Hyperlegible Next as the other two to try.

cmux Sans Squat and Candy are cmux Sans with more character, opt-in (Leo, 2026-11-19: cmux Sans looks "a
bit like generic school font ... It just doesn't have that like pizzazz", and he likes a face that "looks a bit
squat"). Each is `build.py --preset squat|candy --subset latin --release --out DIR`: Squat 8 % wider with a
lowercase 15 % taller than Source's and its regular a touch heavier (440); Candy 5 % wider, the single-storey a
and the tailed l, heavier (470).
The width scales every outline, advance and kern; the weight moves the axis (avar), so 400 draws heavier and 200
and 900 stay. Their tracking is chatUiFont.ts's, per width.

cmux Sans Open fixes the fit, not the letters (Leo, 2026-11-19: "The kerning in cmux sans is off it all looks too
packed together and narrow a lot of the time ... Quillet does things better"): `build.py --preset open`. Measured against
Quillet at weight 400, cmux Sans's lowercase sidebearings sum 88 units to Quillet's 103 and its word space is 200 to
270, so Open is 4 % wider, adds 8 units each side of a lowercase letter (4 more right of the round ones), 3 each side
of a capital (6 more right of the round ones), 4 each side of a figure, and has a 255-unit word space. Its x-height
stays cmux Sans's.

Inter was the app's bundled UI font until 2026-11-07 (Lawrence: "default fonts on cmux for everything should
be macos default, not inter"); it stays a choice here, `cmux Inter` (its calculated tracking) or stock, and
no longer loads unless chosen. Verdana and the system font are not bundled: macOS has both.

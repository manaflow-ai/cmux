# Chat interface font candidates

The faces `chatUiFont.ts` offers besides the app's own Inter (`Settings > Agent Chat > Interface
Font`, `agentPane.display.font.ui`). Each is the Latin subset of the font's variable weight axis,
unmodified, from Fontsource `@fontsource-variable/<name>` 5.3.x (`files/<name>-latin-wght-normal.woff2`).
A character outside Latin falls back to Inter. The licence notices are in `OFL.txt`.

| File | Font | sha256 |
| --- | --- | --- |
| `Roboto-latin-wght.woff2` | Roboto | `1404ca348bd75ef836f4dd8b6f2cc719458642d1237c368296b2fc652dca47dc` |
| `IBMPlexSans-latin-wght.woff2` | IBM Plex Sans | `e2291e842cf5af167122a22881a740c7f2dda7716f1e8cd76680264f4a859470` |
| `SourceSans3-latin-wght.woff2` | Source Sans 3 | `19143dca075972bc84e3fd9eab7416dd40cc565dccb2435a044bdfabe060c7d5` |
| `Geist-latin-wght.woff2` | Geist | `19f9c92546aa300c312235e3125af1b81394d8db9a4bc4a425cd5b641d2d54e1` |

Verdana and the system font are not bundled: macOS has both.

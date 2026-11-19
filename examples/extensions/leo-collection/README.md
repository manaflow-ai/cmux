# The Leo collection

A riced-up set of cmux extensions, and a look that ties them together. Every piece is a short
example on the public SDK: read one, copy it, make your own. None of it is in the app by default;
you put it on live and take it off with one command.

| Piece | What it is | On its own | Source |
| --- | --- | --- | --- |
| [Clock](../leo-clock) | A big animated clock and the world's time zones | `cmux ext dev examples/extensions/leo-clock` | [#44206](https://github.com/manaflow-ai/cmux/pull/44206) |
| [Weather](../leo-weather) | Live, animated conditions where you are | `cmux ext dev examples/extensions/leo-weather` | [#44224](https://github.com/manaflow-ai/cmux/pull/44224) |
| [Gacha](../leo-gacha) | Pull a Chief: rarity glow, confetti, a collection log | `cmux ext dev examples/extensions/leo-gacha` | [#44199](https://github.com/manaflow-ai/cmux/pull/44199) |
| [Usage](../leo-usage) | Tokens and spend across all your agents | `cmux ext dev examples/extensions/leo-usage` | signal [#44145](https://github.com/manaflow-ai/cmux/pull/44145) |
| [Theme](../../customize/leo) | The look: dusk, daylight or neon | `cmux customize use examples/customize/leo/dusk.json` | [#44176](https://github.com/manaflow-ai/cmux/pull/44176) |

A piece whose PR has not merged yet is skipped by `install.sh`; until then, try it from its own
branch: `cmux customize use pr:N`.

## All of it, one command

From the root of this repository, with cmux open:

```sh
examples/extensions/leo-collection/install.sh          # the four extensions and the dusk look
examples/extensions/leo-collection/install.sh neon     # the same with another look
examples/extensions/leo-collection/install.sh remove   # take it all off
```

Each extension shows its install card once, listing what it may read or reach and why; accept it
and it stays installed. The look is a preview until `cmux customize apply`.

## Look how simple this is

- An extension is a folder: `cmux-app.json` (what it is and the scopes it asks for) and
  `src/main.ts` (its view). `cmux ext dev DIR` reloads it on every save.
- A look is one JSON file of settings: colors, glass, the sidebar. `cmux customize use FILE`
  shows it on your window before you keep it.
- They match because the extensions draw theme tokens (`accent`, `success`, `warning`, `danger`,
  `secondary`), never fixed colors. Switch the look and every piece recolors at once:

| Token | dusk | daylight | neon |
| --- | --- | --- | --- |
| `accent` | `#a78bfa` | `#7c4dff` | `#ff4fd8` |
| `success` (ANSI 2) | `#7ee0b5` | `#1f8a5f` | `#3dff9e` |
| `warning` (ANSI 3) | `#f6c177` | `#a8650f` | `#ffd23d` |
| `danger` (ANSI 1) | `#f2708a` | `#c92a5e` | `#ff3b6b` |
| highlight (ANSI 4) | `#7aa2f7` | `#3563c9` | `#3d8bff` |
| cyan (ANSI 6) | `#6fd3e8` | `#0b839a` | `#00e5ff` |

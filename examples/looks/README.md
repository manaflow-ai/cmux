# Looks written on public surfaces

Each folder is a whole cmux look written the way anyone outside the cmux team could write it: a theme
file, a few settings, a stylesheet of public chat tokens and a sidebar view, in one setup
([docs/cmux-next/look-addons.md](../../docs/cmux-next/look-addons.md)).

| Look | What it is |
| --- | --- |
| [`studio`](studio) | A dense, near-black workbench: quiet chrome, compact rows, a boxed prompt with a hairline |
| [`paper`](paper) | A warm, roomy reading look: serif replies on paper, soft rounded prompts |

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/studio@feat-cmux-next   # on, as one layer
cmux setup remove manaflow-ai/studio-look                                              # off; yours comes back
```

[`looks.json`](looks.json) lists every look and the built-in preset it recreates. CI installs each one
(`cmux-customize` `tests/example_looks.rs`), holds its stylesheet to the public token list
(`bun run check:look-addons`), and draws it in the real chat to check that nothing moves
(`webviews/test/browser/look-addons.test.ts`).

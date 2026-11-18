# Looks written on public surfaces

Each look is a whole cmux look written the way anyone outside the cmux team could write it: a theme
file, a few settings, a stylesheet of public chat tokens and a sidebar view, in one setup
([docs/cmux-next/look-addons.md](../../docs/cmux-next/look-addons.md)). Each lives in a small repo of
its own, like dotfiles, and you install it from there:

| Look | Its repo | What it is |
| --- | --- | --- |
| [`studio`](studio) | [manaflow-ai/cmux-studio-look](https://github.com/manaflow-ai/cmux-studio-look) | A dense, near-black workbench: quiet chrome, compact rows, a boxed prompt with a hairline |
| [`paper`](paper) | [manaflow-ai/cmux-paper-look](https://github.com/manaflow-ai/cmux-paper-look) | A warm, roomy reading look: serif replies on paper, soft rounded prompts |

```sh
cmux setup install github.com/manaflow-ai/cmux-studio-look   # on, as one layer
cmux setup remove manaflow-ai/studio-look                     # off; yours comes back
```

The look's repo is its source: change a look there. The folders here are copies that cmux's own tests
check: their setup, theme, stylesheet and view files are the repos'. [`looks.json`](looks.json) lists every look and the built-in preset
it recreates. CI installs each one (`cmux-customize` `tests/example_looks.rs`), holds its stylesheet to
the public token list (`bun run check:look-addons`), and draws it in the real chat to check that
nothing moves (`webviews/test/browser/look-addons.test.ts`).

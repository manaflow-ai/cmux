# The Leo look

The look that ties the [Leo collection](../../extensions/leo-collection) together, as one profile
file per variant. It is opt-in: nothing changes until you use it, and one command takes it off.

| Variant | The look |
| --- | --- |
| [`dusk`](dusk.json) | Violet glass over a painted dusk; mint, gold and rose tones |
| [`daylight`](daylight.json) | Frosted glass on lavender paper; a violet accent, teal and amber tones |
| [`neon`](neon.json) | Hot pink and cyan on black glass over a night of fireworks |

```sh
cmux customize use examples/customize/leo/dusk.json   # on, live, nothing kept yet
cmux customize discard                                # off again
cmux customize apply                                  # or keep it (then `rollback` takes it off)
```

No checkout? `curl -fsSLo /tmp/leo.json https://raw.githubusercontent.com/manaflow-ai/cmux/lane/leo-collection-theme/examples/customize/leo/dusk.json && cmux customize use /tmp/leo.json`.

Each variant is a theme file (`<variant>/themes/leo-<variant>.json`: the terminal colors, accent,
glass, sidebar and pane surfaces) plus the style surfaces in `shared/` (`agent-pane/theme.css`,
`markdown/theme.css`). The extensions match it by drawing theme tokens (`accent`, `success`,
`warning`, `danger`), which come from `colors.accent` and ANSI 2, 3 and 1. Edit a file, then run
`python3 examples/customize/leo/bundle.py` to rebuild the three bundles.

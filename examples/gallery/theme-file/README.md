# Starter Dusk

The smallest look you can share: one theme file and the setting that picks it.

| File | What it does |
| --- | --- |
| `cmux-setup.json` | The look's id, name and tagline. One setting: `"appearance.themeFile": "starter-dusk"` |
| `themes/starter-dusk.json` | The theme file. It sets four colors that every surface mixes from, the terminal's sixteen ANSI colors as Ghostty lines, card chrome and comfortable density |

A key the theme file leaves out stays as you had it. The keys a theme file may carry are listed in
[theme-recipes.md](../../../docs/cmux-next/theme-recipes.md).

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/gallery/theme-file@feat-cmux-next
cmux setup remove manaflow-ai/starter-dusk
```

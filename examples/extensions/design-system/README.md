# Design system: your own on top of cmux's

`local/showcase-design-system` imports nothing but `cmux-extension-sdk`. `cmux-design.json` is a
design system (`cmux.design/1`) on top of cmux's: it sets only what differs, and everything else
comes from cmux's system. A pane shows it, drawn with itself, beside cmux's own.

- `type` overrides cmux's roles by name (`numeral`, `heading`) or adds one (`code`): a size of 9 to
  64 points and a weight (regular, medium, semibold, bold), `monospaced` optional.
- `space` replaces the spacing scale: from 0, going up, 2 to 16 steps.
- `colors` names cmux color roles (`brand` is `accent`), so dark mode and contrast still hold. A
  hex color is not a role and is refused.
- `limits` moves how many type roles and accent colors one view may use.

`defineDesign(spec)` merges the file over `cmuxDesign` and throws, naming the field and the fix,
when an entry does not hold. Draw text with `design.text("code", "…")` and colors with
`design.color("brand")`. `DesignSystemView(system)` is the page: the type roles as specimens (the
ones you change or add marked), the spacing scale as bars, each color and the role it stands for,
the widget components drawn with the system, and its limits. The two buttons at the top flip
between cmux's system and this one.

## Run it

```sh
cd examples/extensions/design-system
cmux ext dev
```

`cmux ext dev` packs `src/main.ts` into `dist/main.js` (build output, not committed) and checks
the pane's scene against `cmux-design.json`. Outside this repository, copy the folder and run `npm
install` first; inside it, `tsconfig.json` points the import at the SDK's source. Tests:
`cmux-tui/crates/cmux-app-host/js/test/design.test.ts` packs it and runs it in the fake host.

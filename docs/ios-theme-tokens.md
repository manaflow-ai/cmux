# iOS: literal styling instead of theme tokens

The class: iOS view code that picks its own color or size, such as `Color(red: 0.2, green: 0.6, blue: 1)`,
`.foregroundStyle(.orange)` or `.font(.system(size: 15))`, instead of a semantic system style or a
named token from the surface's theme type. Each one looks fine in the screenshot it was written for
and breaks somewhere else: dark mode, a light terminal theme, Dynamic Type at an accessibility size,
or the next palette change, which has to find every copy by hand. Two screens that both mean
"connected" end up in two greens.

The rule, the same one desktop UI follows: a UI change starts from the references and the surface's
spec (`ios/design/ios-<surface>.md`), uses theme tokens only, and ships with its variants (iPhone, iPad,
a foldable iPhone folded and unfolded, Dynamic Type, dark mode, rotation).

## Detector

`scripts/lint_ios_theme_tokens.py`, run by `scripts/lint-ios-package-conventions.sh`, which the
`package-conventions-lint` job in `.github/workflows/test-ios.yml` runs on every pull request that
touches `ios/` or `Packages/`. Its tests are `scripts/tests/test_lint_ios_theme_tokens.py`.

| Rule | Flags | Use instead |
| --- | --- | --- |
| `literal-color` | `Color(red:/white:/hue:)`, `Color(.sRGB, ...)`, `UIColor(red:/white:/hue:)`, `#colorLiteral`, `Color(hex: "...")` | `.primary`, `.secondary`, `Color.accentColor` / `.tint`, `PlatformPalette`, or a token in the surface's theme |
| `hue-color` | `Color.blue`, `UIColor.systemOrange`, `.foregroundStyle(.red)`, `.tint(.green)` and the other style modifiers | `Color.accentColor` / `.tint` for brand and selection; a named status token in the theme for connected, warning and failure |
| `literal-font-size` | `.system(size: N)`, `UIFont.systemFont(ofSize: N)`, `.custom(_, size: N)` | a text style (`.body`, `.system(.title2, design: .monospaced)`, `UIFont.preferredFont(forTextStyle:)`) or a size scaled with `@ScaledMetric` / `UIFontMetrics` |
| `literal-radius`, `literal-padding` | `cornerRadius: N`, `.padding(N)`, only in packages whose theme defines those tokens (today `CmuxMobileChanges`, `ChangesTheme`) | the theme's token |

Each finding prints `file:line`, the line, and the token to use.

Not checked: tests and UI tests, debug and preview code (files under `Debug/`, files whose code
starts inside `#if ... DEBUG`, everything after `#Preview` or a `PreviewProvider`), and the token
definitions themselves (files named `*Theme.swift`, `*Palette.swift`, `*Colors.swift`,
`*Tokens.swift`, with an optional `+Extension`). Comments and strings are ignored. A line that
must keep a literal (the App Store brand mark, a value matched to an Apple reference) takes a
`lint:allow <reason>` comment on it or one of the two lines above.

The detector reads source text, so it misses a hue passed through a variable or a bare `.blue`
argument to a custom function (`deviceIcon(tint: .blue)`). Review still catches those; when you
see one, add the form to the detector.

## Baseline

The violations that predate the detector are in `scripts/lint-ios-theme-tokens-baseline.txt`,
keyed by rule, path and line text (so moved code stays matched). A new finding fails the PR. When
you fix one, the lint warns that the entry is gone; drop it with

```
python3 scripts/lint_ios_theme_tokens.py --update-baseline
```

which refuses to add entries. `--summary` prints the count by package and rule.

## Fixing one

1. Find the token. Semantic system styles first; then the surface's theme (`PlatformPalette`,
   `ChangesTheme`, `ConversationTheme`, `TerminalTheme`, `TerminalSizingChromePalette`,
   `MachineAvatarColors`). If the value is new, add a named token to that theme, not a second literal.
2. Check the surface's spec in `ios/design/` and update its Tokens section.
3. Look at it in light and dark, at an accessibility text size, and on iPad.

# Link Hints

An example extension for following links from the keyboard, built only on SDK ops.

- **Command "Link hints"** (`link_hints.show`): calls `page.hints {action: "show"}`, which draws a
  short label on every link of the focused browser tab. The Link Hints sidebar section turns into
  the picker: its field takes focus; type a label and it follows as soon as the label is complete
  (`page.follow {label}`), or press Return on a unique prefix, or click a row.
- **Command "Link hints: open in new split"** (`link_hints.show_split`): the same, but the picked
  link opens in a new split (`page.follow {label, new_split: true}`).
- **Escape** in the field, **Cancel**, or the command "Link hints: clear" (`link_hints.clear`) calls
  `page.hints {action: "clear"}` and removes the labels.
- `link_hints.follow {label, new_split?}` is also a command for the CLI and scripts:
  `cmux apps run cmux/link-hints follow --label sd`.

| Op | Scope | Why |
| --- | --- | --- |
| `page.hints {tab?, action}` | `page:write` | draw and remove the labels |
| `page.follow {tab?, label, new_split?}` | `page:write` | follow the picked link |

Build: `bun samples/apps/build.ts`. Test: `bun test samples/apps/link-hints` (mocks the page ops,
asserts show, type, follow; new split from a row; Escape clears).

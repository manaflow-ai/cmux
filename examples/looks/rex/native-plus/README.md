# Native Plus Menu

Optional companion pack for a build containing this SDK change. The base looks
remain compatible with builds that do not know `tabs.plusMenu`.

Install from this PR branch after opening a build containing its code:

```sh
git clone --single-branch --branch lane/rex-native-plus-menu https://github.com/manaflow-ai/cmux.git cmux-native-plus
cmux setup install ./cmux-native-plus/examples/looks/rex/native-plus
```

The setup and standalone `profile.json` both set:

```json
{"tabs.plusMenu":["terminal","localWorkspace","host"]}
```

Reorder or remove entries in General > Tabs > + Button Menu. The default is an
empty list (`[]`), which keeps direct creation. Remove this setup with
`cmux setup remove manaflow-ai/native-plus-menu` to restore the prior settings.

- `terminal` runs `newSurface` in the clicked pane on its machine. Existing
  terminal workspace and pane-placement preferences still apply.
- `localWorkspace` runs `workspace.newOnMachine` with the actual local machine
  ID, even when + belongs to a remote pane.
- `host` runs `remote.connect` without a destination, opening the existing
  connection picker. It does not select a machine for the other two rows.

For selecting an existing machine before creating content, use the richer
launcher supplied by the parent look. This pack configures only the native +
menu; it does not install that launcher or offer arbitrary per-row machine IDs.

The adjacent chevron and right-click menu still use `contextMenus.layouts.newTab`.
Option-click, keyboard actions, screen-bar + and button visibility are unchanged.
See [the behavior specification](../../../../docs/cmux-next/design/native-plus-menu.md).

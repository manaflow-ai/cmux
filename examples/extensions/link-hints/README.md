# Link hints: browse with the keyboard

`local/link-hints` imports nothing but `cmux-extension-sdk`. On a page in cmux's browser, with no
text field focused:

| Key | What it does |
| --- | --- |
| `f` | Labels every link and button on screen. Type a label to follow it; Shift on its last letter opens it in a new tab. Backspace takes a letter back; Escape, a click or a scroll takes the labels away. |
| `F` | Labels only the links, and opens the one you pick in a new tab. |
| `b` | Goes back. |
| `a` | Bookmarks the page, as cmux's own Bookmark This Page does. |
| `D` | Saves the page's images to Downloads. An image another site does not let the page read is skipped. |
| `y` | Copies the page's address, as cmux's own Copy Page URL does. |
| `/` | Opens a find bar on the page: type to find, Return for the next match, Shift-Return for the one before, Escape to close. |

Rebind any of them in the extension's pane, "Link hints keys": type keys separated by commas
(`g`, `G` for Shift+G, `/`) and press Return. An empty field turns a key off. While the extension
is installed and enabled, its keys come before cmux's own single-key browser keys; turn it off and
cmux's come back.

How it is made:

- Each key is a command in `catalog.json` whose `keyboard` entry has `"when": "browserFocused"`.
  cmux runs it when you press the key on a page that left it alone while no text field had
  focus, and passes the page's tab.
- `f`, `D` and `/` run a script in the page with `browserPage(ctx.cmux).eval`. The labels, the
  find bar and the keys you type into them live in the page, so nothing round-trips through cmux
  while you type.
- The pane saves your keys with `setPageKeys`; cmux routes the new keys at once.

## Run it

```sh
cd examples/extensions/link-hints
cmux ext dev
```

Accept the install card, then grant `browser:execute`, `browser:write` and `actions:run` in
Settings > Extensions: a local extension starts with read scopes only.

`cmux ext dev` packs `src/main.ts` into `dist/main.js` (build output, not committed). Outside
this repository, copy the folder and run `npm install` first; inside it, `tsconfig.json` points
the import at the SDK's source. Tests:
`cmux-tui/crates/cmux-app-host/js/test/showcase-examples.test.ts` runs it in the fake host.

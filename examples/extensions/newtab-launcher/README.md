# New Tab launcher: a calm launchpad

`local/showcase-newtab-launcher` draws a whole New Tab page through `cmux.newtab/1`. It keeps a
clock and a short greeting above three quick actions, then shows recent agent chats and the current
workspaces. Chats and workspaces are live SDK lists, so the page updates on cmux's events without
polling.

Pick it after installing with:

```sh
cmux settings set tabs.newTabApp local/showcase-newtab-launcher
```

The `layout` variant in Settings > Apps > New Tab launcher has three gallery layouts:

- **focus** keeps the launch actions prominent, then gives recent chats and workspaces their own rows.
- **split** puts the same two live lists side by side below the actions for a wider reading column.
- **compact** keeps the actions and a short recent-work strip together for a smaller page.

Settings also includes **Show greeting** and **Recent chats**. Unset `tabs.newTabApp` to return to
cmux's own New Tab page.

## Run it

```sh
cd examples/extensions/newtab-launcher
cmux ext dev
```

`cmux ext dev` packs `src/main.ts` into `dist/main.js` (build output, not committed). The sample
uses only `cmux-extension-sdk` and is included in `bun examples/extensions/build.ts --check`.

# JavaScript for this site: one command to turn it off or on

`local/showcase-site-js` imports nothing but `cmux-extension-sdk`. Run **Toggle JavaScript for
this site** from the command palette and the site in the front browser tab stops running
JavaScript, or starts again. A toast says which, and cmux reloads that site's open tabs.

- `site.javascript.get()` reads the site's setting, the same one as Page Info's JavaScript row,
  so either place shows the other's change.
- `site.javascript.set()` needs a gesture: the command passes its own (`ctx.gesture`), so an agent
  or a script can't flip it.

## Run it

```sh
cd examples/extensions/site-js
cmux ext dev
```

`cmux ext dev` packs `src/main.ts` into `dist/main.js` (build output, not committed). Outside
this repository, copy the folder and run `npm install` first; inside it, `tsconfig.json` points
the import at the SDK's source. Tests: `bun test` in this folder runs the command in the fake host.

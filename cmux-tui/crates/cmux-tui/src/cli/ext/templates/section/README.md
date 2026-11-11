# {{TITLE}}

A cmux extension (`local/{{NAME}}`): one sidebar section.

## Work on it

```sh
cmux ext dev            # in this folder: validate, build, load, then reload on every save
```

Edit `src/main.ts` and save. Each save prints one line: `reloaded in N ms`, or the error with
its file and line (the last version that loaded stays on screen). The extension's log lines
print as they come. Ctrl-C stops; the extension stays installed (`--remove-on-exit` removes it).

The first run asks you to install it (cmux shows a card; confirm it once). Until then cmux
loads it as a preview, so `cmux ext dev --once` still says whether it loads.

## In an agent's loop

```sh
cmux ext dev --once --json   # one validate + build + reload; exit 0 ok, 1 load, 3 no cmux, 4 manifest, 5 build
```

## Files

- `cmux-app.json`: the manifest (id, the section it implements, the scopes it asks for).
- `src/main.ts`: the code. `dist/main.js` is built from it (`bun` on PATH; without it,
  `dist/main.js` is loaded as it is).
- `cmux-app.d.ts`: the types of everything cmux gives the script.

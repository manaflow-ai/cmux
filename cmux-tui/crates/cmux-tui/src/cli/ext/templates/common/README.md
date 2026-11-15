# {{TITLE}}

A cmux extension (`local/{{NAME}}`): {{WHAT}}

## Work on it

```sh
cmux ext dev            # in this folder: validate, build, load, then reload on every save
```

Edit `src/main.ts` and save. Each save prints one line: `reloaded in N ms`, or the error with
its file and line (the last version that loaded stays on screen). The extension's log lines
print as they come. Ctrl-C stops; the extension stays installed (`--remove-on-exit` removes it).

The first run asks you to install it (cmux shows a card; confirm it once). Until then cmux
loads it as a preview, so `cmux ext dev --once` still says whether it loads.

{{USE}}

## In an agent's loop

```sh
cmux ext dev --once --json   # one validate + build + reload; exit 0 ok, 1 load, 3 no cmux, 4 manifest, 5 build
```

## Files

- `cmux-app.json`: the manifest (id, what it adds to cmux, the scopes it asks for).{{FILES}}
- `src/main.ts`: the code. It imports `cmux-extension-sdk`. `dist/main.js` is built from it
  (`bun` on PATH; without it, `dist/main.js` is loaded as it is).
- `sdk/`: `cmux-extension-sdk` as the cmux that made this folder ships it (SDK `API_VERSION`
  matches that cmux). `tsconfig.json` points the import here, so nothing is installed from a
  registry. `cmux ext new` in a newer cmux gives a newer copy.
- `cmux-app.d.ts`: the types of everything cmux gives the script; `cmux ext dev` keeps it
  matching the running cmux.

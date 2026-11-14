# Recent PRs: the pull requests you touched lately

`local/showcase-recent-prs` imports nothing but `cmux-extension-sdk`. A sidebar section lists your
pull requests of the last few days, open and merged, the ones you opened, the ones asking for your
review and the ones assigned to you, newest change first. A click opens one in a cmux browser tab.

- **Nothing here polls.** `cmux.watch("github.pulls", params)` reads through your connected GitHub
  account, once however many windows show it, and re-reads in the background.
- **Settings**: Look back (hours, default 72) and a GitHub login for the public fallback when no
  account is connected.

## Run it

```sh
cd examples/extensions/recent-prs
cmux ext dev
```

`cmux ext dev` packs `src/main.ts` into `dist/main.js` (build output, not committed). Outside
this repository, copy the folder and run `npm install` first; inside it, `tsconfig.json` points
the import at the SDK's source. Tests:
`cmux-tui/crates/cmux-app-host/js/test/showcase-examples.test.ts` packs each sample and runs it
in the fake host.

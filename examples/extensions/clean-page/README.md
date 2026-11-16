# Clean this page: your agent picks the clutter, cmux hides it

`local/showcase-clean-page` imports nothing but `cmux-extension-sdk`. Open a page in a browser tab,
run **Clean this page** from the command palette, and the ads, cookie banners, popups, newsletter
prompts, sticky bars and recommended rails go away. The next visit to that site is clean before it
draws, with no model call.

- `browserPage(ctx.cmux).state()` gives the tab's address. `src/page_read.js`, run with
  `browserPage(ctx.cmux).eval()`, lists the elements that look like clutter (at most 150, never the
  one holding the article) and changes nothing. It answers at once, since `eval` doesn't wait for a
  promise.
- `agent.ask()` sends that list to your default agent with every tool denied. It runs only from the
  command, with its gesture, since it spends your agent's quota.
- Only selectors that were in the list are kept, and never the article or main content. Then
  `site.style.set()` saves them, and cmux applies them to that site's open tabs and every later visit.
- The **Sites cleaned** sidebar section lists each site; **Restore** puts one back as it was.
- On a site that's already clean, the command says so; run it again (or **Clean this page again**)
  to start over with a fresh answer.

## Run it

```sh
cd examples/extensions/clean-page
cmux ext dev
```

`cmux ext dev` packs `src/main.ts` into `dist/main.js` (build output, not committed). Outside
this repository, copy the folder and run `npm install` first; inside it, `tsconfig.json` points
the import at the SDK's source. Tests: `bun test` in this folder. `test/clean.test.ts` covers the
prompt, the reply parser and the filter; `test/main.test.ts` runs the command and the section in
the fake host.

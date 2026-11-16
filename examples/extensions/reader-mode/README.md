# Reader mode: the article, and nothing else

`local/reader-mode` imports nothing but `cmux-extension-sdk`. On a browser page, **Shift+R** (or
**Reader Mode: Toggle** in the command palette) lays the article over the page as clean, readable
text: the site, the title, the byline and reading time, then the story with its images, quotes,
lists, code and tables. Menus, ads, share bars, related links, cookie banners and popups are gone.
Press Shift+R again (or Escape) and the page is back exactly as it was: reader mode never changes
or reloads the page, so the scroll position and anything you typed stay.

- **One script per toggle.** `src/page.js` runs in the page through `browserPage(cmux).eval`
  (`browser.page.eval`). It finds the block whose paragraphs carry the most text, adds the sibling
  blocks of the same story, cleans a copy and draws it in a shadow root, so the page's own styles
  never reach it. Only a small answer (`{reader, title, words, minutes}`) comes back.
- **It asks for one scope, `browser:execute`.** It lets the extension run a script in the page you
  are reading. cmux highlights it on the install card. A local extension starts with read scopes
  only, so turn it on in the extension's page under Extensions; you can turn it off there too.
- **The key is a page key** (`catalog.json`, `"when": "browserFocused"`): it never fires while you
  type in a field. Rebind it like any page key of an extension.
- **Light and dark** follow the system.

## Run it

```sh
cd examples/extensions/reader-mode
cmux ext dev
```

Accept the install card, allow `browser:execute` on the extension's page under Extensions, then
open an article in a browser tab and press Shift+R.

## Tests

`cmux-tui/crates/cmux-app-host/js/test/reader-mode.test.ts` packs the extension and runs the
command in the fake host. `test/page.test.ts` runs the page script against a news page in a DOM
(happy-dom, from `webviews/`). `scripts/cmux-next/media/tours/reader-mode.json` is the live tour
(`cmux-ci capture SHA --state scripts/cmux-next/media/tours/reader-mode.json --video`).

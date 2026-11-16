# Reader Mode

An example extension that reads the article of the focused browser tab and shows it as plain,
readable text in a pane, built only on SDK ops.

- **Command "Reader mode"** (`reader_mode.open`; Command Palette, `cmux apps run cmux/reader-mode open
  [--tab TAB]`): calls `page.read` on the focused browser tab (or `tab`), keeps the article, and opens
  the Reader pane with `app.open`.
- **Pane** (`cmux.pane/1`, `renderReader`): the title, byline and site, then every block in order:
  headings (by level), paragraphs, list items, quotes and code. The scene kit draws no remote
  images, so an image is a row with its caption; a click opens it in a browser tab. The page's
  links follow the article; a click opens one. **Read this page** reads the focused browser tab
  again, **Reload** re-reads the tab the article came from, **Open original** opens its URL.
- The last article stays in app storage, so the pane still shows it after a reload.

| Op | Scope | Why |
| --- | --- | --- |
| `page.read {tab?}` | `page:read` | the article and links of the page |
| `action.run app.open`, `openBrowser` | `actions:run` | open the pane, a link or an image |
| `app.storage.*` | `storage:local` | keep the last article |

Build: `bun samples/apps/build.ts`. Test: `bun test samples/apps/reader-mode` (mocks `page.read`,
asserts that the command reads the page, opens the pane and the pane renders every block kind).

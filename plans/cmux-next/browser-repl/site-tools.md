> Moved from https://github.com/manaflow-ai/cmux/pull/15570. History and authorship are in that PR. The runtime JS now lives in cmux-tui/crates/cmux-browser-host/js and the suite in tests/browser-parity; paths that name Sources/Panels/BrowserRepl, CmuxBrowser/Repl or TerminalController refer to the legacy Swift app in #15570 (cmux-next homes: browser-host.md).

# Site tools (`sites`)

`sites` is the REPL global for site-specific tools: Google Workspace, Gmail,
Calendar, Search, YouTube, Slack, Notion, LinkedIn, X, GitHub, Linear, Jira,
page assets, WebMCP and a secure sign-in handoff, with three rules:

1. **The user's cmux browser session is the only credential.** A tool reads
   through the cookie-bearing REPL `fetch` (Google's export endpoints,
   YouTube, GitHub `.diff`/`/raw/`) or in a background tab of the same
   profile, where its code runs in the page's own world against the site's
   own origin. A token a site keeps in the page (Slack's `xoxc-` token in
   `localStorage`, LinkedIn's CSRF cookie) is used inside that page and never
   returned to the REPL.
2. **Reads run directly. Writes that reach other people are drafts.**
   `sites.gmail.send(message)` returns a draft (what will be sent, to whom,
   from which account, and the confirmation category it falls under).
   Nothing happens until `sites.gmail.send(draft.id, { confirm: true })`.
   cmux enforces this in the API, not as policy text
   ([confirmation taxonomy](#confirmation-taxonomy)): a write without a draft id is a draft, `{ confirm: true }` without a
   draft id is an error, a draft is single-use, expires after 30 minutes and
   lives only in the REPL session that made it.
3. **Failures say what to do.** A tab that reaches a sign-in page (at load or
   later from script) fails with `not_signed_in` and names the fix; a CAPTCHA
   is reported, never solved; a wrong Google account is an HTTP 403 that names
   the `{ uid }` option.

Load order and the hook: `cmux-tui/crates/cmux-browser-host/js/sites/loader.js` defines
`register` and `createSites`; each file in `sites/` registers one tool; the
files are in `manifest.json`'s `repl` list after `api.js`, which builds
`sites` on first use.

```js
// In one named session, so the draft survives until the user answers:
//   cmux browser repl --session mail
const hits = await sites.gmail.search("from:bob has:attachment newer_than:7d");
const thread = await sites.gmail.thread(hits[0].threadId);
const draft = await sites.gmail.send({ threadId: hits[0].threadId, body: "Thanks, looks good." });
draft.preview; // show it to the user; on approval:
await sites.gmail.send(draft.id, { confirm: true });
```

## Inventory

Read and write columns name the method.

| Tool | cmux |
| --- | --- |
| Google accounts | `sites.googleAccounts.list()` (ListAccounts, cookie) |
| Google Docs | `sites.googleDocs.read(url, { format: md/txt/html })`, `.export(url, { format: md/pdf/docx/txt/html/odt/rtf/epub })`; also `page.exportContent({ format })`. Edits: not implemented (decision 6) |
| Google Sheets | `sites.googleSheets.info()`, `.read(url, { gid \| sheet, range })` (whole sheet from the CSV export), `.readAll()`, `.export(xlsx/csv/tsv/pdf/ods)`. Writes: decision 6 |
| Google Slides | `sites.googleSlides.read()` (text), `.export(pptx/pdf/txt/odp)` |
| Google Drive | `sites.googleDrive.download(url)` (uploaded files), `.export(url)` (Google files by Drive URL) |
| Gmail | `sites.gmail.search(q)`, `.inbox()`, `.thread(id, { format })`, `.attachment(id, name)`, `.send(message)` draft, then confirmed send or reply through Gmail's compose window, waiting out Gmail's undo window |
| Google Calendar | `sites.googleCalendar.events({ date, view, query })`, `.create(event)` draft, then confirmed save through the template link (invitations sent only for drafted guests) |
| Google Search | `sites.googleSearch.search(q, { limit, start, language, country, safeSearch, time })`: Google's basic results page through the session (real destination URLs), else the full page in a tab; one query at a time is enforced; CAPTCHA reported |
| YouTube | `sites.youtube.search`, `.metadata`, `.captions`, `.transcript(v, { lang, timestamps, format })` (direct caption URL, else the player's caption request in a muted background tab), `.comments(v, { limit, continuation })`; also `page.exportContent({ transcript: true })` |
| Slack | `sites.slack.workspaces`, `.channels`, `.history(team, "#name")`, `.replies`, `.search`, `.user`, `.call()` (read-only methods only), `.post()` draft; the token stays in the app.slack.com page |
| Notion | `sites.notion.accounts`, `.search`, `.read(url)` (Markdown), `.append(page, markdown)` draft; same-origin calls, the httpOnly cookie never leaves the page |
| LinkedIn | `sites.linkedin.me`, `.profile`, `.search(q, { type })`, `.feed`, `.post(text)` draft. Messages and invitations: decision 7 |
| X (Twitter) | `sites.x.user`, `.userTweets`, `.timeline`, `.search`, `.tweet(id)` (post and replies), `.post(text \| { text, replyTo })` draft. Likes, follows, DMs: decision 7 |
| GitHub | `sites.github.issue`, `.pull(ref, { diff })`, `.diff`, `.issues(repo, { query, pulls })`, `.file(repo, path, { ref })`; private repositories through the session |
| Linear | `sites.linear.viewer`, `.issue`, `.search`, `.assigned`, `.query()` (read-only GraphQL) |
| Jira | `sites.jira.issue` (description and comments as Markdown), `.search(jql, { site })`, `.me` |
| Other site guides (Airtable, Amazon, Asana, ClickUp, Confluence, Discord, Google Forms, Trello, Notion UI) | none: they are hints, not tools; `snapshot()` and Playwright drive these sites |
| Page assets | `sites.pageAssets.list(page?)`, `.bundle(inventory, { kinds, assetIds, dir })`; also writes inline SVGs and fetches through the session |
| WebMCP | `sites.webmcp.tools(page?)`, `.call(name, input)`; WebKit has no WebMCP, so only tools a page registers with its own implementation; non-read-only tools are drafts |
| Secure sign-in | `sites.browserAuth.request(page?, { origin, fields, submit })`: a cmux sheet collects the values and the app fills them; sign-in method choice (`options`) and QR are not implemented |
| Background content | `tabs.content({ urls, format })` (not in `sites`) |
| History | `tabs.history({ query, from, to, limit })` over cmux history |
| Claim user tabs | `tabs.list({ all: true })`, `tabs.use(id)` |
| Bot detection | CAPTCHA and sign-in blocks are errors with codes; no telemetry |
| CAPTCHA | not implemented (decision 1) |
| Password managers | not implemented (decision 2) |
| iMessage, KakaoTalk | not implemented (decision 3) |
| Image generation, image search | not implemented (decision 4) |
| Documents (pdf, docx, pptx, xlsx) | not a browser tool; exports above write the files |
| Chrome APIs (bookmarks, tab groups, downloads, top sites) | not applicable to cmux's WebKit browser |

## Methods

Common options: Google tools take `uid` (the `/u/{uid}/` account index from
`sites.googleAccounts.list()`; a URL's `/u/N/` is used when present). Output
files go to `options.path`, else the session's temporary directory. Every
error is a `SiteError` with a `code`: `invalid`, `not_signed_in`,
`not_found`, `forbidden`, `timeout`, `captcha`, `consent_required`,
`no_captions`, `confirm_required`, `draft_required`, `draft_not_found`,
`draft_used`, `draft_expired`, `compose_mismatch`, `write_requires_draft`,
`unsupported`.

| Method | Mechanism | Kind |
| --- | --- | --- |
| `googleAccounts.list()` | POST accounts.google.com/ListAccounts (cookie) | read |
| `googleDocs.read(url, { format, uid })`, `.export(url, { format, path, uid })` | docs.google.com `/export?format=` (cookie) | read |
| `googleSheets.info(url)`, `.read(url, { gid, sheet, range })`, `.readAll(url)`, `.export(url, { format, gid })` | `/htmlview` for sheet names, `/export?format=csv&gid=` | read |
| `googleSlides.read(url)`, `.export(url, { format })` | `/export?format=` | read |
| `googleDrive.download(url)`, `.export(url, { kind, format })` | drive.usercontent.google.com `/download`, Docs export | read |
| `gmail.search(q, { limit, page, uid })`, `.inbox()`, `.thread(id, { format })`, `.attachment(id, name)` | Gmail web app in a background tab: thread rows (`tr.zA`), messages (`.adn`, expanded first), attachment links fetched with the session | read |
| `gmail.send({ to, cc, bcc, subject, body } \| { threadId, body, replyAll })` | draft; confirmed: Gmail compose (`?view=cm`) or the thread's Reply, body checked in the composer, Send, wait for "Message sent" and the undo window | write [9], [14] |
| `googleCalendar.events({ date, view, query, limit })` | Calendar view or search in a background tab; each `[data-eventid]` and its screen-reader description | read |
| `googleCalendar.create({ title, start, end, allDay, description, location, guests, timeZone, recurrence })` | draft; confirmed: `calendar/render?action=TEMPLATE`, Save, Send invitations only when the draft has guests | write [9], [14] |
| `googleSearch.search(q, options)` | the basic results page from the session's fetch (`/url?q=` links carry the destination), parsed in a blank tab; else the full page in a background tab (`div[data-rpos]` blocks, whose opaque `/goto` links are kept with `displayUrl`) | read |
| `youtube.search`, `.metadata`, `.captions`, `.comments` | desktop watch/results HTML (`ytInitialPlayerResponse`, `ytInitialData`, also as an escaped string), InnerTube `/youtubei/v1/next` | read |
| `youtube.transcript(v, { lang, timestamps, format })` | in order: InnerTube `/youtubei/v1/player` as the IOS, then ANDROID_VR client through the session's fetch (native clients' caption URLs need no player token; YouTube requires one for WEB subtitles, as yt-dlp's PO Token Guide documents), the track read as json3; the same calls from a youtube.com page; the watch page's track URL; last, the player in a muted background tab. A video with no track fails as `no_captions` | read |
| `slack.workspaces()`, `.channels`, `.history`, `.replies`, `.search`, `.user`, `.call(team, readMethod, params)` | Slack Web API from an app.slack.com tab, token from that page's `localStorage` | read |
| `slack.post({ team, channel, text, threadTs })` | draft; confirmed: `chat.postMessage` | write [9] |
| `notion.accounts()`, `.search(q, { spaceId })`, `.read(url)` | `/api/v3` (`getSpaces`, `search`, `loadPageChunk`, `syncRecordValues`) same-origin | read |
| `notion.append(page, markdown)` | draft; confirmed: `saveTransactions` (`set` and `listAfter` per block, after the last block) | write [9] |
| `linkedin.me()`, `.profile(id)` | Voyager API same-origin, CSRF from the page's cookie | read |
| `linkedin.search(q, { type })`, `.feed()` | result and feed cards in a background tab | read |
| `linkedin.post(text)` | draft; confirmed: share composer (`/feed/?shareActive=true&text=`), text checked, Post | write [9] |
| `x.user`, `.userTweets`, `.timeline`, `.search`, `.tweet` | profile and `article[data-testid="tweet"]` cards in a background tab, scrolled for more | read |
| `x.post(text \| { text, replyTo })` | draft; confirmed: Web Intent `/intent/post`, text checked, Post | write [9] |
| `github.issue`, `.pull`, `.issues` | pages in a background tab | read |
| `github.assigned({ issues, pulls, state, limit })` | GitHub's own search (`/search?type=issues`, `assignee:@me`) answering JSON in the session, 10 per page | read |
| `googleDrive.recent({ uid, limit })` | Drive's Recent view in a background tab, rows by `data-id` | read |
| `github.diff`, `.file` | `/pull/N.diff`, `/raw/REF/PATH` with the session | read |
| `linear.*` | client-api.linear.app GraphQL from a linear.app tab with the session | read |
| `jira.*` | `/rest/api/3/issue`, `/search/jql` (falls back to `/search`), `/myself`, same-origin | read |
| `pageAssets.list(page?)`, `.bundle(inv, { kinds, assetIds, dir })` | DOM, computed styles, `@font-face`, resource timing; downloads with the session | read |
| `webmcp.tools(page?)`, `.call(name, input)` | the page's `navigator.modelContext` implementation | read-only tools read; others write |
| `browserAuth.request(page?, { origin, fields, submit })` | native sheet, `sites/auth-fill.js` run by the app | fills user-typed values |
| `sites.list()`, `sites.help(name)`, `sites.drafts.list()/get(id)/discard(id)` | | |

## Editing Google files

Specialized tools for Google Sheets, Docs and Slides: read sheet and cell
contents, update and clear cells, select a cell or range, and more. cmux reads
through the editors' own exports (no selection, no clipboard, whole files
and every tab) and writes with real input into a background tab, then reads
the file back to verify.

| Method | Mechanism | Kind |
| --- | --- | --- |
| `googleSheets.info(url)` | `/htmlview` tab list | read |
| `googleSheets.read(url, { gid, sheet, range })` | CSV export: values | read |
| `googleSheets.cells(url, { sheet, gid, range })` | xlsx export unzipped in a docs.google.com page (`DecompressionStream`): `{ cell, value, formula }` | read |
| `googleSheets.find(url, text)` | the same, every tab | read |
| `googleSheets.write(url, range, rows)` | name box selects the top-left cell, then one Meta+V of the rows as TSV from the tab's clipboard (a trusted `paste` whose `clipboardData` Sheets reads; `=` makes a formula); if the export does not show the values within about 5 s, each value is typed with real keys (Tab between cells, Enter after a row). Verified through the xlsx export | write |
| `googleSheets.append(url, rows)` | the same after the last non-empty row | write |
| `googleSheets.clear(url, range)` | name box selects the range, Delete, verified | write |
| `googleDocs.structure(url)` | HTML export parsed in a blank tab: headings with levels, paragraphs, lists, tables | read |
| `googleDocs.replace(url, find, replacement)` | Find and replace (Meta+Shift+H), Replace all, verified through the text export | write |
| `googleDocs.insertAfter(url, anchor, text)` | the same with `anchor` -> `anchor + text`; the anchor must occur exactly once | write |
| `googleDocs.append(url, text)` | end of document (Meta+ArrowDown), Enter, typed text, verified | write |
| `googleSlides.slides(url)` | pptx export: `{ index, title, text, notes }` per slide | read |
| `googleSlides.setNotes(url, slide, text)` | the slide's filmstrip thumbnail (`g#filmstrip-slide-<n>-<page>`), the speaker notes box, old notes selected (Meta+ArrowUp, Meta+Shift+ArrowDown) and deleted, new notes typed; verified through the pptx export | write |
| `googleSlides.replace(url, find, replacement)` | Find and replace, verified through the pptx export | write |
| `googleDrive.create(kind, title)` | `docs.google.com/<kind>/create`, then the title field | creates a private file |
| `googleDrive.trash(url)` | the editor's File > Move to trash | delete |

Rule for writes (confirmation category [9], edits others can see):
a write first opens the file's editor and reads its Share button. If it
says "Private to only me", nobody else sees the edit and it runs at once.
Otherwise, including when the sharing cannot be read, the write returns a
draft with the file, its title, the sharing text and the change, and runs
only on `method(draftId, { confirm: true })`. `googleDrive.trash` deletes
data ([1]): it is a draft, except for a file `googleDrive.create` made in
the same REPL session.

## Confirmation taxonomy

Browser actions fall into
"hand-off required", "always confirm at action time", "pre-approval works"
and "no confirmation". Every cmux write is in "always confirm": [9]
representational communication (mail, messages, posts, events, page edits)
and [14] transmitting data to a third party. Each draft names its category.
cmux has no delete, share, permission, purchase or account-creation tool;
those stay with the agent driving the page under the policy, and are listed
as decisions below. `{ confirm: true }` is the agent's statement that the
user approved this exact preview; the API cannot see the user, so it makes
the preview and the second call unavoidable and makes approval impossible to
skip by accident.

## Secure sign-in

`sites.browserAuth.request({ origin, fields, submit })` checks that each
selector is one visible, enabled text field in the tab's origin and that all
are in one frame, marks them with a random attribute, and calls the driver's
`auth.request`. The app shows a sheet on the browser pane's window with the
origin and one field per request (secure text for passwords). On Fill, the
app runs `sites/auth-fill.js` in the agent content world of that frame: it
sets each value with the native setter and dispatches `input` and `change`,
so framework-controlled fields see it. The REPL receives only a status:
`submitted`, `cancelled`, `unavailable`, `expired`, `origin_changed`,
`page_changed`, `locator_invalid` or `submission_failed`. The fill script is
read from the signed app bundle, never from the REPL, so an agent cannot
substitute code that receives the values.

## Decisions for the user

These are not implemented and need a decision:

1. **CAPTCHA solving.** cmux reports `captcha` and stops.
2. **Third-party password managers.** Reading or autofilling 1Password,
   Bitwarden, Dashlane, LastPass, Proton Pass or Apple Passwords puts vault
   access behind an agent. `browserAuth` covers sign-in without it.
3. **iMessage, SMS and KakaoTalk.** Not browser operations; they read local
   message databases and send as the user.
4. **Image generation and image search.** Not browser operations; image
   generation needs an API credential.
5. **Bot-detection evasion.** Not implemented; cmux does not disguise
   automation.
6. **Google Docs and Sheets editing beyond the tools above.** A cmux version would be a draft of the diff,
   confirmed, applied with real input in the document tab.
7. **More social writes.** LinkedIn messages and invitations, X likes,
   follows, reposts and DMs: each is [9] or [14]; the draft mechanism supports
   them, but each adds a way to act as the user in public.
8. **Native approval for writes.** A cmux sheet showing the draft, with
   Send and Cancel, would make approval the user's click instead of the
   agent's `{ confirm: true }`.
9. **Sign-in method choice and QR codes** in `browserAuth`.
10. **Contacts.** cmux has no contacts tool for the user's address book.

## Tests

`tests/browser-parity/sites/` runs every tool on the Playwright WebKit dev
driver against `mock-sites.mjs`: one handler per host that answers the
endpoints and page structure each tool relies on, with shapes from each
site's public documentation or public pages and synthetic data. Real hosts
are routed to the mock in the browser and in the REPL's `fetch`; any other
https request is blocked. Each host checks the session the way the site does,
so the tests prove the tools use the session, keep secrets in the page (the
REPL scope is scanned for them), write only after a confirmed draft, and
report sign-in pages.

```sh
node --test tests/browser-parity/sites/*.test.mjs
tests/browser-parity/gate.sh   # includes it
```

Live smoke checklist, read-only and public pages only, run once on a tagged
app build:

1. `await sites.youtube.search("rick astley never gonna give you up", { limit: 3 })`
2. `await sites.youtube.metadata("dQw4w9WgXcQ")` and `.captions(...)`
3. `(await sites.youtube.transcript("dQw4w9WgXcQ", { timestamps: true })).slice(0, 200)`
4. `(await sites.youtube.comments("dQw4w9WgXcQ", { limit: 3 })).comments.length`
5. `await sites.googleSearch.search("webkit content world", { limit: 3 })`
6. `await sites.github.issue("https://github.com/microsoft/playwright/issues/1")`
7. `(await sites.github.diff("https://github.com/microsoft/playwright/pull/1")).slice(0, 200)`
8. On `https://example.com`: `await sites.pageAssets.list()` and `await sites.webmcp.tools()`

Result of that run on `brepl-sites1` (commit be5988f070e): every item
returned real data. It found three things the first mocks did not model,
now in the mocks and fixed: the REPL's fetch gets YouTube's mobile site and
Google's basic results page, a tab gets Google's opaque `/goto` links, and
YouTube's player token makes the direct caption URL empty.

Transcript reliability, 3 public videos (manual English captions
`dQw4w9WgXcQ`, auto-generated Korean only `9bZkp7q19f0`, Spanish with
`{ lang: "es" }` `kJQP7kiw5Fk`): cmux with the native-client path 30/30
(10 runs each, about 300 ms).


Tools against private accounts (Gmail, Calendar, Slack, Notion, LinkedIn, X
timelines, Linear, Jira) are verified only against the mocks: running them
live reads the user's private data. Their page selectors follow the sites'
current markup and will need updates when the sites change it; each such
failure is a `timeout` naming what it waited for.

# Site tools (`sites`)

`sites` is the REPL global for site-specific tools: Google Workspace, Gmail,
Calendar, Search, YouTube, Slack, Notion, LinkedIn, X, GitHub, Linear, Jira,
page assets, WebMCP and a secure sign-in handoff. It covers what Aside's REPL
integrations and ChatGPT for Chrome's site capabilities offer, with three
rules neither reference enforces together:

1. **The user's cmux browser session is the only credential.** A tool reads
   through the cookie-bearing REPL `fetch` (Google's export endpoints,
   YouTube, GitHub `.diff`/`/raw/`) or in a background tab of the same
   profile, where its code runs in the page's own world against the site's
   own origin. A token a site keeps in the page (Slack's `xoxc-` token in
   `localStorage`, LinkedIn's CSRF cookie) is used inside that page and never
   returned. Aside's `slack.getClient()` and `notion.getClient()` extract
   the token into the REPL; its `imagegen` object printed OAuth tokens in a
   probe.
2. **Reads run directly. Writes that reach other people are drafts.**
   `sites.gmail.send(message)` returns a draft (what will be sent, to whom,
   from which account, and the ChatGPT confirmation category it falls under).
   Nothing happens until `sites.gmail.send(draft.id, { confirm: true })`.
   Aside's `slack` client posts, `twitter.tweet()` posts and `gmail` compose
   pages send with no gate; ChatGPT for Chrome has the rule only as policy
   text ([confirmations.md](#confirmation-taxonomy)). cmux enforces it in the
   API: a write without a draft id is a draft, `{ confirm: true }` without a
   draft id is an error, a draft is single-use, expires after 30 minutes and
   lives only in the REPL session that made it.
3. **Failures say what to do.** A tab that reaches a sign-in page (at load or
   later from script) fails with `not_signed_in` and names the fix; a CAPTCHA
   is reported, never solved; a wrong Google account is an HTTP 403 that names
   the `{ uid }` option.

Load order and the hook: `Resources/browser-repl/sites/loader.js` defines
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

Aside is `aside skills show <name>` plus its hidden builtin skills and REPL
globals (Aside CLI 1.26.916); ChatGPT is the Chrome plugin's `docs/`,
`docs/api.json` and `scripts/browser-service.mjs`. Read and write columns
name the method; "guide" means the reference only documents URLs and
shortcuts for the agent to drive by hand.

| Tool | Aside | ChatGPT for Chrome | cmux |
| --- | --- | --- | --- |
| Google accounts | `googleAccounts.list/print` (cookie HTTP) | none | `sites.googleAccounts.list()` (ListAccounts, cookie) |
| Google Docs | `googleDocs.getDocumentHTML/Text` (cookie); edits by clipboard paste and select-by-index in a tab (`applyDiffs`, suggestions, comments) | `content.exportGsuite(pdf/md/docx)` | `sites.googleDocs.read(url, { format: md/txt/html })`, `.export(url, { format: md/pdf/docx/txt/html/odt/rtf/epub })`; also `page.exportContent({ format })`. Edits: not implemented (decision 6) |
| Google Sheets | `googleSheets.getSpreadsheetInfo/readSheet/readAllSheets` (first HTML chunk, can omit rows); `writeMatrix/setNote/addComment` in a tab | `exportGsuite(xlsx/csv/pdf)` | `sites.googleSheets.info()`, `.read(url, { gid \| sheet, range })` (whole sheet from the CSV export), `.readAll()`, `.export(xlsx/csv/tsv/pdf/ods)`. Writes: decision 6 |
| Google Slides | guide | `exportGsuite(pdf/pptx)` | `sites.googleSlides.read()` (text), `.export(pptx/pdf/txt/odp)` |
| Google Drive | guide | none | `sites.googleDrive.download(url)` (uploaded files), `.export(url)` (Google files by Drive URL) |
| Gmail | `gmail.search/getInbox/getThread` (internal sync API), `openComposer/openReplyComposer` (sends by clicking, no gate), `downloadAttachment` | none | `sites.gmail.search(q)`, `.inbox()`, `.thread(id, { format })`, `.attachment(id, name)`, `.send(message)` draft, then confirmed send or reply through Gmail's compose window, waiting out Gmail's undo window |
| Google Calendar | guide (event template URL) | none | `sites.googleCalendar.events({ date, view, query })`, `.create(event)` draft, then confirmed save through the template link (invitations sent only for drafted guests) |
| Google Search | `googleSearch.search` (cookie fetch, DOM parse; documents "do not run in parallel") | none | `sites.googleSearch.search(q, { limit, start, language, country, safeSearch, time })`: Google's basic results page through the session (real destination URLs), else the full page in a tab; one query at a time is enforced; CAPTCHA reported |
| YouTube | `youtube.search/getMetadata/listTranscriptLanguages/getTranscript/getComments` | `content.exportYouTubeTranscript()` (turns captions on in the player, reads the caption URL it requests) | `sites.youtube.search`, `.metadata`, `.captions`, `.transcript(v, { lang, timestamps, format })` (direct caption URL, else ChatGPT's player method in a muted background tab), `.comments(v, { limit, continuation })`; also `page.exportContent({ transcript: true })` |
| Slack | `slack.listWorkspaces`, `slack.getClient()` returns a full `@slack/web-api` client holding the token (every method, posts with no gate) | none | `sites.slack.workspaces`, `.channels`, `.history(team, "#name")`, `.replies`, `.search`, `.user`, `.call()` (read-only methods only), `.post()` draft; the token stays in the app.slack.com page |
| Notion | `notion.getClient()` (extracts `token_v2`; full client with deletes and moves) | none | `sites.notion.accounts`, `.search`, `.read(url)` (Markdown), `.append(page, markdown)` draft; same-origin calls, the httpOnly cookie never leaves the page |
| LinkedIn | `linkedin.getMe/getProfile/searchPeople/searchCompanies/getCompany/getJob/getUserPosts/getInbox/getConversation/sendMessage/sendInvitation/accept/ignore/withdraw` (no gate) | none | `sites.linkedin.me`, `.profile`, `.search(q, { type })`, `.feed`, `.post(text)` draft. Messages and invitations: decision 7 |
| X (Twitter) | `twitter.getMe/getUser/getTweet/getTweetThread/getTimeline/search/getUserTweets/getBookmarks/tweet/reply/like/retweet/follow/DMs/block/mute` (no gate) | none | `sites.x.user`, `.userTweets`, `.timeline`, `.search`, `.tweet(id)` (post and replies), `.post(text \| { text, replyTo })` draft. Likes, follows, DMs: decision 7 |
| GitHub | guide | none | `sites.github.issue`, `.pull(ref, { diff })`, `.diff`, `.issues(repo, { query, pulls })`, `.file(repo, path, { ref })`; private repositories through the session |
| Linear | guide | none | `sites.linear.viewer`, `.issue`, `.search`, `.assigned`, `.query()` (read-only GraphQL) |
| Jira | guide | none | `sites.jira.issue` (description and comments as Markdown), `.search(jql, { site })`, `.me` |
| Other site guides (Airtable, Amazon, Asana, ClickUp, Confluence, Discord, Google Forms, Trello, Notion UI) | guide | none | none: they are hints, not tools; `snapshot()` and Playwright drive these sites |
| Page assets | none | `pageAssets.list()`, `.bundle({ inventoryId, kinds, assetIds })` | `sites.pageAssets.list(page?)`, `.bundle(inventory, { kinds, assetIds, dir })`; also writes inline SVGs and fetches through the session |
| WebMCP | none | `webmcp.fetchTools()`, `tools.call()` (Chrome's `document.modelContext`) | `sites.webmcp.tools(page?)`, `.call(name, input)`; WebKit has no WebMCP, so only tools a page registers with its own implementation; non-read-only tools are drafts |
| Secure sign-in | password managers fill by ref | `browserAuth.request({ origin, fields, options, submit })` | `sites.browserAuth.request(page?, { origin, fields, submit })`: a cmux sheet collects the values and the app fills them; sign-in method choice (`options`) and QR are not implemented |
| Background content | none | `tabs.content({ urls })` | `tabs.content({ urls, format })` (not in `sites`) |
| History | `chrome.history` | `browser.history()` | `tabs.history({ query, from, to, limit })` over cmux history |
| Claim user tabs | `listBrowserTabs`, `attachBrowserTab` | `user.openTabs()`, `user.claimTab()` | `tabs.list({ all: true })`, `tabs.use(id)` |
| Bot detection | none | `botDetection.report({ reason })` (cloud telemetry) | CAPTCHA and sign-in blocks are errors with codes; no telemetry |
| CAPTCHA | `captcha.click/drag/readText` | policy: confirm before solving | not implemented (decision 1) |
| Password managers | Aside Vault, 1Password, Bitwarden, Dashlane, LastPass, Proton Pass, Apple Passwords (read, autofill, save) | none | not implemented (decision 2) |
| iMessage, KakaoTalk | `imessage.*` (read, send), `kakaotalk.*` (read) | none | not implemented (decision 3) |
| Image generation, image search | `imagegen.*`, `imageSearch.search` | none | not implemented (decision 4) |
| Documents (pdf, docx, pptx, xlsx) | skills for local files | none | not a browser tool; exports above write the files |
| Chrome APIs (bookmarks, tab groups, downloads, top sites) | `chrome.*` | none | not applicable to cmux's WebKit browser |

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
| `youtube.transcript(v, { lang, timestamps, format })` | caption track URL as json3; when it needs the player's token (YouTube in 2026: the direct URL is empty), a muted background watch tab turns captions on and the tool reads the caption response the player itself receives (json3, srv3 or XML), in short page calls | read |
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
| `github.diff`, `.file` | `/pull/N.diff`, `/raw/REF/PATH` with the session | read |
| `linear.*` | client-api.linear.app GraphQL from a linear.app tab with the session | read |
| `jira.*` | `/rest/api/3/issue`, `/search/jql` (falls back to `/search`), `/myself`, same-origin | read |
| `pageAssets.list(page?)`, `.bundle(inv, { kinds, assetIds, dir })` | DOM, computed styles, `@font-face`, resource timing; downloads with the session | read |
| `webmcp.tools(page?)`, `.call(name, input)` | the page's `navigator.modelContext` implementation | read-only tools read; others write |
| `browserAuth.request(page?, { origin, fields, submit })` | native sheet, `sites/auth-fill.js` run by the app | fills user-typed values |
| `sites.list()`, `sites.help(name)`, `sites.drafts.list()/get(id)/discard(id)` | | |

## Confirmation taxonomy

ChatGPT for Chrome's `docs/confirmations.md` sorts browser actions into
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

1. **CAPTCHA solving.** Aside solves by clicking, dragging and OCR; ChatGPT's
   policy requires confirmation at action time. cmux reports `captcha` and
   stops.
2. **Third-party password managers.** Reading or autofilling 1Password,
   Bitwarden, Dashlane, LastPass, Proton Pass or Apple Passwords puts vault
   access behind an agent. `browserAuth` covers sign-in without it.
3. **iMessage, SMS and KakaoTalk.** Not browser operations; they read local
   message databases and send as the user.
4. **Image generation and image search.** Not browser operations; image
   generation needs an API credential.
5. **Bot-detection evasion.** Not implemented; ChatGPT's `botDetection` is
   telemetry, and cmux does not disguise automation.
6. **Google Docs and Sheets editing.** Aside edits by clipboard paste and
   index-mapped selection. A cmux version would be a draft of the diff,
   confirmed, applied with real input in the document tab.
7. **More social writes.** LinkedIn messages and invitations, X likes,
   follows, reposts and DMs: each is [9] or [14]; the draft mechanism supports
   them, but each adds a way to act as the user in public.
8. **Native approval for writes.** A cmux sheet showing the draft, with
   Send and Cancel, would make approval the user's click instead of the
   agent's `{ confirm: true }`.
9. **Sign-in method choice and QR codes** in `browserAuth` (ChatGPT's
   `options` and `qr_code`).

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

Tools against private accounts (Gmail, Calendar, Slack, Notion, LinkedIn, X
timelines, Linear, Jira) are verified only against the mocks: running them
live reads the user's private data. Their page selectors follow the sites'
current markup and will need updates when the sites change it; each such
failure is a `timeout` naming what it waited for.

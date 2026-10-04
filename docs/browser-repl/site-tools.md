# Site tools (`sites`)

`sites` is the REPL global for site-specific tools: Google Workspace, Gmail,
Calendar, Search, YouTube, Slack, Notion, LinkedIn, X, GitHub, Linear, Jira,
page assets, WebMCP and a secure sign-in handoff. It covers what reference A's REPL
integrations and reference B's site capabilities offer, with three
rules neither reference enforces together:

1. **The user's cmux browser session is the only credential.** A tool reads
   through the cookie-bearing REPL `fetch` (Google's export endpoints,
   YouTube, GitHub `.diff`/`/raw/`) or in a background tab of the same
   profile, where its code runs in the page's own world against the site's
   own origin. A tool that runs in a site's origin loads a bootstrap page
   there (`/robots.txt`) and runs nothing when a redirect left that origin:
   the call fails with `origin_changed` when the tab's URL is elsewhere, and
   each evaluation first checks its document's own `location.origin`.
   A token a site keeps in the page (Slack's `xoxc-` token in
   `localStorage`, LinkedIn's CSRF cookie) is used inside that page and never
   returned. Reference A's `slack.getClient()` and `notion.getClient()` extract
   the token into the REPL; its `imagegen` object printed OAuth tokens in a
   probe.
2. **Reads run directly. Writes that reach other people are drafts.**
   `sites.gmail.send(message)` returns a draft (what will be sent, to whom,
   from which account, and the reference B confirmation category it falls under).
   Nothing happens until `sites.gmail.send(draft.id, { confirm: true })`.
   Reference A's `slack` client posts, `twitter.tweet()` posts and `gmail` compose
   pages send with no gate; reference B has the rule only as policy
   text ([confirmations.md](#confirmation-taxonomy)). cmux enforces it in the
   API: a write without a draft id is a draft, `{ confirm: true }` without a
   draft id is an error, a draft is single-use, expires after 30 minutes and
   lives only in the REPL session that made it. The tool copies its input
   when it makes the draft, and the draft it returns is a frozen copy with
   a frozen preview, so changing the input object, the draft or its preview
   afterwards changes nothing: the confirmed call performs the action the
   preview showed. The status and expiry the confirm step checks stay in the
   session; `sites.drafts.get(id)` reads the current status.
   The draft also names its destination and sending account concretely,
   resolved when it is made, and the confirmed call acts only there, so a
   change of shared browser state another session can make between the
   preview and the confirmation never redirects it: a Slack draft holds the
   workspace and channel ids and the member's user id (`team` omitted means
   Slack's last-active workspace at draft time, a `#name` the channel it
   named then), Gmail and Calendar drafts the account's email for their
   `/u/` index, a Gmail reply the ids of the thread's messages, LinkedIn
   and X drafts the signed-in member or user id, and a Notion draft the
   Notion user (`{ userId }`, or the one user the session holds; with
   several, the draft fails as `invalid` until `{ userId }` names one). When the account at that index, the
   signed-in account or the replied thread has changed, the confirmation
   fails with `account_changed` or `thread_changed` and sends nothing; make
   a new draft. The account is checked again where the write happens,
   right before it, since another session can switch the shared profile's
   account while the composer loads: Slack posts in one page call that
   runs `auth.test` with the same token first (a token names one member);
   Gmail and Calendar read the account the compose, thread or event page
   is signed in as (its title, its Google Account button) right before
   Send or Save, and fail closed with `account_unknown`, sending nothing, when the page names no account; LinkedIn and
   X read the member in the composer page right before Post; Notion checks
   the session's users and then reads and writes with
   `x-notion-active-user-header` set to the drafted user, so Notion runs
   the write as that user or refuses it. The remaining window is between
   that last check and the click (Gmail, Calendar, LinkedIn, X), which no
   site API closes: none binds a click to an account. Drive, Docs, Sheets
   and Slides drafts name the file by id (see "Editing Google files" for
   what else they bind), and a WebMCP draft fails when its tab left the
   previewed URL or the page's tool changed (see "WebMCP calls").
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

Reference A is its skill listing plus its hidden builtin skills and REPL
globals (reference A CLI 1.26.916); reference B is the Chrome plugin's `docs/`,
`docs/api.json` and `scripts/browser-service.mjs`. Read and write columns
name the method; "guide" means the reference only documents URLs and
shortcuts for the agent to drive by hand.

| Tool | Reference A | Reference B | cmux |
| --- | --- | --- | --- |
| Google accounts | `googleAccounts.list/print` (cookie HTTP) | none | `sites.googleAccounts.list()` (ListAccounts, cookie) |
| Google Docs | `googleDocs.getDocumentHTML/Text` (cookie); edits by clipboard paste and select-by-index in a tab (`applyDiffs`, suggestions, comments) | `content.exportGsuite(pdf/md/docx)` | `sites.googleDocs.read(url, { format: md/txt/html })`, `.export(url, { format: md/pdf/docx/txt/html/odt/rtf/epub })`; also `page.exportContent({ format })`. Edits: not implemented (decision 6) |
| Google Sheets | `googleSheets.getSpreadsheetInfo/readSheet/readAllSheets` (first HTML chunk, can omit rows); `writeMatrix/setNote/addComment` in a tab | `exportGsuite(xlsx/csv/pdf)` | `sites.googleSheets.info()`, `.read(url, { gid \| sheet, range })` (whole sheet from the CSV export), `.readAll()`, `.export(xlsx/csv/tsv/pdf/ods)`. Writes: decision 6 |
| Google Slides | guide | `exportGsuite(pdf/pptx)` | `sites.googleSlides.read()` (text), `.export(pptx/pdf/txt/odp)` |
| Google Drive | guide | none | `sites.googleDrive.download(url)` (uploaded files), `.export(url)` (Google files by Drive URL) |
| Gmail | `gmail.search/getInbox/getThread` (internal sync API), `openComposer/openReplyComposer` (sends by clicking, no gate), `downloadAttachment` | none | `sites.gmail.search(q)`, `.inbox()`, `.thread(id, { format })`, `.attachment(id, name)`, `.send(message)` draft, then confirmed send or reply through Gmail's compose window, waiting out Gmail's undo window |
| Google Calendar | guide (event template URL) | none | `sites.googleCalendar.events({ date, view, query })`, `.create(event)` draft, then confirmed save through the template link (invitations sent only for drafted guests) |
| Google Search | `googleSearch.search` (cookie fetch, DOM parse; documents "do not run in parallel") | none | `sites.googleSearch.search(q, { limit, start, language, country, safeSearch, time })`: Google's basic results page through the session (real destination URLs), else the full page in a tab; one query at a time is enforced; CAPTCHA reported |
| YouTube | `youtube.search/getMetadata/listTranscriptLanguages/getTranscript/getComments` | `content.exportYouTubeTranscript()` (turns captions on in the player, reads the caption URL it requests) | `sites.youtube.search`, `.metadata`, `.captions`, `.transcript(v, { lang, timestamps, format })` (direct caption URL, else reference B's player method in a muted background tab), `.comments(v, { limit, continuation })`; also `page.exportContent({ transcript: true })` |
| Slack | `slack.listWorkspaces`, `slack.getClient()` returns a full `@slack/web-api` client holding the token (every method, posts with no gate) | none | `sites.slack.workspaces`, `.channels`, `.history(team, "#name")`, `.replies`, `.search`, `.user`, `.call()` (read-only methods only), `.post()` draft; the token stays in the app.slack.com page |
| Notion | `notion.getClient()` (extracts `token_v2`; full client with deletes and moves) | none | `sites.notion.accounts`, `.search`, `.read(url)` (Markdown), `.append(page, markdown)` draft; same-origin calls, the httpOnly cookie never leaves the page |
| LinkedIn | `linkedin.getMe/getProfile/searchPeople/searchCompanies/getCompany/getJob/getUserPosts/getInbox/getConversation/sendMessage/sendInvitation/accept/ignore/withdraw` (no gate) | none | `sites.linkedin.me`, `.profile`, `.search(q, { type })`, `.feed`, `.post(text)` draft. Messages and invitations: decision 7 |
| X (Twitter) | `twitter.getMe/getUser/getTweet/getTweetThread/getTimeline/search/getUserTweets/getBookmarks/tweet/reply/like/retweet/follow/DMs/block/mute` (no gate) | none | `sites.x.user`, `.userTweets`, `.timeline`, `.search`, `.tweet(id)` (post and replies), `.post(text \| { text, replyTo })` draft. Likes, follows, DMs: decision 7 |
| GitHub | guide | none | `sites.github.issue`, `.pull(ref, { diff })`, `.diff`, `.issues(repo, { query, pulls })`, `.file(repo, path, { ref })`; private repositories through the session |
| Linear | guide | none | `sites.linear.viewer`, `.issue`, `.search`, `.assigned`, `.query(text, variables, { operationName })` (read-only GraphQL) |
| Jira | guide | none | `sites.jira.issue` (description and comments as Markdown), `.search(jql, { site })`, `.me` |
| Other site guides (Airtable, Amazon, Asana, ClickUp, Confluence, Discord, Google Forms, Trello, Notion UI) | guide | none | none: they are hints, not tools; `snapshot()` and Playwright drive these sites |
| Page assets | none | `pageAssets.list()`, `.bundle({ inventoryId, kinds, assetIds })` | `sites.pageAssets.list(page?)`, `.bundle(inventory, { kinds, assetIds, dir })`; also writes inline SVGs and fetches through the session |
| WebMCP | none | `webmcp.fetchTools()`, `tools.call()` (Chrome's `document.modelContext`) | `sites.webmcp.tools(page?)`, `.call(name, input, { trustReadOnlyHint })`; WebKit has no WebMCP, so only tools a page registers with its own implementation; every call is a draft (see "WebMCP calls") |
| Secure sign-in | password managers fill by ref | `browserAuth.request({ origin, fields, options, submit })` | `sites.browserAuth.request(page?, { origin, fields, submit })`: a cmux sheet collects the values and the app fills them; sign-in method choice (`options`) and QR are not implemented |
| Background content | none | `tabs.content({ urls })` | `tabs.content({ urls, format })` (not in `sites`) |
| History | `chrome.history` | `browser.history()` | `tabs.history({ query, from, to, limit })` over cmux history |
| Claim user tabs | `listBrowserTabs`, `attachBrowserTab` | `user.openTabs()`, `user.claimTab()` | `tabs.list({ all: true })`, `tabs.use(id)` |
| Bot detection | none | `botDetection.report({ reason })` (cloud telemetry) | CAPTCHA and sign-in blocks are errors with codes; no telemetry |
| CAPTCHA | `captcha.click/drag/readText` | policy: confirm before solving | not implemented (decision 1) |
| Password managers | Reference A's own vault, 1Password, Bitwarden, Dashlane, LastPass, Proton Pass, Apple Passwords (read, autofill, save) | none | not implemented (decision 2) |
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
`draft_mismatch`, `draft_used`, `draft_expired`, `draft_changed`,
`compose_mismatch`, `account_changed`, `account_unknown`, `thread_changed`,
`tool_changed`, `sharing_changed`, `document_changed`, `sheet_changed`,
`slide_changed`, `origin_changed`, `write_requires_draft`, `unsupported`.

| Method | Mechanism | Kind |
| --- | --- | --- |
| `googleAccounts.list()` | POST accounts.google.com/ListAccounts (cookie) | read |
| `googleDocs.read(url, { format, uid })`, `.export(url, { format, path, uid })` | docs.google.com `/export?format=` (cookie) | read |
| `googleSheets.info(url)`, `.read(url, { gid, sheet, range })`, `.readAll(url)`, `.export(url, { format, gid })` | `/htmlview` for sheet names, `/export?format=csv&gid=` | read |
| `googleSlides.read(url)`, `.export(url, { format })` | `/export?format=` | read |
| `googleDrive.download(url)`, `.export(url, { kind, format })` | drive.usercontent.google.com `/download`, Docs export | read |
| `gmail.search(q, { limit, page, uid })`, `.inbox()`, `.thread(id, { format })`, `.attachment(id, name)` | Gmail web app in a background tab: thread rows (`tr.zA`), messages (`.adn`, expanded first); attachments are Gmail's attachment chips (`.aQH`, `.aZo`, never a link in the message body) whose link is Gmail's own `https://mail.google.com/mail/...view=att` URL, fetched with the session | read |
| `gmail.send({ to, cc, bcc, subject, body } \| { threadId, body, replyAll })` | draft; confirmed: Gmail compose (`?view=cm`) or the thread's Reply, body checked in the composer, the page's account checked against the drafted email, Send, wait for "Message sent" and the undo window | write [9], [14] |
| `googleCalendar.events({ date, view, query, limit })` | Calendar view or search in a background tab; each `[data-eventid]` and its screen-reader description | read |
| `googleCalendar.create({ title, start, end, allDay, description, location, guests, timeZone, recurrence })` | draft; confirmed: `calendar/render?action=TEMPLATE`, the event page's account checked against the drafted email, Save, Send invitations only when the draft has guests | write [9], [14] |
| `googleSearch.search(q, options)` | the basic results page from the session's fetch (`/url?q=` links carry the destination), parsed in a blank tab; else the full page in a background tab (`div[data-rpos]` blocks, whose opaque `/goto` links are kept with `displayUrl`) | read |
| `youtube.search`, `.metadata`, `.captions`, `.comments` | desktop watch/results HTML (`ytInitialPlayerResponse`, `ytInitialData`, also as an escaped string), InnerTube `/youtubei/v1/next` | read |
| `youtube.transcript(v, { lang, timestamps, format })` | in order: InnerTube `/youtubei/v1/player` as the IOS, then ANDROID_VR client through the session's fetch (native clients' caption URLs need no player token; YouTube requires one for WEB subtitles, as yt-dlp's PO Token Guide documents), the track read as json3; the same calls from a youtube.com page; the watch page's track URL; last, the player in a muted background tab. A caption URL is fetched only when it is https on `www.youtube.com`, `m.youtube.com` or `youtube.com` (track URLs come from page data); other tracks are skipped. A video with no track fails as `no_captions` | read |
| `slack.workspaces()`, `.channels`, `.history`, `.replies`, `.search`, `.user`, `.call(team, readMethod, params)` | Slack Web API from an app.slack.com tab, token from that page's `localStorage` | read |
| `slack.post({ team, channel, text, threadTs })` | draft with the workspace, member and channel ids and names; confirmed: one page call that runs `auth.test` with that workspace's token and, when it is the drafted member, `chat.postMessage` to those ids with the same token | write [9] |
| `notion.accounts()`, `.search(q, { spaceId })`, `.read(url)` | `/api/v3` (`getSpaces`, `search`, `loadPageChunk`, `syncRecordValues`) same-origin, on `app.notion.com`, else `www.notion.so`; `{ origin }` pins one of those two exactly and refuses any other | read |
| `notion.append(page, markdown, { userId })` | draft naming the Notion user; confirmed: `getSpaces` must still hold that user, then `syncRecordValues` and `saveTransactions` (`set` and `listAfter` per block, after the last block) with `x-notion-active-user-header` set to that user | write [9] |
| `linkedin.me()`, `.profile(id)` | Voyager API same-origin, CSRF from the page's cookie | read |
| `linkedin.search(q, { type })`, `.feed()` | result and feed cards in a background tab | read |
| `linkedin.post(text)` | draft naming the member id and public identifier; confirmed: share composer (`/feed/?shareActive=true&text=`), text checked, the member checked in that page (Voyager `/me`), Post | write [9] |
| `x.user`, `.userTweets`, `.timeline`, `.search`, `.tweet` | profile and `article[data-testid="tweet"]` cards in a background tab, scrolled for more | read |
| `x.post(text \| { text, replyTo })` | draft; confirmed: Web Intent `/intent/post`, text checked, Post | write [9] |
| `github.issue`, `.pull`, `.issues` | pages in a background tab | read |
| `github.assigned({ issues, pulls, state, limit })` | GitHub's own search (`/search?type=issues`, `assignee:@me`) answering JSON in the session, 10 per page | read |
| `googleDrive.recent({ uid, limit })` | Drive's Recent view in a background tab, rows by `data-id` | read |
| `github.diff`, `.file` | `/pull/N.diff`, `/raw/REF/PATH` with the session | read |
| `linear.*` | client-api.linear.app GraphQL from a linear.app tab with the session | read |
| `linear.query(text, variables, { operationName })` | the same; the document is first lexed and parsed as GraphQL (comments, commas, strings and block strings skipped). It is refused, with nothing sent, when it does not parse, holds a mutation or subscription anywhere, or holds several operations without an `operationName` naming one | read |
| `jira.*` | `/rest/api/3/issue`, `/search/jql` (falls back to `/search`), `/myself`, same-origin, only on a site whose exact origin is in the signed-in account's `jira.sites()` list (read once per session, again when a site is missing); any other `*.atlassian.net` site fails as `invalid` before a request. When the domain policy blocks `home.atlassian.com` (`allowedDomains: ["*.atlassian.net"]`), the site is checked on its own origin instead: its `/rest/api/3/myself` must answer with an account (one cookie-bearing request to that site, which the policy allows), else the call fails naming `home.atlassian.com` to allow; `jira.sites()` then fails as `blocked` | read |
| `pageAssets.list(page?)`, `.bundle(inv, { kinds, assetIds, dir })` | DOM, computed styles, `@font-face`, resource timing; downloads through the tab the inventory was listed in (its cookies, whichever tab is current; a closed tab fails with `stale`), with cookies (`credentials: "same-origin"`) only for assets on the origin of that tab's URL as the browser reported it at `list()` (never the page's answer or the returned inventory's `pageUrl`, which agent code can change), none on a redirect hop that leaves that origin, and none (`"omit"`) for every other asset, since the page chooses the URLs, or for an inventory `list()` did not make in this session | read |
| `webmcp.tools(page?)`, `.call(name, input, { trustReadOnlyHint })` | the page's `navigator.modelContext` implementation; a call runs only the tool whose descriptor (name, title, description, schema, annotations) the draft or the listing just before it saw | write; a call with `trustReadOnlyHint: true` to a tool that declares `readOnlyHint` reads |
| `browserAuth.request(page?, { origin, fields, submit })` | native sheet, `sites/auth-fill.js` run by the app | fills user-typed values |
| `sites.list()`, `sites.help(name)`, `sites.drafts.list()/get(id)/discard(id)` | | |

## Editing Google files

Specialized tools for Google Sheets, Docs and Slides, covering reference C's
Google Sheets actions (`read_sheet_contents`, `read_cell_contents`,
`update_cell_contents`, `clear_cell_contents`, `select_cell_or_range`,
`fallback_input_into_single_selected_cell`; commented out in its current
tree) and more. Reference C reads by copying the selection to the system
clipboard and writes by dispatching a synthetic paste event; cmux reads
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
| `googleSheets.append(url, rows)` | the same after the last non-empty row; right before the paste the CSV export is read again and the write fails (`sheet_changed`) when the last row moved since the target was chosen, so rows added meanwhile are never overwritten (the web editor has no insert-at-end the session can call; a row added between that read and the paste is the remaining window) | write |
| `googleSheets.clear(url, range)` | name box selects the range, Delete, verified | write |
| `googleDocs.structure(url)` | HTML export parsed in a blank tab: headings with levels, paragraphs, lists, tables | read |
| `googleDocs.replace(url, find, replacement)` | Find and replace (Meta+Shift+H), Replace all, verified through the text export. The draft states the match count and offsets in the text export (case ignored, as Find and replace matches by default); right before Replace all the export is read again and the write fails (`document_changed`) unless it is the same text, so a match added since the preview is never edited | write |
| `googleDocs.insertAfter(url, anchor, text)` | the same with `anchor` -> `anchor + text`; the anchor must occur exactly once, also with case ignored (as Find and replace matches). The draft shows the match count (1) and its offset in the text export; right before Replace all the export is read again and the write fails (`document_changed`) unless it is the same text, so a second match or another change is never edited (an edit not yet saved to the export when it is read is the remaining window) | write |
| `googleDocs.append(url, text)` | end of document (Meta+ArrowDown), Enter, typed text, verified | write |
| `googleSlides.slides(url)` | pptx export: `{ index, title, text, notes }` per slide | read |
| `googleSlides.setNotes(url, slide, text)` | the slide's filmstrip thumbnail (`g#filmstrip-slide-<n>-<page>`); the draft names the slide by its object id (`<page>`) and title, and the write clicks the thumbnail with that object id wherever the slide moved (a deleted slide fails with `slide_changed`); the speaker notes box, old notes selected (Meta+ArrowUp, Meta+Shift+ArrowDown) and deleted, new notes typed; verified through the pptx export | write |
| `googleSlides.replace(url, find, replacement)` | Find and replace, verified through the pptx export. The draft states the match count per slide (slide text and notes, case ignored); right before Replace all the pptx export is read again and the write fails (`document_changed`) unless the deck is unchanged | write |
| `googleDrive.create(kind, title, { uid })` | `docs.google.com/<kind>/create?authuser=<email>`, with the email of the account at `/u/<uid>/` (default 0) read first, so a sign-in by another session that moves accounts to other indexes cannot put the file in another account; then the title field. Returns `account` | creates a private file |
| `googleDrive.trash(url)` | the editor's File > Move to trash, after the sharing check below | delete |

Rule for writes (reference B's confirmation taxonomy, [9] edits others can see):
a write first opens the file's editor and reads its Share button. If it
says "Private to only me", nobody else sees the edit and it runs at once.
Otherwise, including when the sharing cannot be read, the write returns a
draft with the file, its title, the sharing text and the change, and runs
only on `method(draftId, { confirm: true })`. Either way the write reloads
the editor right before its first input and fails with `sharing_changed`,
changing nothing, unless the Share button still shows the label the
decision was made on (the private label, or the previewed one): a file
shared after that read is not edited without a draft, and a draft whose
file's sharing changed since the preview does not run. A sharing change
during the input itself is the remaining window. `googleDrive.trash` deletes
data ([1]): it is a draft (with the file's title and sharing), except for a
file `googleDrive.create` made in the same REPL session while its Share
button still says "Private to only me"; a created file another session
shared since gets a draft too. The editor is reloaded right before File >
Move to trash, and the trash fails with `sharing_changed` unless the
sharing is still the one the decision or the preview was made on.

## Confirmation taxonomy

Reference B's `docs/confirmations.md` sorts browser actions into
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

### WebMCP calls

A page writes its WebMCP tools' annotations, so `readOnlyHint` is advisory: a
page can mark a tool that changes or sends data as read-only.
`sites.webmcp.call(name, input)` therefore returns a draft for every tool,
whatever it declares, and only `call(draftId, { confirm: true })` runs it.
The agent can skip the draft for one call with
`call(name, input, { trustReadOnlyHint: true })`, which runs the tool at once
only when it declares `readOnlyHint`; any other tool still returns a draft.
That option is the agent's statement that it accepts the page's claim for
this call. A name the page does not list fails as `not_found` and is not run.
The draft binds the tool's descriptor (name, title, description, input
schema and annotations as sorted-key JSON): its preview shows the schema,
the annotations and a hash of the descriptor, and the confirmed call passes
the descriptor into the page call, which runs the tool only when the page
lists it with that same descriptor, else fails with `tool_changed`. A page
that keeps the descriptor and swaps the implementation behind it is not
detected: the page owns its tools' code, so a WebMCP preview describes what
the page declares, never what its code does.

## Secure sign-in

`sites.browserAuth.request({ origin, fields, submit })` checks that each
selector is one visible, enabled credential field (a password input, or a
username or one-time-code input by type, `autocomplete` or name; a
requested password only into a password input) in the tab's origin and that
all are in one frame, marks them with a random attribute, and calls the
driver's `auth.request`. The app shows a sheet on the browser pane's window
naming the origin of the frame that holds the fields, from WebKit's record of
it (and the page's origin when the frame is embedded from another), with one
field per request (secure text for passwords). On Fill, the app runs
`sites/auth-fill.js` in its own content world of that frame, which agent
code cannot script: it checks the credential rule again, sets each value
with the native setter and dispatches `input` and `change`, so
framework-controlled fields see it. The REPL receives only a status:
`submitted`, `cancelled`, `unavailable`, `expired`, `origin_changed`,
`page_changed`, `locator_invalid` (`not_credential_field` among the reasons)
or `submission_failed`. The fill script is read from the signed app bundle,
never from the REPL, so an agent cannot substitute code that receives the
values. The sheet says what holds: the agent does not receive the values,
but the page's scripts, and code the agent runs in the page, can read a
filled field. Under a domain policy the driver refuses the request
(`blocked`) when the tab's page, or the frame that holds the fields (by
WebKit's record of it and by the document it shows when the request
arrives), is on a domain the policy blocks. The sheet lasts only as long as
the call that asked: when that call is cancelled (its cell is cancelled or
times out, the session is reset, closes or idles out), the sheet goes away
with what was typed in it and the request ends `cancelled`, and after Fill
nothing is filled unless the session still runs and drives the tab.

## Decisions for the user

These are not implemented and need a decision:

1. **CAPTCHA solving.** Reference A solves by clicking, dragging and OCR; reference B's
   policy requires confirmation at action time. cmux reports `captcha` and
   stops.
2. **Third-party password managers.** Reading or autofilling 1Password,
   Bitwarden, Dashlane, LastPass, Proton Pass or Apple Passwords puts vault
   access behind an agent. `browserAuth` covers sign-in without it.
3. **iMessage, SMS and KakaoTalk.** Not browser operations; they read local
   message databases and send as the user.
4. **Image generation and image search.** Not browser operations; image
   generation needs an API credential.
5. **Bot-detection evasion.** Not implemented; reference B's `botDetection` is
   telemetry, and cmux does not disguise automation.
6. **Google Docs and Sheets editing.** Reference A edits by clipboard paste and
   index-mapped selection. A cmux version would be a draft of the diff,
   confirmed, applied with real input in the document tab.
7. **More social writes.** LinkedIn messages and invitations, X likes,
   follows, reposts and DMs: each is [9] or [14]; the draft mechanism supports
   them, but each adds a way to act as the user in public.
8. **Native approval for writes.** A cmux sheet showing the draft, with
   Send and Cancel, would make approval the user's click instead of the
   agent's `{ confirm: true }`.
9. **Sign-in method choice and QR codes** in `browserAuth` (reference B's
   `options` and `qr_code`).
10. **Contacts.** Reference A's `googlePeople` reads the user's address book; cmux
    has no contacts tool.
11. **Reference A's own platform.** `referenceA.settings`, `projects`, `routines` and
    `channels` manage reference A, not a browser; the cmux counterparts are app
    settings and workspaces.

`tests/browser-parity/capabilities.json` (`sites`) maps every reference A site
global and method and every reference B site capability
(`reference/site-surface.txt`) to its `sites.*` or `tabs.*` equivalent and the
tests that prove it, or to one of these decisions; the capabilities unit test
fails on an unmapped member.

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
`{ lang: "es" }` `kJQP7kiw5Fk`): reference A `youtube.getTranscript` 15/15 (5 runs
each, about 200 ms); cmux with the native-client path 30/30 (10 runs each,
about 300 ms), same text lengths as reference A. Reference B's
`exportYouTubeTranscript` was not measured: its reference client may open
only the approved loopback origin.

`live-diff.mjs` compares the reads live, on the user's own sign-ins, with
reference A: `signed-in` reports which sites each side is signed in to (cookie
names on cmux, account counts on reference A, no content); `run [--ops a,b]
[--runs N] [--write-doc]` runs each read on both sides and keeps only
summaries (counts, sha256-prefixed ids, key names, lengths, order agreement,
latency) in the gitignored `sites/live-results/`, with the verdict per read.

<!-- live-diff:begin -->
Live comparison on the user's own sign-ins, 2026-10-01, tag `brepl-live` with the fixes in this branch loaded (counts and lengths only; ids compared as sha256 prefixes). Reference A's own profile was signed in to Google and Slack only; where it was not, the row says so.

| Operation | Verdict | Evidence | cmux ok, median ms | Reference A ok, median ms |
| --- | --- | --- | --- | --- |
| googleAccounts.list | cmux-better | count 5 vs 2; ids in common 2; order agreement 100% | 1/1 433 | 1/1 0 |
| gmail.inbox | same | count 50 vs 50; ids in common 50; order agreement 100% | 1/1 6021 | 1/1 742 |
| gmail.search is:unread | same | count 50 vs 50; ids in common 50; order agreement 100% | 1/1 5771 | 1/1 462 |
| gmail.thread | same | count 1 vs 1; ids in common 1 | 1/1 6402 | 1/1 331 |
| gmail.attachments (metadata) | same | count 2 vs 2; ids in common 2; order agreement 100% | 1/1 5474 | 1/1 368 |
| googleCalendar.events (next 10) | cmux-better | Reference A has no tool for this read | 1/1 3038 | n/a |
| googleDrive.recent | cmux-better | Reference A has no tool for this read | 1/1 3120 | n/a |
| google document read | same | text 28500 vs 26894 chars | 1/1 1797 | 1/1 1895 |
| google spreadsheets read | cmux-better | count 1108 vs 358; ids in common 0 | 1/1 963 | 1/1 556 |
| google presentation read | skipped | no Slides file owned by the user was found (Drive Recent and search) |  |  |
| googleSearch.search | cmux-better | Reference A failed:  Google Search returned bot challenge HTML. Open <url> in the browser, solve it, then retry. | 1/1 1152 | 0/1 595 |
| slack.workspaces | same | count 1 vs 1; ids in common 1 | 1/1 835 | 1/1 0 |
| slack.channels | same | count 55 vs 55; ids in common 55; order agreement 100% | 1/1 1321 | 1/1 209 |
| slack.history (last 20) | same | count 20 vs 20; ids in common 20; order agreement 100% | 1/1 1103 | 1/1 145 |
| slack.search | same | count 0 vs 0; ids in common 0 | 1/1 1048 | 1/1 121 |
| notion.search | reference-a-unavailable | Reference A's profile is not signed in to this site; cmux read it | 1/1 2001 | 0/1 23 |
| notion.read (first page) | reference-a-unavailable | Reference A's profile is not signed in to this site; cmux read it | 1/1 757 | 0/1 21 |
| linkedin.me | reference-a-unavailable | Reference A's profile is not signed in to this site; cmux read it | 1/1 880 | 0/1 19 |
| linkedin.feed (first page) | cmux-better | Reference A has no tool for this read | 1/1 7206 | n/a |
| linkedin.search people | reference-a-unavailable | Reference A's profile is not signed in to this site; cmux read it | 1/1 2563 | 0/1 22 |
| x.user | reference-a-unavailable | Reference A's profile is not signed in to this site; cmux read it | 1/1 1796 | 0/1 19 |
| x.timeline | reference-a-unavailable | Reference A's profile is not signed in to this site; cmux read it | 1/1 6682 | 0/1 21 |
| x.search | reference-a-unavailable | Reference A's profile is not signed in to this site; cmux read it | 1/1 3141 | 0/1 20 |
| github.assigned | cmux-better | Reference A has no tool for this read | 1/1 24183 | n/a |
| linear.assigned | cmux-better | Reference A has no tool for this read | 1/1 801 | n/a |
| jira.sites | cmux-better | Reference A has no tool for this read | 1/1 998 | n/a |
| jira.assigned | skipped | the Atlassian account has no Jira Cloud site (jira.sites: 0) |  |  |
| tabs.content | cmux-better | Reference A has no tool for this read | 1/1 688 | n/a |
| tabs.history | cmux-better | Reference A has no tool for this read | 1/1 15 | n/a |
| pageAssets.list | cmux-better | Reference A has no tool for this read | 1/1 652 | n/a |
| googleDrive.search (own Sheets, Slides) | cmux-better | Reference A has no tool for this read | 1/1 4385 | n/a |
<!-- live-diff:end -->

Tools against private accounts (Gmail, Calendar, Slack, Notion, LinkedIn, X
timelines, Linear, Jira) are verified only against the mocks: running them
live reads the user's private data. Their page selectors follow the sites'
current markup and will need updates when the sites change it; each such
failure is a `timeout` naming what it waited for.

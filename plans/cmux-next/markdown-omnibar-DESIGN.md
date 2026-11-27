# Markdown viewer omnibar and sharing

Design, 2026-10-20. Request (Lawrence, Oct 20): "I want to build a full markdown viewer as an omnibar as
well so I can see the full path... Maybe we should just reuse the omnibar. I want to see screenshots of
various versions of this but I want to be able to also share my actual URL... maybe it's my markdown
file, which is in the git repository, or maybe it is on my computer. How can we have real-time sharing
of it with Vue.js? Or maybe we can build a simple version so it is very easily visible on my own
computer for now."

Gallery (6 variants, #1 recommended): [gallery.html](markdown-omnibar/gallery.html).

## 1. Today

- A Markdown tab is an internal page tab (`FilePageService`, kind `.markdown`); `makeView` returns a
  bare `PageWebView` that `InternalPageView` pins to all four edges. No native chrome sits above it.
- The only bar is in the web page (`webviews/src/pages/markdown/MarkdownPage.tsx`, `md-toolbar`):
  back/forward, the **file name only**, save status, Rich/Source, Aa. The tab title is the file name.
- The host already finds the file's GitHub repository (`AgentPaneGitHubRepository`, config
  `githubRepository`) and watches the file (`FileChangeWatch`, 100 ms debounce, hash compare).
- The browser omnibar has a seam for surfaces that are not browser pages: `OmnibarToolbarView`
  (one `AddressBarView`, its suggestions and state machine, at the toolbar's height and insets). Nothing
  constructs it yet. `BrowserURLResolver` already turns typed `/path` and `~/path` into `file:` URLs,
  and `BrowserURLDisplay` shows a `file:` URL as its plain absolute path.

## 2. The omnibar on a Markdown tab (reuse, not a fork)

One implementation: the Markdown tab gets the browser's `OmnibarToolbarView` as a native row above the
page. No copy of the field, its glass, focus ring, suggestions or keys.

- **Seam.** `InternalPageProvider.makeTopBar(for:) -> NSView?` (default nil). `InternalPageView` takes
  the optional bar, pins it to the top at its `preferredHeight` and puts `content` under it. `content`
  stays the `PageWebView`, so the many `content as? PageWebView` paths (key routing, paint hold, focus
  target, input readiness) keep working unchanged. Only `FilePageService` (kind `.markdown`) returns a
  bar; the code editor and every other page are unchanged.
- **Field.** `addressBar.update(url: file:// URL, security: .local)`. The omnibar shows the full
  absolute path (`BrowserURLDisplay`), selectable; Cmd-L focuses it with the path selected, as in a
  browser tab. The page's own toolbar drops the file name when the native bar is present (config
  `omnibar: true`) and keeps status, Rich/Source and Aa.
- **Typing.** Enter commits through the same resolver: a `file:` URL (typed `/…`, `~/…`, `file://…`, a
  history row) opens in this tab when it is Markdown, else through the file routing (its own tab); an
  `http(s)` URL or a search opens a browser tab next to it; Escape reverts, as in the browser. Cmd-Enter
  and the other dispositions open a new tab.
- **Repo chip.** The trailing machine badge (`setMachineBadge`) shows `repo · branch` plus a state
  glyph when the file is in a git repository, and the host name for a remote file. Its menu
  (`machineBadgeMenu`) and the leading page-info chip (`onPageInfo`) both open the **Share menu** (4).
- `~` shortening: the field shows the absolute path (the request: "see the full path"). The menu's
  Copy Path and the chip's help show the `~` form. A `~` field display needs a display hook in
  `BrowserURLDisplay`, owned by the omnibar-parity work (a146); left as a follow-up.

## 2b. Back, Forward, Reload: the Markdown tab navigates like a page

Request (Lawrence, Oct 20): "I want a Markdown viewer OmniBar to be a standard OmniBar that has back,
forward, and reload as well... like it's just a web page in a sense."

- **One row.** `OmnibarToolbarView(navigation: true)` has the browser toolbar's Back, Forward and
  Reload (`ChromeIconButton`, the same icons, labels, size, spacing and place as
  `BrowserChromeView`), at the browser toolbar's height (`withButtons: true`). The owner gives
  `onBack` / `onForward` / `onReload` and `setNavigation(canGoBack:canGoForward:canReload:)`. The
  New Tab page and the popup window keep the row without buttons.
- **One history, in the page.** The page already kept the tab's link history (`MarkdownStore`
  `navigate` / `go`, scroll per entry). Now a heading anchor (`#usage`) is an entry too (the same
  anchor again adds none), and every change sends `cmux.markdown.history {canBack, canForward}`;
  `FilePageHosting.historyChanged` sets the bar's buttons. The page's own ‹ › buttons hide when the
  native bar is there (config `omnibar: true`).
- **Buttons and keys are one path.** Back, Forward and Reload send the page commands `back`,
  `forward` and `reload`, the same ones Cmd-[, Cmd-] and the new Cmd-R action `markdownReload`
  (`requires: markdownFocused`, as `markdownBack`) send. Reload saves pending edits, reads the file
  from disk again (`cmux.markdown.open` of the current path), and puts the scroll back; the history
  stays. A conflict or edits that would not save keep the page as it is. Cmd-L focuses the field.
- **Typing.** A Markdown path or `file://` URL typed in the field opens in this tab as the next
  history entry (page command `open`); from the empty state it opens as before (a page load). Another
  file goes through the file routing (its own tab). An `http(s)` URL or a search opens a cmux browser
  tab beside the Markdown tab, by the clicked-link rule (`LinkRouter` setting, `LinkOpener`
  placement): the Markdown tab stays, so Back on the Markdown tab never has to leave the browser. A
  modified commit (Cmd-Enter and the others) opens a new tab.
- **Not in this slice.** The browser's long-press Back/Forward menu and the Reload menu, mouse side
  buttons and swipe on a Markdown tab.

Ownership: a146 owns omnibar parity and a180 owns omnibar mouse-down. This work only constructs
`OmnibarToolbarView` and calls its public API; it changes no file under `CmuxNextBrowser/UI`.

## 3. Cases

| Case | Field | Chip | GitHub link | Local live link |
| --- | --- | --- | --- | --- |
| Git, pushed, clean | absolute path | `cmux · main ✓` | exact (`blob/<upstream branch>/<path>`) | yes |
| Git, committed, not pushed (ahead, file differs from upstream) | same | `cmux · main ↑2` | upstream version, marked "last pushed version"; none when the branch has no upstream | yes |
| Git, dirty (modified or staged) | same | `cmux · main ●` | upstream version, marked "last pushed version" | yes (shows the edits) |
| Git, untracked or ignored | same | `cmux · main ?` | none ("not committed") | yes |
| Git, detached HEAD | same | `cmux · <short sha>` | none | yes |
| Plain local file | same | none | none | yes |
| Outside home (`/Volumes/…`) | same | none or repo | as above | yes |
| Remote / SSH file | `ssh://host/path` | host name | git on the host (later) | not in v1 |

Git facts come from one `git status --porcelain=v2 --branch --ignored=matching -- <file>` in the
file's folder, plus `rev-parse --show-toplevel`, `remote get-url origin` (GitHub `owner/repo`) and,
when the branch is ahead, `diff --quiet @{upstream} HEAD -- <file>` (unchanged since the last push
counts as pushed). Each runs with a timeout through an injected runner (`MarkdownGitRunning`). The
parser and URL builder are pure functions with tests.

## 4. Sharing

| Option | What it is | Cost | Fit |
| --- | --- | --- | --- |
| (a) GitHub blob URL | `https://github.com/<owner>/<repo>/blob/<upstream branch>/<path>` | none | exact only when the file is pushed and clean; useful for teammates now |
| (b) Local live link | `http://127.0.0.1:<port>/md/<token>/<name>` served by cmux, reloads on save | none | v1 for "very easily visible on my own computer"; works in any browser on this Mac; never leaves the Mac |
| (c) Hosted real-time link | a cmux cloud room per document (Cloudflare Durable Object or the existing cmux cloud), presence and cursors, rendered by a small web client (Vue.js would work; the app's pages are React) | hosting, auth, a new public surface | the later "share my actual URL" with others; designed only |

**Recommendation.** v1 ships (a) and (b) in the Share menu: Copy GitHub Link, Copy Local Live Link,
Open Live Link in Browser, Copy Path, Reveal in Finder, Open in Default App. (c) appears in the menu
disabled ("Live share: coming later") and is only designed here. Building it needs a paid service or new
credentials, so it waits for the user's OK.

### 4.1 The local live server (v1)

- `MarkdownLiveShareServer` (app target), `NWListener` bound to `127.0.0.1` on a random port, started
  on the first Copy Local Live Link, one per app.
- Each shared file gets a random 128-bit token; the URL is `/md/<token>/<file name>`. Unknown tokens
  answer 404; only shared files are served, never a folder listing or another path. No CORS headers.
- `GET /md/<token>/<name>` answers a self-contained HTML page: the Markdown rendered on the Mac by
  `MarkdownHTMLRenderer` (Foundation `AttributedString(markdown:)` with full syntax: headings, lists,
  quotes, code blocks, tables, links, emphasis). Every text run is HTML-escaped and raw HTML in the
  Markdown is shown as text, so a file cannot inject script. A strict CSP (`default-src 'none';
  style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'`) limits the page to
  its own inline style and reload script.
- Live reload: `GET /md/<token>/<name>/events` is a Server-Sent Events stream; the server sends
  `reload` when `FileChangeWatch` reports a new hash. No polling.
- The token list lives in memory; quitting cmux ends every link.
- Images and relative links: v1 shows image alt text and keeps links as links; serving the file's
  folder is a later step behind the same token rule.

### 4.2 Hosted real-time sharing (designed only)

- A room per shared document on the cmux cloud (Durable Object), created by Share > Live Share. The
  Mac pushes the Markdown text (whole text on open, then diffs on save); viewers get a read-only page at
  `https://share.cmux.dev/d/<id>` with presence (who is viewing) and the owner's scroll position.
- Auth: the link is unguessable and revocable; optional "team only" uses the cmux cloud account.
- Client: a small web page. Vue.js would work; reusing the Markdown page's React renderer keeps one
  renderer for the Mac and the web, so we would use that.
- Needs: a hosted route, storage limits and billing. Ask the user before any paid service or new
  credentials.

## 5. Tests

Failing first (Swift Testing, `CmuxNextAppTests`; fleet runs only):

- `MarkdownGitStatusTests`: porcelain v2 parsing for clean, ahead, modified, staged, untracked,
  ignored, detached and no-upstream; blob URL building with spaces and Unicode in the path; `~` display.
- `MarkdownFileLocationReaderTests`: a real temp git repo (init, commit, fake bare upstream) read
  through the process runner, for clean, ahead, dirty and untracked; a file outside any repo.
- `MarkdownHTMLRendererTests`: headings, lists, code, tables, and escaping of `<script>` and raw HTML.
- `MarkdownLiveShareServerTests`: a real loopback request for a shared token answers the HTML; an
  unknown token and a path outside the share answer 404; a change sends `reload` on the event stream.
- `InternalPageTopBarTests`: a provider top bar sits above the content and `content` stays the page.

Web (`bun test`): the page hides its file name when the host says `omnibar: true`.

## 6. Coordination

- a146 (omnibar parity), a180 (omnibar mouse-down): this work only uses `OmnibarToolbarView`'s public
  API. The `~` display hook is theirs to add.
- a169 (Markdown Obsidian parity), a88 (Markdown width): the page change is one condition on the file
  name in `MarkdownPage.tsx`; no change to the editor, tables or width.

## 7. Left after v1

- `~` shortening in the field (needs a display hook in `BrowserURLDisplay`).
- Remote/SSH files: path and host chip in the field; git and the live link on the remote host.
- Images and relative links on the live page.
- Hosted real-time sharing (4.2), after the user approves cost and credentials.

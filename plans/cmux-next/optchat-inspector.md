# Chief memory inspector

A debug page that shows how a Chief's OptChat memory works. Open it with Command-Shift-P, then
"Chief: Open Memory Inspector" (DEV and nightly builds), or with "Show Memory" in the Chief
settings sidebar. It opens as a browser tab in a new column to the right of the focused pane's
column. From Home (no focused pane) the column goes right of the last column of the window's
workspace, and the app shows that workspace with the new tab selected.

## The mental model it teaches

A person needs two answers: what did the model see at this turn, and where did each part of it
come from. Everything else in the page supports those two.

1. **What the model saw.** A turn's prompt is three things in a fixed order: the system prompt
   (who Chief is, how to read the view, cmux instructions, the user's AGENTS.md), the **view**
   (the whole chat as one line per tree node, at most 128 KB), and the turn's new messages. The
   page shows that prompt for any traced turn, with byte and approximate token sizes, the cache
   breakpoints, and what the first model request read from cache or wrote to it.
2. **Where it came from.** Each view line is a tree **node**: `id+n` covers messages `id` to
   `id+n-1`. Recent lines cover one message each; older lines cover more. Clicking a line
   **zooms** into it exactly as the agent's `zoom(id, n)` does: the two lines of n/2 under it,
   down to one message in full. The breadcrumb records each hop, so a person can follow the
   same path the agent can.

Terms carry a tooltip where they first appear: node, level, view, settle, fold (the view
merges two old lines into their parent when it runs over budget), cache mark, grid, marker.

## Views

- **Prompt**: the prompt of the selected turn (default: the view as it is now). System parts,
  then the view, then the messages. Each view line shows its node name and level; clicking it
  zooms. A side bar shows the cache layout: our one marker, the harness breakpoints, the bytes
  that were the same as the previous turn's view, and the first request's cached, written and
  uncached tokens. A badge says whether the page rebuilt the exact bytes (hashes match the
  trace) or why not.
- **Tree**: the zoom panel (focused node, its text, its two children or its message), the
  breadcrumb, a level strip per level (newest nodes on the right, raw messages at the bottom,
  coarser levels above), `date(id)` lookup and full-text search that jumps to the node.
- **Timeline**: one row per turn from the trace: when, how long, cache hit rate, tools called,
  harness and model, compactor nodes built before and during the turn, settle wait, status.
  Clicking a row opens that turn's prompt.
- **Live**: settle progress (built of total view lines), the running turn, compactor work in
  flight, failures and the last error. It refreshes every 2 s while the tab is visible.

## Exact prompts from the trace

`turn.start` now records the view by its **parts** (the node name of each line), the log ids of
the turn's messages, and the layout (`cached` with its marker flag, or `blocks`). Nodes and
messages are never rewritten, so the inspector renders the parts again (`render_parts` in
optchat-core) and lays the prompt out with the same function the turn used
(`prompt::cached_layout` or `prompt::turn_blocks`). The trace's view, system and message hashes
check the result. A test compares the rebuilt system prompt and user blocks with what the fake
acpmux received. Turns traced before this change show only when the current view has the same
hash; otherwise the page says the parts were not recorded. Image blocks are not rebuilt.

## Data path

The brain host (`optchat-chief host`) serves a read-only JSON API and the page on
`127.0.0.1:<random port>`:

- It calls only the chat's read methods, searches through a `query_only` SQLite connection, and
  reads trace and status files. A test calls every endpoint and checks the database and WAL are
  unchanged.
- Loopback only: a non-loopback bind is refused, a non-loopback peer is dropped, and a Host
  header that is not this loopback address gets 403 (DNS rebinding).
- One random 256-bit token per host start, in `optchat/inspector.json` (0600, with the URL). The
  app reads it, asks `GET /api/ticket` with `Authorization: Bearer`, and opens `/?ticket=T`.
  A ticket works once within 60 s (a reload of the same URL within 10 s gets the same session) and buys an HttpOnly, SameSite=Strict session cookie, so no
  live secret appears in a URL or the browser history. GET and HEAD only; anything else is 405.
- Endpoints: `status`, `turns`, `turn?key=K|now`, `node?name=id+n`, `level?l&from&limit`,
  `date?id`, `search?q`. `OPTCHAT_INSPECTOR=0` turns the server off.

The page is React and TypeScript in `webviews/src/optchat-inspector`, built by
`scripts/cmux-next/build-optchat-inspector-web.sh` into one self-contained
`Native/OptChat/optchat-chief/inspector/index.html` (CSP: inline script and style only,
`connect-src 'self'`) and compiled into the optchat-chief binary. Nothing is fetched from the
network at run time. Unit tests run under `bun test` with jsdom; no browser runs.

## Remote brains (later)

A brain host on another Mac (server reach, cmux-lawrence) runs the same server on its own
loopback. The app will reach it through the existing trusted server path: the server relays
`GET /api/*` for the paired Chief to the host's loopback port, authenticating the app with its
existing server credential and the host with the token it holds. The page itself is in the app's
own optchat-chief binary, so only JSON crosses the link. Until then the action opens the local
Chief only and says so for a remote one.

## Status (2026-10-07)

- Landed on feat-cmux-next: d0a1d5603451 (red tests a069281246cd, feature 4862d71eece9, review
  fixes 3e499312044c). Follow-ups gated at 5c6dc9ab7e68: open from Home into a user workspace
  (the home workspace holds only the Chief conversation), a ticket reload within 10 s keeps its
  session (the browser loads the URL again when the tab moves into its column), preflight script.
- Gates on 5c6dc9ab: CmuxNext compile and catalog suites (fleet step 5f84... superseded by
  the step on 5c6dc9ab, 31 tests), optchat-chief fmt, clippy and all tests on a Testbox (inspect
  suite 6 tests), page tests under bun test with jsdom, bundle --check.
- Preflight (`scripts/cmux-next/chief-inspector-preflight.py`, tag chinsp-v4, fleet build
  355deb86570c70cee483ee84, M1 Max under ~/cmux-agent-work/hq-6d-inspector): 320 seeded notes,
  a real claude-sr turn, Cmd-Shift-P "memory inspector" Return from Home opened the page in a new
  column of workspace-2; the turn's prompt shows "Exact bytes", cache marks and our marker; Tree
  zoom 0+8 > 0+4 > 0+2 > 0+1 (3 hops) with the agent's zoom answer at each hop. API: view,
  system and message hashes equal the trace, first cache mark at byte 49929.
- Not done: pixel screenshots of the page (window snapshots do not render Chromium content and
  showed the workspace's first column, not the scrolled-in new one); remote brain path.

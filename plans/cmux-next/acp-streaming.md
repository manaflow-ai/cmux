# ACP streaming in the agent pane: audit and design

Audit of how the cmux-next agent pane (`webviews/src/agent-session/acpmux`) receives and draws streamed ACP text, measured on 2026-10-04 against a dev slot (`dev-slot.sh up 8`, acpmux `0.1.0 (7841386ef)`), with a prototype of pacing and reveal in `webviews/bench/stream/`. No pane file was changed.

## Method

- Live turns: one Claude turn (claude, via subrouter) and one Codex turn (codex), each asked for a ~2,000-word Markdown explainer with headings, a list, a 5x4 table and three code blocks, no tools. `bench/stream/measure-live.mjs` drives the real pane in headless Chromium through `cmuxAcpmuxDebug.newChat` / `sendPrompt`, with `bench/stream/instrument.js` injected before page scripts. The instrument timestamps every WebSocket message on the page clock (and records its text delta), samples every `requestAnimationFrame`, and per frame records: characters of the streaming row that changed, whether an earlier Markdown block moved or the last one shrank, the row's on-screen position (for scroll jumps), the scroller's distance from its end while pinned, the drift of an anchored element after the reader scrolls up 500 px, and whether each Pierre code block replaced its line nodes or drew no lines. Layout-shift and longtask observers run where supported.
- Repeatable replays: the live turns were saved as timed fixtures (`bench/stream/fixtures/{claude,codex}-turn.json`: each chunk with its arrival time). `bench/stream/pane.html` runs the production pane in `?mock` mode and paces the mock daemon's deliveries to the recorded arrival times (a bench-only patch of the mock's private `deliver`), so the real reducer, layout, virtualizer and renderer see the real cadence. `bench/stream/index.html?mode=before|after|parse` replays the same fixtures into one assistant message: `before` re-renders the production `<Markdown>` on every chunk (today's path), `after` is the prototype. Codex replays use the first 90 s (1,669 of 3,858 chunks; 21 code fences in the full turn).
- Both engines: Chromium headless shell and WebKit, headless. CPU totals come from CDP `Performance.getMetrics` (Chromium only). Headless Chromium paints at 120 Hz (8.3 ms frames); headless WebKit paints at about 50 to 60 Hz with throttled gaps up to 1.4 s, so WebKit frame-gap numbers describe the harness more than the pane and only its relative numbers are used.

## 1. What the daemon sends

acpmux does not coalesce. Each harness `session/update` becomes one recorded event and one `_acpmux/event` WebSocket frame (`hub/stream.rs`, `server/mod.rs::deliver`); the store writes each line and fsyncs only at turn end. Deltas are therefore exactly the harness's:

| live turn | chunks | chars (words) | stream time | rate | delta chars p50/p90/max | inter-arrival p50/p90/p99/max ms | gaps >100 ms | gaps <2 ms | frame bytes p50 |
|---|---|---|---|---|---|---|---|---|---|
| Claude | 920 | 14,588 (~2,560) | 46.1 s | 317 chars/s | 15 / 26 / 43 | 49.8 / 73.3 / 119.8 / 127.4 | 46 | 0 | 429 |
| Codex | 3,858 | 18,569 (~3,260) | 211.2 s | 88 chars/s | 5 / 9 / 16 | 8.2 / 161.8 / 325 / 1,051.6 | 1,046 | 642 | 487 |

Claude (`claude_stdio` maps each `text_delta`) arrives as a steady ~20 Hz drip of ~16 characters. Codex (`codex-acp`, one token per chunk) arrives in bursts: runs of tokens under 5 ms apart, then pauses of 100 to 500 ms (1,027 of them) and 19 pauses over 500 ms. The JSON envelope is 413 B (Claude) and 483 B (Codex) per delta, 96 to 97% of each frame. That is cheap on loopback and needs no daemon change; the cadence problem is the page's to solve.

## 2. How the page applies deltas

Per WebSocket message, `direct.ts` `apply()` reduces the event, appends the text to the row (`text: existing + delta`, `version + 1`) and `emit()`s a whole snapshot (rows re-sorted by `at`). `App.tsx` `setSnapshot` renders on React's default lane; messages that land in one task batch, nothing else does. There is no frame batching and no reveal pacing. Each version then:

- `VirtualTranscript` re-runs `layoutConversation` over every row (its memo depends on `rows`); the streaming row re-lexes its whole text with `marked.lexer` (`model.ts` `markdownBlocks`) and re-measures with Pretext.
- `MessageRow` re-renders `<Markdown>`, which re-parses the whole text with `parseMarkdown` and re-renders every block (blocks are keyed by index, not memoized).
- Each fenced block calls Pierre `File.render` with the whole code on every version: a full re-highlight.

Parse cost over the turn (`?mode=parse`, whole passes timed because page timers are coarse):

| fixture | engine | render parse total | layout lexer total | both | per delta at end (render + lexer) | incremental prototype total | its tail per delta at end |
|---|---|---|---|---|---|---|---|
| Claude, 920 deltas | Chromium | 17.4 ms | 122.3 ms | 139.7 ms | 0.04 + 0.25 ms | 11.9 ms | 0.012 ms |
| Claude | WebKit | 28 ms | 343 ms | 371 ms | 0.04 + 0.78 ms | 3 ms | 0.02 ms |
| Codex, 3,858 deltas | Chromium | 110.3 ms | 611.5 ms | 721.8 ms | 0.06 + 0.34 ms | 52.3 ms | 0.012 ms |
| Codex | WebKit | 96 ms | 1,870 ms | 1,966 ms | 0.06 + 0.98 ms | 15 ms | ~0 ms |

The whole message is re-parsed twice per delta, so cost is linear per delta and quadratic per turn; the `marked` lexer used only for height estimates is 6 to 30 times the render parser. At these sizes no frame is lost to parsing (no long tasks in the Claude turn), but a 100 KB reply would cost ~5 ms per delta on WebKit, at Codex's burst rate.

## 3. What the reader sees (production pane)

| run | frames with new text | chars per changed frame p50/p99 | frames >20.9 ms | long tasks | pinned jumps >10 px (max) | code rebuilds / blank-code frames | drift after scrolling up |
|---|---|---|---|---|---|---|---|
| Claude live, Chromium | 713 of 5,547 (13%) | 14 / 39 | 1 | 0 | n/a (metric added later) | 171 / 8 | 0 px |
| Codex live, Chromium | 1,856 of 25,321 (7%) | 6 / 26 | 7 | 1 (107 ms) | n/a | 710 / 218 | 0 px |
| Claude replay, Chromium | 711 (13%) | 14 / 38 | 7 | 0 | 71 (500*) | 172 / 7 | 0 px |
| Claude replay, WebKit | 699 (26%) | 14 / 41 | 97 | 0 | n/a** | 148 / 4 | 0 px |
| Codex 90 s replay, Chromium | 814 (8%) | 6 / 24 | 6 | 1 | 14 (400) | 256 / 78 | 0 px |
| Codex 90 s replay, WebKit | 671 (13%) | 8 / 33 | 113 | 0 | 11 (412) | 198 / 40 | 0 px |

\* 500 px is the harness's own scroll-up; the other jumps are the transcript stepping a line (22.75 px) or a code line burst (up to 131 px) in one frame. \*\* the WebKit pane replay recorded no row positions while pinned.

Findings:

- **Stop-go text.** Text changes on 7 to 13% of frames and lands 14 characters (Claude) at a time, or in Codex bursts of up to 43 characters followed by 100 ms to 1 s of nothing. On a 120 Hz display that reads as words popping in at 20 Hz, and for Codex as a stutter.
- **Lines jump.** While pinned to the end, each wrapped line moves the whole transcript 22.75 px in one frame; a burst of code lines moves it up to 131 px at once (p99 82 px Claude, 131 px Codex in the bench).
- **Code blocks re-highlight per chunk and blank out.** Pierre rebuilds its line nodes on 171 (Claude) to 710 (Codex) deltas per turn, and a code card drew no lines on 8 (Claude) and 218 (Codex, about 1.8 s at 120 Hz) frames. The card collapses to its 59 px chrome for those frames, which also yanks the pinned scroll.
- **Half-written Markdown flips.** An unclosed `` ` `` or `**` draws as a literal marker until its closer arrives, then the run re-styles (seen as "`2t -" in `acp-stream-claude-replay-chromium-12.png`). A fence opener matches the fence rule before its newline, so the language label reads `t`, `ty`, `typ` before `TypeScript`. A table header draws as a paragraph of pipes until its separator row arrives, then becomes a table.
- **No live edge.** Nothing marks where text is arriving and nothing animates in. The "Thinking" row covers only the wait before the first token.
- **What already works.** Earlier blocks never moved or resized (0 events in every run), layout-shift entries are 0 (rows move by transform, which CLS ignores, hence the custom metrics), and when the reader scrolls up the anchored text stays exactly in place (0 px drift, both engines). The pinned offset is stable (16 px short of the true end on 73% of pinned frames: the row's bottom padding, not jitter).
- **Hygiene.** The production pane logs `ResizeObserver loop completed with undelivered notifications` repeatedly while streaming (the row observer in `VirtualTranscript` flushes synchronously inside its callback). Rows sort by wall-clock `at`, not `seq`; the mock replay put the prompt under its own answer when both carried the same millisecond (a fixture artifact here, a latent tie risk in `emit()`).

## 4. Against the best streaming UIs

The strongest web chat UIs (Claude.ai, ChatGPT, the Codex app; behavior observed as a user, not from their source) share five traits. The pane has none of the first four and half of the fifth.

| trait | best practice | pane today |
|---|---|---|
| Pacing | Display decoupled from network: text flows at a steady rate near the arrival rate, a small buffer absorbs bursts, the tail drains quickly at the end | Raw network cadence |
| Soft reveal | New text fades in over ~100 to 200 ms; new blocks (rows, list items, code cards) ease in | None |
| Stable layout | Text space is reserved as it is revealed, so earlier lines never reflow; scroll follows smoothly | Earlier lines stable; scroll steps a line per frame |
| Streaming-safe Markdown | Open fences draw as code immediately; markers, links and tables never flash raw | Literal markers, label flicker, pipe paragraphs |
| Incremental highlight | Closed blocks never re-render; the open code block highlights cheaply or after it closes | Whole message re-parsed, whole fence re-highlighted per delta |

## 5. Prototype and before/after numbers

`bench/stream/` (new files only):

- `pacer.ts` `RevealPacer`: the pacing algorithm below. Pure, ticked from rAF.
- `StreamingMarkdown.tsx`: incremental block split (`StableSplitter`), streaming-safe tail (`safeTail`), fade spans, plain open-fence card, and a `CodeHandoff` that keeps the plain card until Pierre has painted lines, then fades the highlighted card in over it.
- `bench.tsx`, `index.html`, `bench.css`: the replay page; `pane.html` + `pane-entry.ts`: the paced production pane; `instrument.js`, `measure-live.mjs`, `run-bench.mjs`, `analyze.mjs`, `summarize.mjs`: measurement.

Same fixtures, same scroll script. Both modes run development React with a Profiler, so absolute CPU is inflated for both.

| run | frames with new text | chars per changed frame p50/p99 | pinned jumps >10 px | row move per frame p99 | code rebuilds / blank frames | last-block shrinks | React commits @ p50/p99 | main thread ms (script/layout/style) |
|---|---|---|---|---|---|---|---|---|
| Claude before, Chromium | 716 (13%) | 14 / 38 | 52 (max 500) | 82 px | 177 / 7 | 0 | 922 @ 0.5/1.6 ms | 2,885 (1,902/140/49) |
| Claude after (120 Hz commits), Chromium | 4,889 (88%) | 3 / 5 | 1 (max 23) | 23 px* | 2 / 1** | 1 | 5,439 @ 0.5/0.9 ms | 10,319 (5,562/633/1,447) |
| Claude after (60 Hz commits), Chromium | 2,478 (45%) | 5 / 9 | 1 (max 23) | 23 px* | 0 / 2** | 1 | 2,731 @ 0.4/0.9 ms | 5,804 (3,096/325/640) |
| Claude after, reduced motion, Chromium | 2,381 (43%) | 5 / 24 | 60 (max 500) | 93 px | 0 / 1** | 1 | 2,628 @ 0.4/0.8 ms | 4,002 (2,543/284/60) |
| Claude before, WebKit | 705 (26%) | 14 / 39 | 40 (max 500) | 500 px | 150 / 4 | 0 | 897 | n/a |
| Claude after, WebKit | 2,375 (88%) | 5 / 18 | 1 (max 20) | 20 px* | 0 / 1** | 1 | 2,624 | n/a |
| Codex 90 s before, Chromium | 812 (8%) | 6 / 25 | 6 (max 131) | 131 px | 254 / 78 | 5 | 1,461 @ 0.4/0.9 ms | 4,883 (3,270/198/71) |
| Codex 90 s after (120 Hz), Chromium | 6,046 (56%) | 1 / 3 | 1 (max 17) | 17 px* | 2 / 0 | 2 | 7,066 @ 0.4/0.8 ms | 14,860 (7,331/873/2,143) |
| Codex 90 s after (60 Hz), Chromium | 4,423 (41%) | 2 / 4 | 1 (max 17) | 17 px* | 1 / 0 | 1 | 4,914 @ 0.4/0.7 ms | 10,562 (5,164/594/1,364) |
| Codex 90 s before, WebKit | 667 (13%) | 8 / 30 | 4 (max 143) | 143 px | 200 / 40 | 2 | n/a | n/a |
| Codex 90 s after, WebKit | 4,293 (81%) | 2 / 6 | 1 (max 17) | 17 px* | 1 / 0 | 2 | 4,734 | n/a |

\* the largest single-frame step during a glide (a 22.75 px line spread over 180 ms); the one frame over 10 px in the "after" runs is the same step. A 500 px maximum is the harness's own scroll-up landing inside the pinned window. \*\* counted on Pierre's hidden card during the handoff, not drawn.

What changed: text now moves on 88% of frames (Claude) at 3 to 5 characters each instead of 14 at once; Codex bursts become a 1 to 2 character-per-frame flow; pinned scrolling has at most one frame over 10 px (a 17 to 23 px glide step) instead of 6 to 52 line jumps; Pierre renders each fence once instead of 150 to 250 times and never draws an empty card; scrolled-up drift stays 0 px; parse work drops 12x (Chromium Claude) to 130x (WebKit Codex).

What it costs: the prototype re-renders the whole message tree through React on every commit, so main-thread time rises from 6% to 22% of one core at 120 Hz commits (Claude, Chromium) and to 13% at 60 Hz. Fades still run every display frame on the compositor at 60 Hz commits, which reveals 5 characters per commit and is indistinguishable at reading distance in the frame captures. A production implementation must not re-render the message per frame (see slice 4), and should measure on a release bundle.

Residuals: one 22.75 px shrink of the last block per Claude turn (a paragraph that briefly carried one more line around a held-back table header) and two to three per Codex segment (44 px, same cause class). The tail-safety rules need a unit test matrix before they ship.

Frame captures: `acp-stream-claude-chromium-*.png`, `acp-stream-codex-chromium-*.png` (live), `acp-stream-claude-replay-chromium-*.png` (production pane replay), `acp-stream-bench-claude-{before,after}-{chromium,webkit}-*.png` (bench), in the session scratchpad.

## 6. Design

### Pacing (RevealPacer)

The view reveals a prefix of the text the model holds. Per arrival it records the time and the character count; per display frame it advances the revealed count:

- `rate` = characters that arrived in the last 600 ms, divided by 0.6 s, smoothed with an EWMA (0.9 old, 0.1 new), floored at 40 chars/s.
- `lag` = p90 of the last 32 inter-arrival gaps x 1.25, clamped to 50 to 350 ms (120 ms until 3 gaps exist). Claude settles at ~92 ms (73.3 ms p90), Codex at the 350 ms cap (162 ms p90 x 1.25 = 202 ms, rising in pauses).
- `cps` = `rate + (backlog - rate x lag) / 250 ms`, at least 40 chars/s. This is a proportional controller: the display runs at the arrival rate and trails by `lag`, which covers a typical gap so the reveal does not stall between chunks.
- Catch-up: a backlog over 900 ms of text drains in 250 ms. End of turn, cancel, or no arrival for 600 ms: drain the rest within 180 ms (the reveal never makes a finished answer wait more than ~0.2 s).
- Cuts never split a UTF-16 surrogate pair. Under reduced motion, cuts snap back to word boundaries.
- Only live text paces. History, replay after attach, a session switch, a hidden document (`visibilityState`), and a row outside the mounted range flush to the full text at once.

### Incremental Markdown parse

- `StableSplitter` scans each complete line once (state: offset, inside-fence). A boundary is final after a closing fence, after a heading or a rule, and at a blank line once the next line is complete and is not a list marker, an indented continuation or a quote. Text before the last boundary is a sequence of closed segments; each is parsed once (`parseMarkdown`) and its React subtree memoized by its source. Only the tail re-parses per commit (0.012 ms at the end of a 15 KB turn).
- The same segments should feed `model.ts`: keep `PreparedRow` blocks per closed segment so the estimator re-lexes only the tail. Better, measure from `parseMarkdown` blocks and drop `marked` from the hot path (it is 6 to 30x the render parser and a second grammar that can disagree with the renderer).
- Streaming-safe tail (`safeTail`): hold a fence line until its newline; hold a table header until its separator row and each row until its newline; hold `[text](` until `)`; strip a marker being typed at the very end; close an odd `**` or `` ` `` virtually. An open fence draws as a plain monospace card with Pierre's chrome and 20 px lines (no trailing empty line), so its height is final as it grows.
- Code: Pierre renders a fence once, after it closes. The plain card stays in flow while Pierre paints underneath at opacity 0; when Pierre's shadow root has lines, the highlighted card fades in over 180 ms and the plain card is removed at `animationend`. Same metrics, so nothing moves; only the colors arrive. (Incremental highlighting of the open fence, with Shiki per closed line, is a later option; color arriving at close reads well and costs nothing per delta.)

### Reveal animation (compositor only, 120 Hz)

- Characters revealed in the last 160 ms sit in `<span>`s keyed by reveal id with `animation: fade 160ms cubic-bezier(0.2, 0, 0, 1) both` and `animation-delay: -age`, so a re-render never restarts a fade. Older text merges back into plain text nodes (at most ~20 live spans at 120 Hz).
- The text occupies its final layout space while transparent, so line breaks are decided when a character first appears and never change (0 earlier-block moves measured).
- New block-level items (a list item, a table row, the plain code card) fade in over 200 ms on mount.
- Only `opacity` and `transform` animate. No color, filter, mask, clip-path, height or width transitions.
- Live edge: a 0.5em x 0.9em soft bar at 55% text color after the newest character; it pulses (opacity, 1 s) only while the reveal has caught up and nothing new has arrived, and disappears at turn end. The "Thinking" row stays for the wait before the first token.
- React commits are capped at 60 Hz while revealing; the fades run every display frame on the compositor (120 Hz on ProMotion).

### Scroll anchoring rules

1. Pinned means the reader is at the end (within 2 px) as of their last scroll; programmatic scrolls do not unpin.
2. Pinned and content grew by `0 < d < viewport` in a commit: set `scrollTop` to the end and animate the thread `translateY(d) -> 0` over 180 ms, `composite: "add"` so glides stack. `d >= viewport`: jump.
3. Wheel, touch or key scroll during a glide: finish the animations immediately and unpin.
4. Not pinned: never move the reader. The existing top-row anchor in `VirtualTranscript` already holds drift at 0 px; keep it, and keep rows growing only below the anchor.
5. A row that changes height off-screen above the viewport keeps the existing anchor correction.

### Reduced motion

`prefers-reduced-motion: reduce`: no fades (text appears opaque), no glide (pinned scroll jumps as today), no caret pulse, the code handoff is instant; pacing stays (it is not motion, and it still removes the burst stutter), with reveals snapped to whole words.

## 7. Slice plan

Each slice is independently shippable and measurable with `bench/stream` and the replay.

1. **Incremental estimate.** `model.ts` (`measuredRowHeight`, `PreparedRow`, `markdownBlocks`), new `conversation/stableBlocks.ts` (`StableSplitter`), `model.test.ts`; `App.tsx` `VirtualTranscript` so `layoutConversation` reuses heights of rows whose version did not change. No visual change; removes the quadratic lexer cost.
2. **Streaming-safe, memoized Markdown.** `conversation/Markdown.tsx` (a `streaming` prop: closed segments memoized by source, `safeTail` on the tail; export the block renderer or accept a tail hook), `conversation/markdown.test.ts`. Fixes literal markers, the fence label flicker and pipe paragraphs.
3. **Code blocks.** `conversation/CodeBlock.tsx` (open fence as plain lines; render Pierre once on close; handoff crossfade), `conversation/conversation.css`. Removes 150 to 700 re-highlights per turn and the blank-card frames.
4. **Pacing and reveal.** New `conversation/reveal.ts` (`RevealPacer`) and `reveal.test.ts`; a `useRevealedRows` hook in a new file used by `App.tsx` (`MessageRow` / `VirtualTranscript`), which passes the streaming row's revealed text with a reveal version so layout, drawn heights and pinning keep working; the fade spans and caret in `conversation/Markdown.tsx`; keyframes and reduced-motion rules in `conversation/conversation.css`; `direct.ts` marks rows from live `apply()` (as opposed to `rebuild()` and history pages) so only live text paces. The reveal must update only the streaming row's tail leaf per commit (memoized closed segments, or an imperative text-node append), not the whole message.
5. **Scroll glide.** `App.tsx` `VirtualTranscript` pinned branch (animate `.acpmux-thread`, cancel on user input), `styles.css`.
6. **Hygiene and measurement.** `App.tsx` row `ResizeObserver` (no `flushSync` inside the callback, or skip unchanged sizes); `direct.ts` `emit()` orders rows by `seq` and stops re-sorting every row per chunk; `perf.ts` / `debug.ts` gain streaming metrics (chars per changed frame, row-move jumps, code rebuilds) so `debug.agent_pane` measures this in the app.

The daemon (`cmux-tui/crates/acpmux`) needs no change. Coalescing is worth revisiting only for remote (cloud) links, where 430 to 490 B per 5 to 16 character delta matters.

## 8. Decisions for the owner

- Accept a display lag of ~90 ms (Claude) to 350 ms (Codex) in return for steady flow.
- 60 Hz React commits with compositor fades (13% of a core in the dev prototype) versus 120 Hz commits (22%). The production slice should land well below both by not re-rendering the message.
- Move the height estimator from `marked` to the render parser's blocks (one grammar, 6 to 30x cheaper), or keep `marked` and cache per segment.
- Hold-back rules hide a half-written table row, link or fence opener until it completes; confirm that delay is preferred over drawing raw Markdown.

## Limits of this audit

Headless WebKit frame timing is throttled and not representative of WKWebView in cmux-next; the WebKit numbers support relative comparisons only. CPU numbers are Chromium development builds with a React Profiler. Live turns ran in Chromium only (WebKit used the recorded replays). The Codex replays cover the first 90 s. The text-change metric reads `textContent`, which excludes code inside Pierre's shadow root. Not verified in the app on a 120 Hz display.

## Reproduce

From a cmux worktree with `bun install` done in `webviews/`, start a slot (`webviews/scripts/agent-pane/dev-slot.sh up 8`), then from `webviews/`:

```sh
node bench/stream/run-bench.mjs --out /tmp/stream --modes parse,before,after --fixtures claude,codex --limit 90000
node bench/stream/measure-live.mjs --replay claude --engine webkit --out /tmp/stream     # production pane, paced replay
node bench/stream/measure-live.mjs --url "<pane url from dev-slot.sh url 8>" --harness codex --out /tmp/stream   # a live turn; also writes codex-turn.json
node bench/stream/summarize.mjs /tmp/stream
```

The slot's Vite watcher did not pick up edits under `bench/` during this audit; restart the slot after editing bench files.

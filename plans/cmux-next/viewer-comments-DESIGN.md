# Viewer comments: quote and comment on selected text in a viewer, land it in a chat

User ask (2026-10-20): "We also need to be able to comment on Markdown files as well as highlight
text and comment on a Markdown file and it will show up in the chat area. We need the same thing
but for the viewers as well."

## What the user does

1. Selects text in a viewer tab (Markdown page, code editor page; later diff, PDF, web page).
2. Right-clicks. Under WebKit's Copy the menu has **Comment…** and **Quote in Chat**.
3. **Comment…** opens a small popover at the pointer: a text field, Add (Return) and Cancel (Esc).
   **Quote in Chat** skips the popover.
4. The quote lands in the composer of the chat it belongs to as a quote card: file name and line
   range as the title, then the quoted text, then the comment. The chat is not sent; the user can
   add more cards, type, then send.

## Which chat gets it (default)

1. The chat that opened the file: an agent (ACP) chat tab that opened it through a file link in the
   chat, its changed-files list, or `cmux open`/`cmux file open` run from that chat
   (`caller.agent_session`).
2. Else the Chief Home chat of the window.

The opener is remembered in the app, in memory, per file path (`ChatQuoteRouter`). A relaunch
forgets it, and the quote then goes to Chief. This is deliberate for v1: the daemon tab record has
no opener field, and adding one is a daemon schema change (tracked as a follow-up below).

If the opener chat tab is closed, or its page has not loaded, the quote goes to Chief.

## One model: `ChatQuote`

`CmuxNextPages/ChatQuote.swift`, a `Sendable` value shared by every producer:

| Field | Meaning |
| --- | --- |
| `source` | The file path (or page URL) the text came from. |
| `kind` | `markdown`, `code`, `diff`, `pdf`, `web`, `design` (the design-mode highlight). |
| `lines` | The 1-based line range in the source, nil when the viewer has no lines (a web page). |
| `quoted` | The selected text, as the user saw it. |
| `comment` | What the user wrote, empty for Quote in Chat. |

Producers: the Markdown and editor pages (this work); the design-mode highlight cards (sibling
agent) build the same value with `kind: .design` and the element's selector or description as
`quoted`. Nobody adds a second card type.

Two renderings, both from the model:

- `title`: `README.md · L12–18` (or `README.md` with no lines).
- `markdown`: the chat text a model reads:

  ```
  > **README.md** · L12–18
  > first quoted line
  > second quoted line

  the comment
  ```

## Where it lands

- **ACP agent chat** (webviews `acpmux`): a new host event `quote` (`AgentPageEvent.quote`). The
  page adds a `kind: "text"` composer attachment (the chip the floating chat's "Include focused
  tab" already uses) named `quote.title`, whose text is `quote.markdown`, and focuses the composer.
  The chip is the card; `promptBlocks()` already inlines text attachments into the prompt.
- **Chief Home chat** (native MessagesLab composer): `HomeNativeTranscriptView.appendQuote(_:)`
  appends `quote.markdown` to the field's text (after a blank line when the field has text) and
  focuses the field. Home's attachments are uploaded blobs, so a quote stays text; Home bubbles
  render the Markdown quote. A native card chip in the Home field is a follow-up (needs a
  MessagesLab inline attachment kind that is not a blob).

## Line ranges

- **Editor page (Monaco)**: exact, from `editor.getSelection()` (`cmux.editor.selection`).
- **Markdown page (Milkdown)**: the page asks its source map (`MarkdownEditor.snapshot()`) which
  top-level source block holds the selection's first and last node, then narrows inside each block
  by finding the selection's first and last line text in the block's source
  (`markdown/selectionQuote.ts`, pure, unit tested). Unsaved edits are counted in the current
  document's lines, which is what the file holds after the next save.

Host-initiated page ops (`PageRouter.callPage`), one per page: `cmux.markdown.selection`,
`cmux.editor.selection`, reply `{text, startLine, endLine}` or `null` with no selection.

## Coordination

- a223 (Markdown selection): reads only `view.state.selection`; no change to pointer selection.
- a280 (Markdown tables): a selection inside a table maps to the table block's lines.
- a304 (Send to Chief on selected text, unlanded on `scratch/rc-send-message`): its
  `PageSelectionRows` sets the same `contextMenuEditor` on file pages. This work adds
  `ViewerSelectionMenu`, which takes a list of rows; a304 should add its two rows to that list in
  `FilePageService.makeView` instead of installing a second editor (the last one set wins).
- Design mode (sibling): uses `ChatQuote` and `ChatQuoteRouter.deliver`.

## Tests (failing first)

- Swift Testing, `CmuxNextPagesTests/ChatQuoteTests`: title and Markdown rendering (lines, no
  lines, empty comment, multi-line quote, `>` inside the quote).
- `CmuxNextPagesTests/ViewerSelectionMenuTests`: rows appear after Copy only with a selection, in
  order, and run their handlers.
- `CmuxNextAppTests/ChatQuoteRouterTests`: opener chat when known and live, Chief otherwise, a later
  opener replaces an earlier one, a dead opener falls back to Chief.
- bun, `webviews/test/markdown-selection-quote.test.ts`: block lines and narrowing inside a block.
- bun, `webviews/test/acpmux-quote-event.test.ts`: the `quote` host event calls the bridge.

## Follow-ups (not in v1)

1. Diff viewer: its line comments (`webviews/src/comments`) are hidden in cmux-next
   (`DiffPageConfig.ops = []`, S5). Turn them on and send each saved comment as a `ChatQuote`.
2. PDF and web pages (browser tabs): the browser selection menu (`BrowserHitActionCatalog`) gets
   Comment… / Quote in Chat with `kind: .pdf` / `.web` and no lines.
3. Images: a region comment needs a drawn rectangle; shared with design mode.
4. Opener persisted on the daemon tab record, so it survives relaunch.
5. A native quote card chip in the Home composer.
6. Show the target chat (select its tab) when the quote lands in a chat that is not visible.

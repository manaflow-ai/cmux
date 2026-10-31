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

The opener is remembered in the app, in memory, per file path (`ChatQuoteOpeners`). A relaunch
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

A quote takes the design mode highlight's own paths (plans/cmux-next/design-mode-DESIGN.md), so a
viewer quote and a design highlight make the same card in every chat:

- **ACP agent chat**: `AgentPaneDesignSelection(id: "quote-<uuid>", name: quote.title,
  text: quote.markdown, png: nil).push(to:)`: the `designSelection` host event, which the page
  turns into a text chip (`designSelection.ts`) that goes with the next message.
- **Chief Home chat**: the quote as a file `<title>.txt` holding `quote.markdown`
  (`ChatQuoteFile`, like design mode's `BrowserDesignModeCardFiles`), given to the Home composer
  through `attachFiles(paths:via: .drop)`, so it shows as a file chip.

## Comments in the viewer

A comment made with Comment… on the Markdown page also stays in the viewer:

- **Kept with the file**: `ViewerCommentList` (`{"v":1,"comments":[{id, startLine, endLine,
  quoted, comment}]}`, at most 100 comments, oldest out) in the file's `com.cmux.markdown.comments`
  extended attribute, with an app-side copy under Application Support `MarkdownComments` (the
  table widths store, `MarkdownTableWidthRepository(name:maxBytes:)`). It survives a relaunch, a
  rename and a Finder copy, and changes neither the file's bytes nor its modification time.
- **Shown**: the config carries `comments`; every change comes as the `comments` page command.
  Each comment is a margin marker just before the block that holds its first line
  (`comments.ts`, a ProseMirror widget decoration, mapped through edits, drawn again after each
  load). The marker opens a card with the quoted text, the comment and Delete Comment
  (`cmux.markdown.deleteComment {path, id}`).
- **Not in v1**: the code editor page (its comments still go to the chat), editing a comment, and
  moving a comment when an outside edit moves its lines (it stays on the same line numbers).

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
- a304 (Send to Chief on selected text, landed 351e456c46e): its `PageSelectionRows` set a second
  `contextMenuEditor` on file pages, which replaced the table menu (Reset Column Widths was gone).
  Its two rows (Send to Chief, Send To…) are now rows of the one `ViewerSelectionMenu`, and
  `PageSelectionRows` is removed.
- Design mode (c47142a56ca): quotes reuse its card paths (above); there is no second card type.

## Tests (failing first)

- Swift Testing, `CmuxNextPagesTests/ChatQuoteTests`: title and Markdown rendering (lines, no
  lines, empty comment, multi-line quote, `>` inside the quote).
- `CmuxNextPagesTests/ViewerSelectionMenuTests`: rows appear after Copy only with a selection, in
  order, and run their handlers.
- `CmuxNextAppTests/ChatQuoteOpenersTests`: opener chat when known and live, Chief otherwise, a later
  opener replaces an earlier one, a dead opener falls back to Chief.
- bun, `webviews/test/markdown-selection-quote.test.ts`: block lines and narrowing inside a block.
- `CmuxNextPagesTests/ChatQuoteFileTests`: the Home file is named by the title and holds the Markdown.
- `CmuxNextPagesTests/ViewerCommentPromptTests`: selection reply parsing; Add to Chat and Cancel.

## Follow-ups (not in v1)

1. Diff viewer: its line comments (`webviews/src/comments`) are hidden in cmux-next
   (`DiffPageConfig.ops = []`, S5). Turn them on and send each saved comment as a `ChatQuote`.
2. PDF and web pages (browser tabs): the browser selection menu (`BrowserHitActionCatalog`) gets
   Comment… / Quote in Chat with `kind: .pdf` / `.web` and no lines.
3. Images: a region comment needs a drawn rectangle; shared with design mode.
4. Opener persisted on the daemon tab record, so it survives relaunch.
6. Show the target chat (select its tab) when the quote lands in a chat that is not visible.

# Home link chips

User (2026-10-20): links to workspaces, terminals, ACP sessions, browser tabs and Markdown
documents in the Home (iMessage) transcript show as a badge with an icon. A click focuses the
target. A hover shows a preview of the target.

## Today (inventory)

- Agent text is Markdown. `HomeMarkdown.render` turns it into a display string plus `TextRun`s;
  MessagesLab's `TextLayout` measures and `RowDraw.drawText` draws it. Rich blocks (tables) go
  through `MarkdownLayout` (`MDFrag` + `MDBox`).
- Links: `[label](url)`, `<url>`, and bare paths, `ws_…`/`pane_…`/`tab_…` ids and `cmux://` links
  (`HomeAutoLinks`, a25/a77 work). The link policy (`HomeMarkdownPolicy`) accepts http, https,
  mailto, `URL.isCmuxAppLink` (workspace, pane, tab, session, Chief subagent) and
  `URL.isHomePathLink` (`file://`).
- A link draws as blue underlined text. A click on an app link or a path goes to the host's
  `onAppLink` → `CmuxAppLinks.open` → `link.open` (one shared path) or the file pages.
- `TranscriptLinkCursor` sets the pointing hand over links. There is no hover preview.
- Reusable: `HoverCardCoordinator` / `HoverCardSource` (CmuxNextDesign, used by the tab strip and
  the sidebar, a186), `TabPreviewProvider` thumbnails, `HoverCardRowView`.
- a220 (Chief replies and reactions) changes the Chief side (Rust) and reply threading. It does
  not change link drawing. a216 (Markdown omnibar) is the file viewer's omnibar, not the transcript.

## Chip

One chip for each link whose target is a cmux object, a local file, or a GitHub object. Other
web links stay underlined text.

| Kind | Detected from | Icon (SF Symbol) |
| --- | --- | --- |
| Workspace | `cmux://workspace/ws_…` | `macwindow` |
| Pane | `cmux://pane/pane_…` | `rectangle.split.2x1` |
| Tab (unknown kind) | `cmux://tab/tab_…` | `square.on.square` |
| Terminal tab | tab + host facts | `terminal` |
| Browser tab | tab + host facts | `globe` (favicon: later) |
| Agent chat (ACP session) | `cmux://session/…` | `bubble.left.and.bubble.right` |
| Chief subagent | `cmux://chief/<home>/session/…` | `person.2` |
| Folder | `file://…/` or no extension | `folder` |
| Markdown | `.md`, `.markdown` | `doc.richtext` |
| Image | png, jpg, gif, heic, webp, svg | `photo` |
| Code | swift, ts, rs, py, go, json, … | `chevron.left.forwardslash.chevron.right` |
| Other file | anything else | `doc` |
| Pull request | `github.com/o/r/pull/N` | `arrow.triangle.pull` |
| Issue | `github.com/o/r/issues/N` | `exclamationmark.circle` |
| Commit | `github.com/o/r/commit/sha` | `smallcircle.filled.circle` |
| CI run | `github.com/o/r/actions/runs/N` | `play.circle` |

Drawing (shipped variant A, "tinted pill"): a rounded pill (radius 5) in the link tint at 14 %
alpha (outgoing: white at 22 %), the icon in the tint at 11 pt, then the label in the tint with no
underline. The label is the Markdown link text the Chief wrote; a bare id shows its short label.
A short label (≤ 40 characters) does not wrap inside the chip (non-breaking spaces).

How it fits the text engine without a second layout system: `HomeMarkdown` puts one leading
no-break space in the link and marks its runs with the style `chip:<kind>`. `TextLayout`
gives that space the icon's width with `.kern` (measure and draw use the same attributes), and
the last character a right pad. `RowDraw.drawText` fills the pill and draws the icon behind each
line's part of the chip, then draws the text. The hit test, selection, the pointing hand and the
click path do not change: the chip is still one link run.

States: the chip draws from the link alone. The live title and closed/broken state show in the
hover card (it asks the app at hover time). The chip's own icon refines a tab to terminal or
browser when the host's facts know it at render time.

## Click

No change: `onAppLink` → `CmuxAppLinks.open` → `link.open` (switches the workspace and selects
the tab), a path → the file pages or a terminal in the folder, a GitHub link → the link router.

## Hover preview

Home joins the app's one `HoverCardCoordinator` as a `HoverCardSource`:

- `MessagesLabHomeView.linkChip(at:)` returns the chip's URL and its rect on the hovered line
  (the same hit test as a click).
- `HomeNativeTranscriptView` forwards pointer moves to the coordinator, answers hits for chips,
  and supplies one reused `HomeLinkPreviewCardView`. Timing, aim, single-card rule, dismissal on
  key down, click and scroll are the coordinator's.
- The content comes from an injected `HomeLinkPreviewing` (`preview(for:) async ->
  HomeLinkPreview`). The App implements it over `AppServices`:
  - workspace: name, tab count, first tab titles;
  - tab: title, kind; a terminal's last lines; a browser's title, URL and thumbnail
    (`TabPreviewProvider`);
  - agent chat / subagent: title and status;
  - Markdown/text file: name, folder, first lines (read off the main thread, 4 KB cap);
  - folder: path and item count; GitHub: repo and number;
  - a missing target: "Closed" (or "Not found") in the card, with the id.

Keyboard: chips stay links in the accessibility tree (VoiceOver reads "workspace, <label>, link").
Tab/arrow navigation of transcript links and Space-to-preview are the follow-up; the existing
keyboard path (accessibility press) opens a chip.

## Variants (gallery)

`plans/cmux-next/home-link-chips/gallery.html` shows four chip styles and two preview cards:

- A. Tinted pill: icon + label in the link tint (Recommended, shipped).
- B. Outline tag: hairline border, label in text colour.
- C. Inline icon: icon before an underlined link, no pill.
- D. Kind-prefixed pill: "Workspace · name".
- Preview 1: compact card (icon, title, subtitle, 3 lines). Preview 2: card with a thumbnail.

## Tests (failing first)

- `HomeLinkChipTests`: kind detection for every row of the table; chip runs and the leading pad
  from `HomeMarkdown.render`; plain web links are not chips; `TextLayout` reserves the icon width.
- `HomeLinkChipHitTests`: `linkChip(at:)` finds the chip's URL and rect in a rendered bubble.
- App: `HomeLinkPreviewTests` with a fake services seam (workspace, missing tab, Markdown file).

## Left for later

- Chips inside tables (`MarkdownLayout` path), favicons on browser chips, live title in the chip
  itself for bare ids, keyboard focus ring per chip, chips in people's (plain) messages.

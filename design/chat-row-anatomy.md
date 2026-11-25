# Chat row anatomy: one rule for opening and closing rows, and one chevron

The agent chat pane puts an agent's work between its answers as one-line rows: thoughts, tool calls,
commands, groups of those, "Worked for", messages sent and received, and "Background task finished"
lines. This page is the rule for how each of them opens and closes and where its chevron goes. It
was decided by a design panel and two rounds of before and after sheets, and it ships as the
default.

Leo, 2026-11-21 05:30Z: "2. inconsistent tool calls collapsing and expanding 3. inconsistent chevrons
... 7. background tasks not expandable. even if they're denoting completion, why shouldn't they get
the same treatment? 8. all of these are just ugly. they dont spark joy. you need to think deeply about
the purpose. go get a gaggle of guys to think here."

Spacing (the gaps between rows and above a group's first child) is a separate change and is not
covered here.

## What was wrong

Measured on the gallery stage `agent-pane.row-anatomy` (the same nine rows that open, plus one read
that opens nothing):

| | before | after |
|---|---|---|
| Rows that open and show a chevron at rest | 6 of 8 | 9 of 9 |
| Rows that open nothing and show a chevron | 0 | 0 |
| "Background task finished: bg-…" line opens | no | yes: command, end, last lines |
| Ways an opened body looks | 3 (prose, card, a row inside a card) | 2 (prose for words, a card for content) |

Before:
- A group's head, a message line and a failed line showed their chevron all the time.
- An inner call or a thought inside a group showed one only while the pointer was over it.
- A finished background task's line showed none and could not open, even when its task was known.
- A sent call with no words (the message was read from a file) opened as a row drawn inside a
  message card, so it nested a second frame.

## The rule

1. **One glyph, one place, one state.** A row that opens has a chevron right after its words. The
   chevron points right when the row is closed and turns down when it is open. It is always visible,
   in the row's quiet tone; hovering brightens the row's words, not the chevron.
2. **No chevron on a row that can't open.** A read with nothing to show, or a running background
   task, draws none. A chevron is a promise that the row opens.
3. **Rows that hold rows open them in place.** "Worked for" and a group ("Read a file and ran 2
   commands") open to their child rows at the child step, with no frame around them.
4. **Rows that hold content open one body.** A thought opens to its words as prose. A message opens
   to its words in its card (the card look Leo picked on 2026-11-07). A command, a tool call and a
   background task open to the command card (the shell block), unchanged.
5. **A row inside a card opens without a card.** A sent message with no words of its own is only a
   call, so it opens to that call as a row, not as a row inside a card.
6. **A finished background task opens like a command.** "Background task finished: bg-…" opens to
   the task's command, how it ended (Finished, or the exit code in red) and the last seven lines it
   printed. Seven lines plus the cut mark fill the card's eight-line box, so the end is in sight
   without scrolling. The line reads the task from acpmux (`_acpmux/bg/output`) on its first open.
   If acpmux no longer has the task (another machine, a restart), it shows the command the line
   cites and its end, and no invented output.
7. **A row's text is gone before its band shuts.** Every fold closes the way design/chat-fold-motion.md
   says (exit before move, `exitLead.ts` `exitThenClose`): the leaving text goes to 0 while the height
   holds, then the height shuts with nothing drawn in it. That also ends the "ghost band" at 0:42 in
   Leo's 05:30Z video, where a faint "Shell 0.0s" stayed on a 30 px band under the closed row while
   it shut, because height and opacity used to share one curve. `test/command-close-no-ghost-band.test.ts`
   fails on the close before exit before move (32 px at 0.28, 17 px at 0.14) and passes on it.

## The panel

Five agents each read the 12 frames of Leo's recording and answered the same four questions for
every row kind: what question the row answers, what it shows closed, what it shows open, and when
it should open at all. Each one worked through a named lens with sources.

| Lens | Source | What it asked for |
|---|---|---|
| Dieter Rams, ten principles of good design | his ten principles ("Good design makes a product understandable", "is honest", "as little design as possible") | same thing, same look; nothing arbitrary; a chevron that opens nothing is dishonest |
| Edward Tufte, data-ink | *The Visual Display of Quantitative Information* (1983), *Envisioning Information* (1990): "Erase non-data-ink", "smallest effective difference" | three chevron behaviours and two open styles are ink with no data; one glyph per kind in one column |
| A chat app's "Thought for Ns" fold | the vendor's launch pages and a community bug report showing the fold | one muted line, the chevron right after the words, opened in place, the answer never inside it |
| An issue tracker's activity feed | the tracker's own design posts (2024, 2026): "not every element of the interface should carry equal visual weight" | two registers only: a quiet line for events, a card for content; every state tried on every kind |
| Claude's transcript | Claude Code docs, interactive mode: "Background tasks have unique IDs for tracking and output retrieval"; `Ctrl+O` "expands lines that collapse by default" | one way to open every row; a background task is an object with retrievable output, not a dead notice |

Where all five agreed: one glyph that turns, always visible; open in place; one hover effect; a
background task opens like a command. They split only on placement: a left gutter (Tufte, Claude's
transcript), after the words (the chat app, the issue tracker), or the right edge (Rams). The two
rounds below settled it.

## Variants and rounds

All five looks are gallery variants of `agent-pane.row-anatomy`. Each sheet shows them side by side,
in light and dark: round 1 at 760 px and round 2 at 420 px.

| Variant | Rows that open with a chevron at rest | Chevron place | Opened bodies (card / bare) |
|---|---|---|---|
| `before` | 6 of 8 (task line can't open) | after the words | 2 / 0, plus a row inside a card |
| **`one-rule` (default)** | **9 of 9** | **after the words** | **2 / 1** |
| `gutter` | 9 of 9 | mixed: before the glyph on tool rows, after the words on message lines | 2 / 1 |
| `all-inline` | 9 of 9 | after the words | 0 / 3 |
| `hover-only` | 4 of 9 | after the words | 2 / 1 |

Why `one-rule` won:
- **gutter** puts the chevron before the glyph on tool rows. A row that opens nothing has no chevron
  there, so its glyph jumps left: at 420 px, "Read promote.md" sits one column left of its siblings.
  Message lines keep their chevron after their words, so the pane ends up with two chevron places,
  not one. It also moves Leo's 2026-11-03 after-the-words pick.
- **all-inline** removes every card, so a command's output runs straight into the next row with
  nothing to mark where it ends. At 420 px the output and the following row read as one block. It
  also undoes the message card Leo picked on 2026-11-07.
- **hover-only** is consistent, but at rest only 4 of the 9 rows that open say so. A reader has to
  sweep the pointer over every row to find out what opens, which is the complaint in point 3.
- **one-rule** keeps every place Leo already picked (after the words, the message card, the command
  card). It changes only what was inconsistent: every row that opens shows its chevron and every
  row that doesn't shows none, and the task line now opens.

The background task line has a stage of its own, `agent-pane.background-turn-task-open`, with these
variants: closed, opened when finished, opened when failed (exit 101 in red), and opened when acpmux
no longer has the task.

## Where it lives

- `webviews/src/agent-session/acpmux/conversation/conversation.css`, `MessageGroupHead.css`: the
  chevron at rest.
- `BackgroundTurnLine.tsx`, `backgroundTurnTask.ts`: the task line opens to its task.
- `AgentMessageRow.tsx` (`bare`), `SentMessageLine.tsx`: a sent call with no words opens without a
  card.
- `RowAnatomy.gallery.ts`, `BackgroundTurnTaskOpen.gallery.tsx`: the stages and variants.

# Reply to Selection (Home, agent and group chats)

Lawrence 2026-10-20: "If I highlight text in the message UI, I need to be able
to right-click it and respond only to that text, not to the full message. Think
about how Apple would design this."

## What the person does

1. Drag across part of a message (or double-click a word).
2. Right-click the selection. The menu has **Reply to Selection** at the top of
   the reply group, above **Reply…**. Cmd-Shift-R does the same (free in the
   cmux-next defaults; Cmd-R is Rename Tab / Reload).
3. The thread composer opens like **Reply…** does, with a quote card on the
   field: a thin neutral bar, "Replying to <name>", and the excerpt (two lines
   at most, an ellipsis after that). The card has a close button; Esc on an
   empty field removes the card first, then closes the thread as before.
4. Send. The sent bubble starts with the excerpt in quotation marks, in the
   bubble's secondary text colour, then the reply.
5. A click on that quote scrolls to the original message and flashes exactly the
   quoted words (not the whole bubble), with the reveal timing Home already uses
   for permalinks (in 0.22 s, hold 1 s, out 0.5 s).

No selection: the menu is unchanged (**Reply…** quotes the whole message, as
now). A selection that spans two messages shows no **Reply to Selection**
(a quote has one source).

## Why this shape (the Apple test)

- Messages has no partial quote, so the nearest Apple patterns are Mail (the
  quoted text travels with the reply) and the iOS reply card over the keyboard
  (what you answer stays visible while you type). We take the card from iOS
  and the "quote travels in the text" rule from Mail.
- Neutral colours only: the bar and excerpt use the secondary label colour, no
  accent fill. The card is the field's own material.
- The quote is short and quiet in the sent bubble; the reply is the message.
- The jump back is the reward: the exact words light up, not a whole bubble.
- Reduce Motion: the card appears and leaves with a cross-fade only (no slide);
  the jump scrolls without animation; the flash still fades (opacity is not
  motion).

## Data

- On the wire the reply's text starts with a Markdown blockquote of the
  excerpt (`> line` per line, a blank line, then the reply). Every owner (the
  Mac daemon, the cloud owner, the Chief's optchat store) stores it as written,
  and the Chief reads the quote in its prompt with no schema change. Old
  replies have no leading quote and render as before.
- `reply_to` stays the message answered (thread parent), so threads, counts and
  tree mode are unchanged.
- In the app, `ReplyQuote` holds the source (message, part), the UTF-16 range
  in the shown text and the excerpt. The range is not stored by the owner: the
  jump finds the excerpt in the parent's shown text (exact, then a whitespace
  tolerant prefix match), so an edited or reflowed original still resolves,
  and a missing one falls back to the whole-bubble reveal.
- Rendering: a person's message whose text starts with a quote block shows it as
  `“excerpt”` with the `quote` run style (secondary colour). An agent's
  Markdown `>` lines get the same style (HomeMarkdown had no blockquotes).

## Coordination

- a347 (shared bubble shape): the quote is a text run inside the shared bubble,
  no new bubble shape or draw path.
- a287 / a220 (Chief quoted replies, tapbacks): unchanged; `reply_to` is the
  same field. A Chief can quote a span the same way by writing `> excerpt`.
- a329 (Markdown highlight comments, quote cards): same excerpt rules
  (`ReplyQuote.excerpt`), so a comment quote and a reply quote truncate alike.
- a304 (right-click Send Message): separate menu, no overlap.
- a353 (whole-message replies): no streaming dependency; a quote is in the
  committed text.

## Not in this slice

- A persistent marker on the original range (variant D in the gallery).
- Reply to Selection in the agent pane's web chat (it already has
  "Quote in Reply", AgentPaneContextMenu).

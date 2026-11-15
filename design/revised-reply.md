# Revised reply

A Claude Code Stop hook can block an agent's stop and give it a reason, for example a check that
the reply calls something "fixed" with no evidence. The turn then goes on, and the agent often sends
its whole reply again with one line changed. Both replies stayed in the chat, back to back. Leo,
2026-11-14, on the same "A few updates:" report drawn twice: "why did u send this twice?"

## What acpmux records

Claude Code writes the hook's reason as a synthetic user line (`Stop hook feedback:` and the
reason). acpmux sends it to the hub as one `stop_hook_feedback` update
(`cmux-tui/crates/acpmux/src/claude_stdio/inbound.rs`). The hub records `message_superseded` with
reason `stop_hook` before the first chunk of the next reply (`hub/stream.rs`) when two things hold:

- the hook came right after a reply in the same turn;
- nothing but thoughts, progress ticks and subagent updates came between the hook and the next
  reply.

A call the person sees, a plan or a prompt in between means the agent did new work, so its next
words are a new reply and both stay. The key is the hook's event. The two texts' likeness is never
read.

## What the pane draws

The new reply streams into the first reply's row (`direct.ts` `reviseSupersededMessage`). The row
keeps the first text, whole, until the new text has streamed, then swaps it in one frame
(`conversation/RevisedReply.tsx`). The transcript never draws the reply twice, and nothing below
the row moves while the agent writes. The row keeps the first text and the hook's reason as
`revisedFrom`. Copy, export and read aloud use the new text.

## Look

The mark is the `revised-reply-look` experiment:

- **word** (selected): one muted word under the reply. It reads "Revising…" while the new reply
  streams and "Revised" after. A click opens the first version under the reply, in dim ink behind a
  rule. The word uses the footer's caption size, ink and row height, as the stopped turn's
  "Stopped" does (`.cv-turn-stopped`).
- **silent**: the swap with no mark. It is the quietest, but the first version is lost.
- **stack**: a closed "Earlier version" fold over the reply. It is the most visible, and it puts
  old text first in the reading order.

The word wins because it adds one quiet line, it keeps the first version one click away, and it
draws nothing new into the reply's prose.

References in `cmux-design-references/index.json`:

- `claude/live/transcript-user-message-actions-read-receipt`: state words and marks sit in the
  message's quiet footer at caption size, not in the prose.
- `cmux/live/transcript-tab-switch-layout-shift`: a transcript must not shift under the reader.
  This is why the row is reused and the first text stays until the swap.

## Gallery

`agent-pane.revised-reply`:

- `recorded`: the turn as acpmux records it (`fixtures/recordings/claude-stop-hook-resend.ndjson`),
  replayed through the pane's own client. Its play checks that one reply shows, the new one, and
  that Revised opens the first.
- `revised`, `revised-open`, `revising`: the word's states.
- `before`: both replies drawn, as Leo saw them.
- Compare arms: the three looks.

## Tests

- `cmux-tui/crates/acpmux/tests/hub_integration/transcript_events.rs`
  `a_reply_sent_again_after_a_stop_hook_supersedes_the_first`
- `cmux-tui/crates/acpmux/src/claude_stdio/tests.rs` `a_stop_hook_block_is_one_update_with_its_reason`
- `webviews/test/transcript-stop-hook-resend.test.ts`
- `webviews/test/agent-pane-stop-hook-resend.test.ts` (Chromium)

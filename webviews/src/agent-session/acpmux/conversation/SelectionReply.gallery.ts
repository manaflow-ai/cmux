// l10n-allow-file: public-safe gallery fixtures.
// Leo: "anyways we have this but would it make sense to have a direct reply button? or would you
// mostly just re-read your own thing anyways? what makes sense here?"
// The ways to reply to part of a reply (SelectionReply.tsx): the right-click menu alone, a chip over
// the selection (shipped), the chip as a glyph, and a Reply button on every message's row.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";

const PHRASE = "retry only on 429 and 503";
const rows = [
  user("How should the fetch helper handle a failed request?", 6, { id: "gallery-reply-prompt" }),
  assistant(
    `I'd ${PHRASE}, with a jittered backoff that starts at 250 ms and caps at 4 s.\n\nEvery other status fails at once, so a bad token or a 404 shows up in the first call instead of after a minute of retries.`,
    5.9,
    { id: "gallery-reply-answer" },
  ),
  summary(5.9, { id: "gallery-reply-summary", status: "completed" }),
];

/// Selects PHRASE in the reply, as a drag would end, then waits for the chip (when the look has one).
async function selectPhrase(ctx: PlayContext, chip: boolean) {
  const doc = ctx.document;
  await ctx.waitFor(() => doc.querySelector('[data-row-id="gallery-reply-answer"] .cv-md'));
  const body = doc.querySelector('[data-row-id="gallery-reply-answer"] .cv-md')!;
  const walker = doc.createTreeWalker(body, 4);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const at = node.textContent?.indexOf(PHRASE) ?? -1;
    if (at < 0) continue;
    const range = doc.createRange();
    range.setStart(node, at);
    range.setEnd(node, at + PHRASE.length);
    const selection = doc.getSelection()!;
    selection.removeAllRanges();
    selection.addRange(range);
    break;
  }
  const View = doc.defaultView!;
  doc.dispatchEvent(new View.PointerEvent("pointerup", { bubbles: true }));
  if (chip) await ctx.waitFor(() => doc.querySelector(".cv-selection-reply"));
}

// The reply right under a sent message's "Sent to <session>" line, so the chip's usual spot over
// the selection's end is that line (Leo, 2026-11-05: "this is a bad reply").
const sentRows = [
  rows[0],
  activity(
    [
      tool("SendMessage", "other", "completed", {
        inputSummary: JSON.stringify({
          to: "Debug Cloud release lane",
          message: "Which statuses does the fetch helper retry?",
        }),
        output: "delivered to Debug Cloud release lane\n",
      }),
    ],
    6,
    { id: "gallery-reply-sent" },
  ),
  ...rows.slice(1),
];

const variant = (look: string, note: string, play: (ctx: PlayContext) => Promise<void>, snapshot = chat(rows)) => ({
  note,
  theme: { selectionReply: look },
  snapshot,
  play,
});

export default agentPaneEntry({
  id: "agent-pane.selection-reply",
  title: "Reply to a selected part of a message",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 400, normal: 760, wide: 1040 },
  covers: ["agent-session/acpmux/conversation/SelectionReply.tsx"],
  variants: {
    none: variant("none", "Before: selected text gets Quote in Reply only from the right-click menu.", (ctx) =>
      selectPhrase(ctx, false),
    ),
    "chip-above": variant(
      "chip",
      "Shipped: a Reply chip over the selection's end, as Claude and ChatGPT; it quotes the selection into the composer.",
      (ctx) => selectPhrase(ctx, true),
    ),
    "chip-under-sent-line": variant(
      "chip",
      'The chip takes a spot with no text under it: here past the "Sent to" line over the selection, never on it.',
      (ctx) => selectPhrase(ctx, true),
      chat(sentRows),
    ),
    "chip-icon-only": variant("icon", "The same chip as a quote glyph alone.", (ctx) => selectPhrase(ctx, true)),
    "row-reply-button": variant(
      "row",
      "Rejected: a Reply button on every message's row. You nearly always reply to the latest message, so it repeats on every row for little use.",
      async (ctx) => {
        await ctx.hover({ selector: '[data-row-id="gallery-reply-answer"]' });
      },
    ),
  },
});

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
  user("How should the fetch helper handle a failed request?", 6, {
    id: "gallery-reply-prompt",
  }),
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

// Leo, 2026-11-07, on the chip floating off to the side of a selection: "if it's ever on the right
// edge, just make it in line". A reply long enough to wrap, a selection that ends on a line's last
// word, one over three lines, and one that ends inside inline code (his second screenshot).
const LONG =
  "The fetch helper retries a request only when the server answers 429 or 503, and it waits a little longer before each new attempt so a busy server gets room to recover. Every other status fails at once, so a bad token or a missing route shows up in the first call instead of after a minute of retries. The backoff starts at 250 ms, doubles on each attempt, adds up to a quarter of jitter and stops growing at 4 s, which keeps a stuck call from holding the queue for long.";
const CODE =
  "Then run `cmux chat --on cloud` once the lane has its machine, and check the first reply it sends back.";
const longRows = [
  user("How should the fetch helper handle a failed request?", 6, {
    id: "gallery-reply-prompt",
  }),
  assistant(`${LONG}\n\n${CODE}`, 5.9, { id: "gallery-reply-long" }),
  summary(5.9, { id: "gallery-reply-summary", status: "completed" }),
];

/// The text node in the long reply whose text starts with `start`.
function textNode(doc: Document, start: string): Text | undefined {
  const body = doc.querySelector('[data-row-id="gallery-reply-long"] .cv-md');
  if (!body) return undefined;
  const walker = doc.createTreeWalker(body, 4);
  for (let node = walker.nextNode(); node; node = walker.nextNode())
    if (node.textContent?.startsWith(start)) return node as Text;
  return undefined;
}

/// The offsets in `node` where each laid-out line ends (after its last non-space character).
function lineEnds(doc: Document, node: Text): number[] {
  const range = doc.createRange();
  const text = node.data;
  const ends: number[] = [];
  let lineTop: number | undefined;
  let last = 0;
  for (let at = 0; at < text.length; at += 1) {
    if (text[at] === " ") continue;
    range.setStart(node, at);
    range.setEnd(node, at + 1);
    const top = range.getBoundingClientRect().top;
    if (lineTop !== undefined && top > lineTop + 4) ends.push(last);
    if (lineTop === undefined || top > lineTop + 4) lineTop = top;
    last = at + 1;
  }
  ends.push(last);
  return ends;
}

/// Selects in the long reply as a drag would end, then waits for the chip to be placed. `pick` gets
/// the paragraph's (or code span's) text node and its line ends and answers the range's two ends.
async function selectIn(
  ctx: PlayContext,
  start: string,
  pick: (node: Text, ends: number[]) => { from: [Text, number]; to: [Text, number] },
) {
  const doc = ctx.document;
  await ctx.waitFor(() => textNode(doc, start));
  await doc.fonts?.ready;
  const node = textNode(doc, start)!;
  const { from, to } = pick(node, lineEnds(doc, node));
  const range = doc.createRange();
  range.setStart(...from);
  range.setEnd(...to);
  const selection = doc.getSelection()!;
  selection.removeAllRanges();
  selection.addRange(range);
  doc.dispatchEvent(new doc.defaultView!.PointerEvent("pointerup", { bubbles: true }));
  await ctx.waitFor(() => {
    const chip = doc.querySelector<HTMLElement>(".cv-selection-reply");
    return chip && chip.style.visibility !== "hidden" ? chip : undefined;
  });
}

/// The second line of the long paragraph from its second word to its last character.
const rightEdge = (ctx: PlayContext) =>
  selectIn(ctx, "The fetch helper", (node, ends) => {
    const start = node.data.indexOf(" ", ends[0]! + 1) + 1;
    return { from: [node, start], to: [node, ends[1]!] };
  });
/// From the first line's middle to the third line's middle.
const multiLine = (ctx: PlayContext) =>
  selectIn(ctx, "The fetch helper", (node, ends) => {
    const end = node.data.lastIndexOf(" ", Math.floor((ends[1]! + ends[2]!) / 2));
    return { from: [node, Math.floor(ends[0]! / 2)], to: [node, end] };
  });
/// From "Then run" into the inline code, ending after "--on cloud".
const inlineCode = (ctx: PlayContext) =>
  selectIn(ctx, "Then run", (node) => {
    const code = textNode(ctx.document, "cmux chat --on cloud")!;
    return { from: [node, 0], to: [code, code.data.length] };
  });

const variant = (
  look: string,
  note: string,
  play: (ctx: PlayContext) => Promise<void>,
  snapshot = chat(rows),
) => ({
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
  // The edge cases' stages (and test/selection-reply-place.test.ts) at every width: the chip goes on
  // the selection's last line, or wraps under it, and never into the margin.
  widths: { narrow: 400, normal: 760, wide: 1040 },
  covers: ["agent-session/acpmux/conversation/SelectionReply.tsx"],
  variants: {
    none: variant(
      "none",
      "Before: selected text gets Quote in Reply only from the right-click menu.",
      (ctx) => selectPhrase(ctx, false),
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
    "chip-right-edge": {
      ...variant(
        "chip",
        "A selection that ends at a line's right edge: no room after it in the column, so the chip wraps under it, never into the margin.",
        rightEdge,
        chat(longRows),
      ),
      height: 640,
    },
    "chip-multi-line": {
      ...variant(
        "chip",
        "A selection over three lines: the chip follows the last line, just after its last character.",
        multiLine,
        chat(longRows),
      ),
      height: 640,
    },
    "chip-inline-code": {
      ...variant(
        "chip",
        "A selection that ends inside inline code: the chip sits on that line, centred on it.",
        inlineCode,
        chat(longRows),
      ),
      height: 640,
    },
    "chip-icon-only": variant("icon", "The same chip as a quote glyph alone.", (ctx) =>
      selectPhrase(ctx, true),
    ),
    "row-reply-button": variant(
      "row",
      "Rejected: a Reply button on every message's row. You nearly always reply to the latest message, so it repeats on every row for little use.",
      async (ctx) => {
        await ctx.hover({ selector: '[data-row-id="gallery-reply-answer"]' });
      },
    ),
  },
});

// l10n-allow-file: public-safe gallery fixtures.
// Leo: "anyways we have this but would it make sense to have a direct reply button? or would you
// mostly just re-read your own thing anyways? what makes sense here?"
// The ways to reply to part of a reply (SelectionReply.tsx): the right-click menu alone, a chip over
// the selection (shipped), the chip as a glyph, and a Reply button on every message's row.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";
import { selectionReplyWrap } from "./selectionReplyWrap.experiment";

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
const CODE = "Once the lane has its machine and the first reply is back, run `cmux chat --on cloud`";
const longRows = [
  user("How should the fetch helper handle a failed request?", 6, {
    id: "gallery-reply-prompt",
  }),
  assistant(`${LONG}\n\n${CODE}`, 5.9, { id: "gallery-reply-long" }),
  summary(5.9, { id: "gallery-reply-summary", status: "completed" }),
];

// A dense reply: ten lines with no gap, a bold word and inline code mid-paragraph. Every spot near
// a short selection holds text, so the chip must measure each spot where it is.
const DENSE =
  "Each retry waits a little longer than the last one, so a busy server gets room to recover before the next request arrives. The helper keeps a count of attempts per request and gives up after the fifth, which keeps a stuck call from holding the queue. Statuses other than 429 and 503 fail at once, so a bad token or a missing route shows up in the first call instead of after a minute of retries. The wait between attempts is the **backoff**, and it doubles each time, starting at 250 ms and stopping at 4 s, with up to a quarter of jitter added so that many clients do not all retry in the same instant. A request the caller cancels stops its retries at once, and `fetchWithRetry` reports the last status it saw. Logs name the attempt number, the status and the wait, which is enough to tell a slow server from a broken one when you read them later. Tests cover each status, the cap, the jitter bounds and the cancel path, and they run in well under a second.";
const denseRows = [
  user("How should the fetch helper handle a failed request?", 6, { id: "gallery-reply-prompt" }),
  assistant(DENSE, 5.9, { id: "gallery-reply-dense" }),
  summary(5.9, { id: "gallery-reply-summary", status: "completed" }),
];

/// The text node in the long or dense reply whose text starts with `start`.
function textNode(doc: Document, start: string): Text | undefined {
  for (const body of Array.from(doc.querySelectorAll('[data-row-id^="gallery-reply-"] .cv-md'))) {
    const walker = doc.createTreeWalker(body, 4);
    for (let node = walker.nextNode(); node; node = walker.nextNode())
      if (node.textContent?.startsWith(start)) return node as Text;
  }
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

/// Selects in the long or dense reply as a drag would end, then waits for the chip to be placed.
/// `pick` gets the paragraph's (or code span's) text node and its line ends and answers the range's
/// two ends; `backward` drags from the end to the start.
async function selectIn(
  ctx: PlayContext,
  start: string,
  pick: (node: Text, ends: number[]) => { from: [Text, number]; to: [Text, number] },
  backward = false,
) {
  const doc = ctx.document;
  await ctx.waitFor(() => !!textNode(doc, start));
  await doc.fonts?.ready;
  const node = textNode(doc, start)!;
  const { from, to } = pick(node, lineEnds(doc, node));
  const selection = doc.getSelection()!;
  selection.removeAllRanges();
  if (backward) selection.setBaseAndExtent(to[0], to[1], from[0], from[1]);
  else selection.setBaseAndExtent(from[0], from[1], to[0], to[1]);
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
/// From "Once the lane" into the inline code, ending after "--on cloud", the paragraph's end.
const inlineCode = (ctx: PlayContext) =>
  selectIn(ctx, "Once the lane", (node) => {
    const code = textNode(ctx.document, "cmux chat --on cloud")!;
    return { from: [node, 0], to: [code, code.data.length] };
  });

/// The long paragraph's last line, to the paragraph's end: nothing follows it on that line.
const paragraphEnd = (ctx: PlayContext) =>
  selectIn(ctx, "The fetch helper", (node, ends) => ({
    from: [node, node.data.indexOf(" ", ends[ends.length - 2]!) + 1],
    to: [node, ends[ends.length - 1]!],
  }));
/// Two words in the middle of the long paragraph's third line: text over it, after it and under it.
const midLine = (ctx: PlayContext) =>
  selectIn(ctx, "The fetch helper", (node, ends) => {
    const from = node.data.indexOf(" ", Math.floor((ends[1]! + ends[2]!) / 2)) + 1;
    const to = node.data.indexOf(" ", node.data.indexOf(" ", from) + 1);
    return { from: [node, from], to: [node, to] };
  });

/// Two short words mid-paragraph in the dense reply: text on every side for lines.
const shortMid = (ctx: PlayContext) =>
  selectIn(ctx, "Each retry", (node) => {
    const at = node.data.indexOf("a minute");
    return { from: [node, at], to: [node, at + "a minute".length] };
  });
/// "the backoff," across the bold word, so the range's boxes overlap (the bold element's and its
/// text's).
const boldMid = (ctx: PlayContext) =>
  selectIn(ctx, "Each retry", (node) => {
    const after = textNode(ctx.document, ", and it doubles")!;
    return { from: [node, node.data.length - "the ".length], to: [after, 1] };
  });
/// From the dense reply's third line to its fifth, dragged backward: the pointer lets go at the
/// start, and the end is two lines below it.
const backwardMulti = (ctx: PlayContext) =>
  selectIn(
    ctx,
    "Each retry",
    (node, ends) => ({
      from: [node, node.data.indexOf(" ", Math.floor((ends[1]! + ends[2]!) / 2)) + 1],
      to: [
        node,
        Math.min(node.data.length, node.data.indexOf(" ", Math.floor((ends[3]! + (ends[4] ?? node.data.length)) / 2))),
      ],
    }),
    true,
  );

// A short Markdown prompt, right-aligned in its bubble: a column narrower than the chip.
const okRows = [
  user("**OK**", 6, { id: "gallery-reply-ok" }),
  assistant(LONG, 5.9, { id: "gallery-reply-long" }),
  summary(5.9, { id: "gallery-reply-summary", status: "completed" }),
];
/// Selects "OK" in the prompt's bubble.
async function selectOk(ctx: PlayContext) {
  const doc = ctx.document;
  const find = () => {
    const row = doc.querySelector('[data-row-id="gallery-reply-ok"]');
    if (!row) return undefined;
    const walker = doc.createTreeWalker(row, 4);
    for (let node = walker.nextNode(); node; node = walker.nextNode())
      if (node.textContent === "OK") return node as Text;
    return undefined;
  };
  await ctx.waitFor(() => !!find());
  const node = find()!;
  doc.getSelection()!.setBaseAndExtent(node, 0, node, 2);
  doc.dispatchEvent(new doc.defaultView!.PointerEvent("pointerup", { bubbles: true }));
  await ctx.waitFor(() => {
    const chip = doc.querySelector<HTMLElement>(".cv-selection-reply");
    return chip && chip.style.visibility !== "hidden" ? chip : undefined;
  });
}

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
  // The edge cases' stages (and test/selection-reply-place.test.ts) at every width: the chip covers
  // no unselected text, stays in the visible transcript and never goes into the margin.
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
    "chip-right-edge": {
      ...variant(
        "chip",
        "A selection that ends at a line's right edge mid-paragraph: no free spot near, so the chip covers the selection's own last words, never other text or the margin.",
        rightEdge,
        chat(longRows),
      ),
      height: 640,
    },
    "chip-multi-line": {
      ...variant(
        "chip",
        "A selection over three lines ending mid-line: the chip takes the nearest spot that covers no other text.",
        multiLine,
        chat(longRows),
      ),
      height: 640,
    },
    "chip-inline-code": {
      ...variant(
        "chip",
        "A selection that ends inside inline code at its paragraph's end: the chip goes over the end when that is free, else just after it.",
        inlineCode,
        chat(longRows),
      ),
      height: 640,
    },
    "chip-paragraph-end": {
      ...variant(
        "chip",
        "A selection that ends its paragraph: the chip sits just after its last character, centred on that line.",
        paragraphEnd,
        chat(longRows),
      ),
      height: 640,
    },
    "chip-mid-line": {
      ...variant(
        "chip",
        "Two words mid-paragraph, text all around: the chip takes the nearest spot with no text under it, or covers only the selection's own words.",
        midLine,
        chat(longRows),
      ),
      height: 640,
    },
    "chip-short-mid": {
      ...variant(
        "chip",
        "Two words mid-paragraph in a dense reply: every spot near holds text, so the bar is its glyphs alone over the selected words.",
        shortMid,
        chat(denseRows),
      ),
      height: 640,
    },
    "chip-bold-mid": {
      ...variant(
        "chip",
        "A selection across a bold word, whose boxes overlap: the chip still covers none of the text around it.",
        boldMid,
        chat(denseRows),
      ),
      height: 640,
    },
    "chip-backward-multi-line": {
      ...variant(
        "chip",
        "Three lines dragged backward: the chip goes over where the pointer let go when that is free, else near the end, measured there.",
        backwardMulti,
        chat(denseRows),
      ),
      height: 640,
    },
    "chip-short-prompt": {
      ...variant(
        "chip",
        "A short Markdown prompt right-aligned in its bubble, narrower than the chip: the chip stays in the pane, over the prompt.",
        selectOk,
        chat(okRows),
      ),
      height: 640,
    },
    "chip-icon-only": variant("icon", "The same bar as its four glyphs alone (Reply, Copy, Ask in side chat, Add to chat).", (ctx) => selectPhrase(ctx, true)),
    "row-reply-button": variant(
      "row",
      "Rejected: a Reply button on every message's row. You nearly always reply to the latest message, so it repeats on every row for little use.",
      async (ctx) => {
        await ctx.hover({ selector: '[data-row-id="gallery-reply-answer"]' });
      },
    ),
  },
  // Where the chip goes when no spot near the selection's end is free of other text
  // (selectionReplyWrap): compare the arms on chip-right-edge, at the narrow width too.
  experiment: {
    definition: selectionReplyWrap,
    script: [
      {
        // Only the stages with the long reply have that line; the others keep their own selection.
        name: "Select to the line's right edge",
        run: async (ctx) => {
          if (ctx.document.querySelector('[data-row-id="gallery-reply-long"]')) await rightEdge(ctx);
        },
      },
    ],
  },
});

// l10n-allow-file: public-safe gallery fixtures.
// Leo 2026-11-07: "this reply, it has too little opacity here." The selection's Reply chip
// (SelectionReply.tsx, conversation.css .cv-selection-reply) over a see-through window, with the
// selected phrase in a user bubble and code around it, so the chip floats over text, a bubble and the
// wallpaper. Each variant is one material: before, Jump to latest's 72% veil, the shipped 90% veil
// (test/selection-reply-contrast.test.ts: 85% is the least that keeps the label at 4.5:1 over any
// backdrop), and a solid card.
import wallpaper from "../../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";

const PHRASE = "retry only on 429 and 503";
const rows = [
  user(`Should the fetch helper ${PHRASE}, or on every 5xx? Keep the backoff jittered.`, 6, {
    id: "gallery-material-prompt",
  }),
  assistant(
    "Only those two. A 500 from the API is a bug on our side, and retrying it hides it.\n\n```ts\nconst RETRY = new Set([429, 503]);\nconst delay = Math.min(4000, 250 * 2 ** attempt) * (0.5 + Math.random());\n```\n\nEvery other status fails at once, so a bad token shows up in the first call.",
    5.9,
    { id: "gallery-material-answer" },
  ),
  summary(5.9, { id: "gallery-material-summary", status: "completed" }),
];

/// The page over a wallpaper, as a see-through window shows it: the page background is clear.
function seeThrough(doc: Document) {
  const root = doc.documentElement;
  root.style.setProperty("--cmux-surface-background", "transparent");
  root.style.background = `url("${wallpaper}") center / cover no-repeat fixed`;
  doc.body.style.background = "transparent";
}

/// Selects PHRASE in the user's bubble, as a drag would end, and gives the chip `style`.
async function selectInBubble(ctx: PlayContext, style: Record<string, string>) {
  const doc = ctx.document;
  seeThrough(doc);
  await ctx.waitFor(() => doc.querySelector('[data-row-id="gallery-material-prompt"]'));
  const bubble = doc.querySelector('[data-row-id="gallery-material-prompt"]')!;
  const walker = doc.createTreeWalker(bubble, 4);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const at = node.textContent?.indexOf(PHRASE) ?? -1;
    if (at < 0) continue;
    const range = doc.createRange();
    range.setStart(node, at);
    range.setEnd(node, at + PHRASE.length);
    doc.getSelection()!.removeAllRanges();
    doc.getSelection()!.addRange(range);
    break;
  }
  const View = doc.defaultView!;
  doc.dispatchEvent(new View.PointerEvent("pointerup", { bubbles: true }));
  await ctx.waitFor(() => doc.querySelector(".cv-selection-reply"));
  const chip = doc.querySelector<HTMLElement>(".cv-selection-reply")!;
  for (const [name, value] of Object.entries(style)) chip.style.setProperty(name, value);
}

const variant = (note: string, style: Record<string, string>) => ({
  note,
  theme: { selectionReply: "chip" },
  snapshot: chat(rows),
  play: (ctx: PlayContext) => selectInBubble(ctx, style),
});

export default agentPaneEntry({
  id: "agent-pane.selection-reply-material",
  title: "The Reply chip's material over a see-through window",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 400, normal: 760 },
  covers: ["agent-session/acpmux/conversation/SelectionReply.tsx#SelectionReplyChip"],
  variants: {
    before: variant(
      "Before: the cards' 4% fill over a clear page and the dim tool-row label; the bubble and wallpaper show through and the label sinks (Leo: too little opacity).",
      {
        background: "linear-gradient(var(--cv-card-fill), var(--cv-card-fill)), var(--agent-page-bg, Canvas)",
        color: "var(--cv-tool-strong)",
        "backdrop-filter": "none",
        "-webkit-backdrop-filter": "none",
      },
    ),
    "veil-72": variant(
      "Jump to latest's 72% veil of the theme surface with its blur: better, but under 4.5:1 over a white or a black backdrop.",
      { "--cv-selection-reply-veil": "72%" },
    ),
    "veil-90": variant(
      "Ships: a 90% veil of the theme surface over a light blur, and the full text color; at least 4.5:1 over anything, and still glass.",
      {},
    ),
    solid: variant("A solid card of the theme surface: reads, but is not glass (Reduce Transparency's look).", {
      background: "var(--glass-surface)",
      "backdrop-filter": "none",
      "-webkit-backdrop-filter": "none",
    }),
  },
});

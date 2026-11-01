// l10n-allow-file: gallery fixtures (sample prompts and agent answers), not shipped UI.
// The rest gap between the chat's newest row and the bottom stack (Leo, 2026-11-01: "in the next
// build, will we have more space between composer and latest messages? i'd like it... tho maybe not
// as much as claude code"). Three values side by side, the chat opened at its latest message: the
// last answer's footer, then the gap, then the composer. 48px (REST_GAP, model.ts) is the one that
// shipped: about two body lines under the footer, as Codex leaves under its action row; Claude Code
// leaves about four and a half.
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, summary, user } from "../../gallery/fixtures/acpmux";
import type { Play, PlayContext } from "../../gallery/play";
import { REST_GAP } from "./model";

const ANSWER =
  "The retry helper now waits longer before each attempt, capped at eight seconds, and stops after five. The fetch tests cover a server that fails twice and then answers.";

const rows = Array.from({ length: 10 }, (_, index) => {
  const turn = 10 - index;
  return [
    user(`Check step ${index + 1} of the retry plan`, turn * 3 + 2),
    assistant(`Step ${index + 1}: ${ANSWER}`, turn * 3 + 1),
    summary(turn * 3 + 1, { status: "completed", durationMs: 12_000 }),
  ];
}).flat();

/// The newest row's drawn bottom sits `want` px over the bottom stack's drawn top.
const gapIs =
  (want: number): Play =>
  async (ctx: PlayContext) => {
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-row"));
    const scroller = ctx.find({ selector: ".acpmux-scroll" }) as HTMLElement;
    const dock = ctx.find({ selector: ".acpmux-dock" });
    const drawn = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
    const last = drawn.reduce((a, b) =>
      Number(b.getAttribute("aria-posinset")) > Number(a.getAttribute("aria-posinset")) ? b : a,
    );
    const drawnRects = (node: Node) => {
      const range = ctx.document.createRange();
      range.selectNodeContents(node);
      return [...range.getClientRects()].filter((rect) => rect.width > 0 && rect.height > 0);
    };
    const bottom = Math.max(...drawnRects(last).map((rect) => rect.bottom));
    const top = Math.min(...drawnRects(dock).map((rect) => rect.top));
    const gap = top - bottom;
    if (Math.abs(gap - want) > 1) throw new Error(`The rest gap is ${gap.toFixed(1)}px, not ${want}px`);
  };

const variant = (gap: number, note: string) => ({
  note,
  snapshot: chat(rows),
  documentAttributes: gap === REST_GAP ? {} : { "rest-gap": String(gap) },
  play: gapIs(gap),
});

export default agentPaneEntry({
  id: "agent-pane.composer-rest-gap",
  title: "Room between the latest message and the composer",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  covers: ["agent-session/acpmux/App.tsx#VirtualTranscript"],
  variants: {
    "gap-32": variant(32, "32px: about a line and a half under the footer. Tighter than Codex."),
    "gap-48": variant(48, "48px, shipped: about two lines under the footer, as Codex leaves under its action row."),
    "gap-64": variant(64, "64px: nearly three lines. Closer to Claude Code, which Leo found too big."),
  },
});

// l10n-allow-file: gallery fixtures (sample prompts and agent answers), not shipped UI.
// The composer floats over the transcript (Leo 2026-10-19, as the Claude and Codex apps lay theirs):
// a long chat opened at its latest message, its scrollbar's track running the pane's height to the
// bottom corner, the composer lying over the transcript's foot and the last answer whole above it.
// The play checks that geometry and then grows the composer by a few lines. The grown card covers the
// transcript's foot and moves no row (the overlay dock, Leo, 2026-11-11: "do we even want stuff to push
// up vs just simple... covering stuff?"); a wheel past the end reaches the covered rows
// (composer/dockMotion.gallery.tsx `grown-reached`).
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, summary, user } from "../../gallery/fixtures/acpmux";
import type { Play, PlayContext } from "../../gallery/play";

const ANSWER =
  "The retry helper now waits longer before each attempt, capped at eight seconds, and stops after five. The fetch tests cover a server that fails twice and then answers.";

const rows = Array.from({ length: 14 }, (_, index) => {
  const turn = 14 - index;
  return [
    user(`Check step ${index + 1} of the retry plan`, turn * 3 + 2),
    assistant(`Step ${index + 1}: ${ANSWER}`, turn * 3 + 1),
    summary(turn * 3 + 1, { status: "completed", durationMs: 12_000 }),
  ];
}).flat();

/// The scroller reaches the pane's bottom; returns the newest drawn row.
function trackToBottom(ctx: PlayContext): HTMLElement {
  const main = ctx.find({ selector: ".acpmux-main" }).getBoundingClientRect();
  const scroller = ctx.find({ selector: ".acpmux-scroll" }) as HTMLElement;
  const track = main.bottom - scroller.getBoundingClientRect().bottom;
  if (Math.abs(track) > 2) throw new Error(`The transcript ends ${track.toFixed(1)}px above the pane's bottom`);
  const drawn = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
  return drawn.reduce((a, b) =>
    Number(b.getAttribute("aria-posinset")) > Number(a.getAttribute("aria-posinset")) ? b : a,
  );
}

/// The scroller reaches the pane's bottom, and the last row ends above the composer's card.
function underComposer(ctx: PlayContext) {
  const card = ctx.find({ selector: ".acpmux-composer-box" }).getBoundingClientRect();
  const under = trackToBottom(ctx).getBoundingClientRect().bottom - card.top;
  if (under > 1) throw new Error(`The last row is ${under.toFixed(1)}px under the composer`);
}

const scrolledToEnd: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-row"));
  underComposer(ctx);
};

const composerGrows: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-md"));
  underComposer(ctx);
  const before = trackToBottom(ctx).getBoundingClientRect().top;
  await ctx.type("Then document the cap", { selector: ".acpmux-md" });
  for (let line = 0; line < 3; line++) {
    await ctx.press("Shift+Enter");
    await ctx.type(`and line ${line + 2} of the note`);
  }
  const moved = trackToBottom(ctx).getBoundingClientRect().top - before;
  if (Math.abs(moved) > 1) throw new Error(`The last row moved ${moved.toFixed(1)}px as the composer grew`);
};

export default agentPaneEntry({
  id: "agent-pane.composer-floats",
  title: "Composer over the transcript",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  covers: ["agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript"],
  variants: {
    "scrolled-to-end": {
      note: "A long chat at its latest message: the scrollbar runs to the pane's bottom corner, the composer floats over the transcript, the last answer sits whole above it.",
      snapshot: chat(rows),
      play: scrolledToEnd,
    },
    "composer-grown": {
      note: "The same chat with a four-line prompt typed: the card grew over the transcript's foot and no row moved.",
      snapshot: chat(rows),
      play: composerGrows,
      checks: {
        layoutShiftMax: {
          value: 0.005,
          reason: "The composer grows a line upward at each Shift-Enter over the transcript, the state under test.",
        },
      },
    },
  },
});

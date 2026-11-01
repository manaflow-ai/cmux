// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// The prompt rail holds still while the rest of the pane lays out again (Leo, 2026-11-01: "the left
// side scroll rail needs to not really get affected by most other layout things it shouldn't really
// shift much at all"). The rail is each variant's anchor: a step that does not target it fails the
// stage when the rail moves or resizes by any amount (play.ts `anchorMovePx`, 0 px), and the stage's
// layout-shift sampling (gallery shift gate) tracks its box from the load on.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";

/** A finished turn: a prompt, a run of commands, the reply and its footer. */
function turn(index: number, minutes: number): AcpmuxRow[] {
  const id = `rail-${index}`;
  return [
    user(`Run the checks for package ${index} and fix what fails`, minutes, { id: `${id}-user` }),
    activity(
      [
        tool(`bun test packages/p${index}`, "execute", "completed", {
          id: `${id}-test`,
          command: `bun test packages/p${index}`,
          output: Array.from({ length: 12 }, (_, line) => `  ok ${line + 1} - case ${line + 1}`).join("\n"),
          exitCode: 0,
        }),
        tool(`Read packages/p${index}/src/index.ts`, "read", "completed", { id: `${id}-read` }),
      ],
      minutes - 0.2,
      { id: `${id}-activity` },
    ),
    assistant(`Package ${index} passes its tests. Nothing needed a change.`, minutes - 0.4, { id: `${id}-reply` }),
    summary(minutes - 0.5, { id: `${id}-summary`, status: "completed", toolCount: 2, durationMs: 42_000 }),
  ];
}

const PROMPTS = 24;
const rows = Array.from({ length: PROMPTS }, (_, index) => turn(index + 1, 200 - index * 6)).flat();
const SCROLLER = { selector: ".acpmux-scroll" };
const codexChat = () => chat(rows, { harness: "codex", model: "gpt-6-astra", title: "Prompt rail holds still" });

const atBottom: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(`[data-row-id="rail-${PROMPTS}-summary"]`));
  await ctx.scroll(SCROLLER, "bottom");
};

export default agentPaneEntry({
  id: "agent-pane.thread-minimap-shift",
  title: "Prompt rail: no shift from other layout",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 520, normal: 900, wide: 1400 },
  anchors: [{ selector: "nav.acpmux-minimap__rail" }],
  covers: [
    "agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#ThreadMinimap",
    "agent-session/acpmux/App.tsx#VirtualTranscript",
  ],
  variants: {
    "open-chat": {
      note: "Opening a long chat: the rail draws at its final box once.",
      snapshot: codexChat(),
    },
    "composer-grows": {
      note: "Play: a four-line prompt grows the composer over the view. The rail keeps its top, height and inset; its bottom ticks stay in full ink.",
      snapshot: codexChat(),
      play: async (ctx) => {
        await atBottom(ctx);
        await ctx.type("Then document the cap", { selector: ".acpmux-md" });
        for (let line = 0; line < 3; line++) {
          await ctx.press("Shift+Enter");
          await ctx.type(`and line ${line + 2} of the note`);
        }
      },
    },
    "tool-expand-bottom": {
      note: "Play: at the bottom of the chat, open the last turn's Worked for. The view lifts the rows; the rail stays where it was.",
      snapshot: codexChat(),
      play: async (ctx) => {
        await atBottom(ctx);
        const toggle = `[data-row-id="worked-rail-${PROMPTS}-user"] button.cv-worked`;
        await ctx.click({ selector: toggle });
        await ctx.waitFor(() => ctx.document.querySelector(`${toggle}[aria-expanded="true"]`));
      },
    },
    "scrolled-up": {
      note: "Play: scrolled into the middle of the chat (the top fade comes, the bottom fade comes). Only the lit band moves.",
      snapshot: codexChat(),
      play: async (ctx) => {
        await atBottom(ctx);
        await ctx.scroll(SCROLLER, 1200);
      },
    },
  },
});

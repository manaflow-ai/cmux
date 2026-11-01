// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// Load and interaction sequences for the layout-shift gate (gallery health, scripts/gallery-matrix/
// shift-baseline.ts). Leo, 2026-11-01: "how about like the apparatuses for improving ui
// verification? let's examine what we can do better for our workflows", after finding in one
// nightly the gap above the composer shifting on load, the rail growing in steps while history
// loaded, the sidebar toggle shifting the layout and a tool expand pushing content up. Each variant
// is one of those sequences on the real pane; the stage measures its load and every step (play.ts,
// shift.ts), and a state whose baseline is 0 fails gallery health the moment anything moves.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";

/** A finished turn: a prompt, a run of commands with output, the reply and its footer. */
function turn(index: number, minutes: number): AcpmuxRow[] {
  const id = `shift-${index}`;
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
        tool(`bun run lint packages/p${index}`, "execute", "completed", {
          id: `${id}-lint`,
          command: `bun run lint packages/p${index}`,
          output: "No problems found.\n",
          exitCode: 0,
        }),
      ],
      minutes - 0.2,
      { id: `${id}-activity` },
    ),
    assistant(`Package ${index} passes its tests and lint. Nothing needed a change.`, minutes - 0.4, {
      id: `${id}-reply`,
    }),
    summary(minutes - 0.5, { id: `${id}-summary`, status: "completed", toolCount: 3, durationMs: 42_000 }),
  ];
}

const rows = Array.from({ length: 8 }, (_, index) => turn(index + 1, 60 - index * 6)).flat();
const SCROLLER = { selector: ".acpmux-scroll" };

/** The tool row toggle of turn `index` (1-based). */
const toolToggle = (index: number) => ({ selector: `button.cv-tool[data-tool-id="shift-${index}-test"]` });

const atBottom = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector('[data-row-id="shift-8-summary"]'));
  await ctx.scroll(SCROLLER, "bottom");
};

export default agentPaneEntry({
  id: "agent-pane.shift-scenarios",
  title: "Layout shift: load and interaction sequences",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 520, normal: 760, wide: 760 },
  anchors: [{ selector: ".acpmux-composer-box" }],
  covers: [
    "agent-session/acpmux/conversation/ToolRow.tsx",
    "agent-session/acpmux/conversation/ToolGroupRow.tsx",
    "agent-session/acpmux/App.tsx",
  ],
  variants: {
    "open-chat": {
      note: "Opening a finished chat: the transcript and the composer draw their final layout once (the load is measured).",
      snapshot: chat(rows),
    },
    "tool-expand-bottom": {
      note: "Play: at the bottom of the chat, open the last turn's command. Rows above it stay where they are; nothing scrolls them up.",
      snapshot: chat(rows),
      play: async (ctx) => {
        await atBottom(ctx);
        await ctx.click(toolToggle(8));
        await ctx.waitFor(() => ctx.document.querySelector(`${toolToggle(8).selector}[aria-expanded="true"]`));
      },
    },
    "tool-expand-mid": {
      note: "Play: scrolled into the middle of the chat, open a command there. Rows above it stay; rows under it move down only.",
      snapshot: chat(rows),
      play: async (ctx) => {
        await atBottom(ctx);
        await ctx.scroll(SCROLLER, 900);
        await ctx.click(toolToggle(4));
        await ctx.waitFor(() => ctx.document.querySelector(`${toolToggle(4).selector}[aria-expanded="true"]`));
      },
    },
    "pane-resize": {
      note: "Play: the pane narrows and widens again, as the sidebar toggle resizes it. Each row moves once to its new place, with no bounce.",
      snapshot: chat(rows),
      play: async (ctx) => {
        await atBottom(ctx);
        await ctx.resize(520);
        await ctx.resize(760);
      },
    },
    "model-menu-open": {
      note: "Play: open the composer's model menu. The menu opens in one frame; the composer and the transcript stay put.",
      snapshot: chat(rows),
      play: async (ctx) => {
        await atBottom(ctx);
        await ctx.click({ selector: ".acpmux-model" });
        await ctx.waitFor(() => ctx.document.querySelector("[role='menu'], [role='listbox']"));
      },
    },
    "older-history": {
      note: "Play: a long chat on the mock daemon opens on its newest page; scrolled to the top, older pages load above. The rows on screen do not move as they arrive.",
      ready: { transport: "mock" },
      snapshot: chat([]),
      play: async (ctx) => {
        type Debug = { loadSeed(turns: number): Promise<unknown> };
        const view = ctx.document.defaultView as unknown as { cmuxAcpmuxDebug?: Debug };
        await ctx.waitFor(() => view.cmuxAcpmuxDebug);
        // The debug socket's load_seed: a long chat recorded in the mock daemon and opened through
        // the real client, so it pages in as a chat on acpmux does (mockPaging.test.ts).
        void view.cmuxAcpmuxDebug!.loadSeed(240);
        await ctx.waitFor(() => ctx.document.querySelectorAll("[data-row-id]").length > 20, { capMs: 15_000 });
        const before = ctx.document.querySelectorAll("[data-row-id]").length;
        await ctx.scroll(SCROLLER, "top");
        await ctx.waitFor(() => ctx.document.querySelectorAll("[data-row-id]").length > before, { capMs: 10_000 });
      },
    },
  },
});

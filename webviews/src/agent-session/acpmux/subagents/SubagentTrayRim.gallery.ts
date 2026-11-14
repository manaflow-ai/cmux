// l10n-allow-file: gallery fixtures (prompts, subagent tasks, commands), not shipped UI.
// The composer hat's top rim drags (trayResize.ts). Leo, 2026-11-12: "it's sort of weird how, you
// know, you have this glass rim, but you can't drag up the composer hat area ... why are there
// ellipses going so fast? Like they get truncated and cut off so soon." Compare the default five
// lines with the list dragged taller and shorter; the long commands run to the row's edge.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { setHatHeight } from "./trayResize";

const running = (task: string, minutes: number, action: string): Subagent => ({
  id: `agent-${task.toLowerCase().replaceAll(/[^a-z]+/g, "-")}`,
  parent: null,
  name: "general-purpose",
  task,
  kind: "general-purpose",
  action,
  state: "running",
  background: true,
  startedAt: minutesAgo(minutes),
});

const command = (line: string, description: string, minutes: number) =>
  tool(line, "execute", "completed", {
    inputSummary: JSON.stringify({ command: line, description, run_in_background: true }),
    startedAt: minutesAgo(minutes),
  });

const snapshot = chat([
  user("Keep the waits going and fan the reviews out", 14),
  row(SUBAGENTS, 14, {
    subagents: [
      running("Review the fold", 6, "cd webviews && bun test src/agent-session/acpmux/subagents/subagentFold.test.ts"),
      running("Read the bottom stack", 5, "Grep acpmux-running-tray__list webviews/src/agent-session/acpmux"),
      running("Audit the linger", 3, "Read trayLinger.ts"),
    ],
  }),
  activity(
    [
      command("gh run watch 19283746 --repo acme/app --exit-status --interval 30 --compact", "wait for CI", 12),
      command("gh pr checks 41790 --repo acme/app --watch --fail-fast --interval 30", "wait for merge", 10),
      command("bun test webviews/src/agent-session/acpmux/subagents --timeout 30000", "run the hat tests", 9),
      command("cd ~/Projects/app && bun run dev --port 5173", "Run the dev server", 8),
    ],
    13,
  ),
  assistant("The waits and the reviewers keep running in the background.", 1),
  summary(1, { status: "completed", durationMs: 600_000, toolCount: 7 }),
]);

const opened = (height: number | undefined) => async (ctx: PlayContext) => {
  setHatHeight(height, false);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
  await ctx.click({ selector: ".acpmux-running-tray__head" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__list .acpmux-agent-line"));
};
const rimHovered = async (ctx: PlayContext) => {
  await opened(undefined)(ctx);
  await ctx.hover({ selector: ".acpmux-running-tray__rim" });
};

export default agentPaneEntry({
  id: "agent-pane.subagent-tray-rim",
  title: "Composer hat: drag the rim, lines cut at the row's edge",
  area: "Agent pane",
  height: 720,
  widths: { narrow: 360 },
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/trayResize.ts",
    "agent-session/acpmux/subagents/trayDetail.ts",
  ],
  variants: {
    default: {
      note: "Open at the default five lines: each command runs to the row's edge before its ellipsis, never 40 characters in.",
      play: opened(undefined),
      snapshot,
    },
    rim: {
      note: "The pointer on the hat's top rim: the resize cursor; a drag up makes the list taller.",
      play: rimHovered,
      snapshot,
    },
    taller: {
      note: "Dragged up to 260px: every line shows, no scroll.",
      play: opened(260),
      snapshot,
    },
    shorter: {
      note: "Dragged down to two lines: the rest scroll in place.",
      play: opened(56),
      snapshot,
    },
  },
});

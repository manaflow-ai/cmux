// l10n-allow-file: gallery fixtures (prompts, subagent names, commands), not shipped UI.
// The running tray's header and trailing column (SubagentTray.tsx, AgentLine.tsx). The collapsed
// header said "Running in background · N subagents · M commands" behind a chat bubble, with the
// elapsed time floating in a column of its own far from the words, and the open tray's Stop buttons
// hung below and right of their lines, off their centre, with the chevrons in two columns. Here the
// header's fixed mark is work that runs (three arms, trayHead.experiment.ts; view Compare arms), its time
// follows the counts as quiet meta, every Stop sits in its line on the line's centre, and the
// header's, every line's and View all's chevrons end on one x.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { trayHeadLook } from "./trayHead.experiment";

const running = (name: string, minutes: number, action: string): Subagent => ({
  id: `agent-${name.toLowerCase().replaceAll(" ", "-")}`,
  parent: null,
  name,
  task: name,
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

/** Between turns: three background subagents and two background commands still run. */
const betweenTurns = chat([
  user("Fan the review out and keep the checks running while I look", 163),
  row(SUBAGENTS, 163, {
    subagents: [
      running("Review the tray", 163.3, "Read SubagentTray.tsx"),
      running("Review the fold", 120, "Grep useFold"),
      running("Audit the stack", 45, "Read bottomStack.css"),
    ],
  }),
  activity(
    [
      command("cd ~/Projects/app && bun run dev", "Run the dev server", 150),
      command("cd ~/Projects/app/webviews && bun test --watch", "Watch the tests", 30),
    ],
    150,
  ),
  assistant("The reviewers and the checks keep running in the background.", 2),
  summary(2, { status: "completed", durationMs: 9_800_000, toolCount: 3 }),
]);

const head = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");

const open = async (ctx: PlayContext) => {
  await ctx.waitFor(() => head(ctx));
  if (head(ctx)!.getAttribute("aria-expanded") !== "true") await ctx.click({ selector: ".acpmux-running-tray__head" });
  await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-running-tray__list .acpmux-agent-line").length >= 3);
};

export default agentPaneEntry({
  id: "agent-pane.subagent-tray-head",
  title: "Running tray header and trailing column",
  area: "Agent pane",
  height: 420,
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/AgentLine.tsx",
    "agent-session/acpmux/subagents/trayHead.experiment.ts",
  ],
  experiment: {
    definition: trayHeadLook,
    script: [
      {
        name: "the folded header",
        run: async (ctx) => {
          await ctx.waitFor(() => head(ctx));
        },
      },
      { name: "open the tray", run: open },
    ],
  },
  variants: {
    folded: {
      note: "Between turns, folded: the header's mark, its counts, the elapsed time right after them as quiet meta, and the chevron in the lines' trailing column.",
      play: async (ctx) => {
        await ctx.waitFor(() => head(ctx));
      },
      snapshot: betweenTurns,
    },
    open: {
      note: "Open: every Stop sits inside its line on the line's centre, before the chevron; the header's and every line's chevrons end on one x.",
      play: open,
      snapshot: betweenTurns,
    },
  },
});

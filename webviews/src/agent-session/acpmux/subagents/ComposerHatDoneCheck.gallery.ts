// l10n-allow-file: gallery fixtures (prompts, subagent tasks), not shipped UI.
// Where a finished line's check sits in the composer hat, against the hat's other glyphs (Leo,
// 2026-11-08, on "47s ✓": "it's just bc the alignment/whatever around the rest of the hat when you look
// at the symbol and size/whatnot of it it just feels iffy how it's close the the number but idk if it
// should be so close"). A running, a finished and a failed line in the open hat, and a lone finished
// item heading the folded hat, so the check's size, its gap to the time and its column read against
// the Stop square, the chevron and the lines' own glyphs. Three arms for the header (Compare arms;
// hatParts.experiment.ts `hatDoneCheckPlace`): its own Stop-wide column (shipped), right after the time,
// the leading glyph column; every arm draws the check at the Stop square's ink size. The fourth idea, the time
// alone, is `hatDoneLook`'s `time` arm (agent-pane.composer-hat-done). Test:
// test/composer-hat-done-check.test.ts.
import { agentPaneEntry } from "../../../gallery/format";
import { chat, row, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo, recentRun } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { hatDoneCheckPlace } from "./hatParts.experiment";

function agent(name: string, minutes: number, state: Subagent["state"] = "running", ran = 0.8): Subagent {
  return {
    id: `agent-${name.toLowerCase().replaceAll(" ", "-")}`,
    parent: null,
    name,
    task: name,
    state,
    ...(state === "running"
      ? { startedAt: minutesAgo(minutes), action: "Read land_ready.py" }
      : recentRun(minutes, ran)),
  };
}

const hat = (agents: Subagent[]) =>
  chat([user("Fan the review out", 7), row(SUBAGENTS, 6.2, { subagents: agents })], { isWorking: true });

const head = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");

const openHat = async (ctx: PlayContext) => {
  await ctx.waitFor(() => head(ctx));
  if (head(ctx)!.getAttribute("aria-expanded") !== "true") await ctx.click({ selector: ".acpmux-running-tray__head" });
  await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-running-tray .acpmux-agent-line").length === 3);
};

export default agentPaneEntry({
  id: "agent-pane.composer-hat-done-check",
  title: "Composer hat: the done check's column",
  area: "Agent pane",
  height: 420,
  anchors: [{ selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/DoneMark.tsx",
    "agent-session/acpmux/subagents/AgentLine.tsx",
    "agent-session/acpmux/subagents/subagents.css",
  ],
  experiment: {
    definition: hatDoneCheckPlace,
    script: [
      {
        name: "a lone finished item heads the folded hat with its time and check",
        run: async (ctx: PlayContext) => {
          await ctx.waitFor(() => head(ctx)?.querySelector("[data-done-check]"));
        },
      },
    ],
  },
  variants: {
    rows: {
      note: "Open: a running line (its time, its Stop square), a finished one (its time, its check) and a failed one (its state and time). The check stands in the Stop square's column at the square's ink size and the hat's stroke, a track gap after the time.",
      play: openHat,
      snapshot: hat([
        agent("Make autoland land again", 6.2, "running"),
        agent("Check the docs", 3, "completed", 0.78),
        agent("Run the update tests", 2.5, "failed", 0.4),
      ]),
    },
    lone: {
      note: "One finished item heads the folded hat: its task, its time, then the check in the lines' Stop column, never hugging the time.",
      play: async (ctx) => {
        await ctx.waitFor(() => head(ctx)?.querySelector("[data-hat-done]"));
      },
      snapshot: hat([agent("Check the docs", 3, "completed", 0.78)]),
    },
  },
});

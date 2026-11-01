// l10n-allow-file: gallery fixtures (prompts, subagent names), not shipped UI.
// One tray line's anatomy (design/chat-transcript.md "Subagent row anatomy"; Leo, 2026-10-31: "why
// is this still so ass in latest nightly", and earlier "eg a lot of these subtitles are bad"): one
// leading glyph (the spinner while it works), the title a gap after it, one muted trailing meta and
// the time, the chevron. No agent-type subtitle and no Done or Running word on the line; a tray with
// nothing running draws no card. The arms (trayPanel.experiment.ts `trayRowLook`) place a running
// line's stats: in the trailing meta, on a second line, or right after the title.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { trayRowLook } from "./trayPanel.experiment";

function agent(
  name: string,
  minutes: number,
  state: Subagent["state"] = "running",
  fields: Partial<Subagent> & { ran?: number } = {},
): Subagent {
  const { ran = 1.4, ...rest } = fields;
  return {
    id: `agent-${name.toLowerCase().replaceAll(" ", "-")}`,
    parent: null,
    name,
    task: name,
    kind: "general-purpose",
    state,
    startedAt: minutesAgo(minutes),
    ...(state !== "running" && { endedAt: minutesAgo(minutes - ran) }),
    ...rest,
  };
}

const group = (agents: Subagent[], minutes: number) => row(SUBAGENTS, minutes, { subagents: agents });

/** The anatomy every arm keeps; a broken one fails the variant. */
function anatomy(ctx: PlayContext): void {
  const lines = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-running-tray .acpmux-agent-line")];
  if (lines.length === 0) throw new Error("no tray line");
  for (const line of lines) {
    if (line.querySelector(".acpmux-agent-line__kind-icon")) throw new Error("a second leading glyph");
    if (line.querySelector(".acpmux-summary-agent__kind")) throw new Error("an agent-type subtitle on the line");
    const glyph = line.querySelector<HTMLElement>(".acpmux-lineage__icon")!.getBoundingClientRect();
    const title = line.querySelector<HTMLElement>(".acpmux-summary-agent__name")!.getBoundingClientRect();
    if (title.left - glyph.right < 6) throw new Error(`the title touches its glyph (${title.left - glyph.right}px)`);
  }
}

const script = [
  {
    name: "the tray at rest",
    run: async (ctx: PlayContext) => {
      await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray .acpmux-agent-line"));
      anatomy(ctx);
    },
  },
];

const play = (settled: boolean) => async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray .acpmux-agent-line"));
  anatomy(ctx);
  const tray = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray")!;
  if (settled !== tray.hasAttribute("data-settled")) throw new Error(`settled should be ${settled}`);
  if (settled && getComputedStyle(tray).boxShadow !== "none") throw new Error("a settled tray draws no card");
};

export default agentPaneEntry({
  id: "agent-pane.subagent-row-anatomy",
  title: "Subagent row anatomy",
  area: "Agent pane",
  height: 360,
  covers: [
    "agent-session/acpmux/subagents/AgentLine.tsx",
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/subagents.css",
  ],
  experiment: { definition: trayRowLook, script },
  variants: {
    "done-one": {
      note: "One subagent finished, nothing running: one leading mark (no fork glyph), the title, a muted 1m 24s, the chevron; no general-purpose subtitle, no Done word, no card.",
      play: play(true),
      snapshot: chat(
        [
          user("Land the open fix and tidy the glyphs", 4),
          group([agent("Land the fix and glyph nits follow-up", 3, "completed", { ran: 1.4 })], 3),
          assistant("Landed, and the glyph nits are in a follow-up.", 1),
        ],
        { isWorking: false },
      ),
    },
    "running-stats": {
      note: "A running workflow: the spinner is its one glyph, its agent counts sit muted before its time (no tokens or tool uses), and the finished one under it lines its time up with it.",
      play: play(false),
      snapshot: chat(
        [
          user("Carry the composer PR and land the follow-up", 6),
          group(
            [
              agent("Carry the composer PR", 5, "running", {
                tokens: 236_600,
                toolUses: 112,
                action: "Bash",
                agents: { done: 1, started: 3 },
              }),
              agent("Land the fix and glyph nits follow-up", 4, "completed", { ran: 1.4 }),
            ],
            5,
          ),
        ],
        { isWorking: true },
      ),
    },
    mixed: {
      note: "Running, finished and failed lines together: only a state worth a word says it (Failed), muted in the meta before the time; the finished Explore agent's kind is in its tooltip, not on the line.",
      play: play(false),
      snapshot: chat(
        [
          user("Fan out the review", 8),
          group(
            [
              agent("Review the fold", 6, "running", { tokens: 48_200, toolUses: 31, action: "Read subagentFold.ts" }),
              agent("Check the docs", 7, "completed", { kind: "Explore", ran: 2.1 }),
              agent("Run the flaky suite", 7, "failed", { ran: 3.2 }),
            ],
            7,
          ),
        ],
        { isWorking: true },
      ),
    },
  },
});

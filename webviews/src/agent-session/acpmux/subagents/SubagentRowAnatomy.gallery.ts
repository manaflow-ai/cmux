// l10n-allow-file: gallery fixtures (prompts, subagent names), not shipped UI.
// One tray line's anatomy (design/chat-transcript.md "Subagent row anatomy"; Leo, 2026-10-31: "why
// is this still so ass in latest nightly", and earlier "eg a lot of these subtitles are bad"): one
// leading glyph (its own mark; no spinner on a running line with its time), the title a gap after it, one muted trailing meta and
// the time, the chevron. No agent-type subtitle; the state word then the time ("Done · 36s"), muted,
// beside the chevron; the title is the subagent's task. Settled or running, the tray sits on the
// composer's glass, joined to it, so the transcript never shows through. The arms (trayPanel.experiment.ts `trayRowLook`) place a running
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
      // Headed trays now start folded; open the list before checking row anatomy.
      await ctx.waitFor(() =>
        ctx.document.querySelector(".acpmux-running-tray .acpmux-agent-line, .acpmux-running-tray__head"),
      );
      const head = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
      if (head && head.getAttribute("aria-expanded") !== "true") {
        await ctx.click({ selector: ".acpmux-running-tray__head" });
      }
      await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray .acpmux-agent-line"));
      anatomy(ctx);
    },
  },
];

const play = (settled: boolean) => async (ctx: PlayContext) => {
  // Headed trays now start folded; open the list before checking row anatomy.
  await ctx.waitFor(() =>
    ctx.document.querySelector(".acpmux-running-tray .acpmux-agent-line, .acpmux-running-tray__head"),
  );
  const head = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
  if (head && head.getAttribute("aria-expanded") !== "true") {
    await ctx.click({ selector: ".acpmux-running-tray__head" });
  }
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray .acpmux-agent-line"));
  anatomy(ctx);
  const tray = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray")!;
  if (settled !== tray.hasAttribute("data-settled")) throw new Error(`settled should be ${settled}`);
  // Settled or not, the line sits on the composer's glass: the transcript never shows through it
  // (Leo, 2026-11-02: "this running thing now looks mildly awkward").
  if (
    getComputedStyle(tray).backgroundColor === "rgba(0, 0, 0, 0)" &&
    getComputedStyle(tray).backgroundImage === "none"
  )
    throw new Error("the tray draws a surface the transcript never shows through");
  // The state word, then the time: "Done · 36s".
  for (const line of ctx.document.querySelectorAll<HTMLElement>(".acpmux-running-tray .acpmux-agent-line")) {
    const state = line.querySelector<HTMLElement>(".acpmux-agent-line__meta")!.getBoundingClientRect();
    const time = line.querySelector<HTMLElement>(".acpmux-agent-line__time")!.getBoundingClientRect();
    if (time.width > 0 && state.right > time.left + 0.5) throw new Error("the state word comes before the time");
  }
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
    "done-task-label": {
      note: 'Leo\'s done line (2026-11-02: "this running thing now looks mildly awkward"): the title is its task, not its name or "Subagent"; Done · 36s muted beside the chevron; the composer\'s glass under it, joined to the composer.',
      play: play(true),
      snapshot: chat(
        [
          user("Review the tray and audit the stack", 4),
          group(
            [
              agent("Reviewer", 3, "completed", {
                id: "01a19ea8-7040-7e00-879d-1e267984f2f7/toolu_01H9Jk66ek2xu2m2SaOS09M1",
                name: "01a19ea8-7040-7e00-879d-1e267984f2f7/toolu_01H9Jk66ek2xu2m2SaOS09M1",
                task: "Review the subagent tray row",
                ran: 0.6,
              }),
            ],
            3,
          ),
          assistant("The review is back: two nits, both fixed.", 1),
        ],
        { isWorking: false },
      ),
    },
    "running-one": {
      note: "One subagent running: its own mark as its glyph, its task as the title, its elapsed time alone (no spinner, no Running word; Leo, 2026-11-03) beside Stop and the chevron.",
      play: play(false),
      snapshot: chat(
        [
          user("Audit the bottom stack", 2),
          group(
            [
              agent("Auditor", 1.2, "running", {
                task: "Audit the bottom stack for motion that skips the tokens",
                action: "Read bottomStack.css",
              }),
            ],
            1.2,
          ),
        ],
        { isWorking: true },
      ),
    },
    "long-name": {
      note: "A long task cuts with an ellipsis before the state and the time, which never cut.",
      play: play(false),
      snapshot: chat(
        [
          user("Fan out the review", 4),
          group(
            [
              agent("Long", 3, "running", {
                task: "Read every subagent tray test and gallery fixture, then list each assertion that encodes the time before the state word, with its file and line",
              }),
              agent("Short", 3, "completed", { task: "Check the docs", ran: 0.9 }),
            ],
            3,
          ),
        ],
        { isWorking: true },
      ),
    },
    "running-stats": {
      note: "A running workflow: its own mark is its one glyph (no spinner), its agent counts sit muted before its time (no tokens or tool uses), and the finished one under it lines its time up with it.",
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

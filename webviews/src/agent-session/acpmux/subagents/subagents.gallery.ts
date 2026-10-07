// l10n-allow-file: gallery fixtures (sample prompts, subagent names and tasks), not shipped UI.
// A batch of subagents inline in the transcript (SubagentGroup.tsx): the group row in each state,
// as the snapshot rows the pane receives after direct.ts folds a session's subagent updates; an
// open group's list (SubagentListRow), opened by a click; and the header summary's Subagents
// section, which reads the same groups.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, summary, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";

const prompt = "Audit the fetch helper: retries, errors, timeouts and tests";

/** A subagent started `minutes` ago, ended `ran` minutes later when it is no longer running. */
function agent(
  name: string,
  minutes: number,
  state: Subagent["state"] = "running",
  fields: Partial<Subagent> & { ran?: number } = {},
): Subagent {
  const { ran = 1.5, ...rest } = fields;
  return {
    id: `agent-${name.toLowerCase().replaceAll(" ", "-")}`,
    parent: null,
    name,
    task: name,
    state,
    startedAt: minutesAgo(minutes),
    ...(state !== "running" && { endedAt: minutesAgo(minutes - ran) }),
    ...rest,
  };
}

const group = (agents: Subagent[], minutes: number) => row(SUBAGENTS, minutes, { subagents: agents });

const AUDIT = ["Retry policy", "Error parsing", "Timeouts", "Test coverage"];

const MIXED = chat(
  [
    user(prompt, 4),
    group(
      [
        agent("Retry policy", 3.8, "completed", { ran: 1.2 }),
        agent("Error parsing", 3.8, "completed", { ran: 2 }),
        agent("Timeouts", 3.8, "failed", { ran: 0.6 }),
        agent("Test coverage", 3.8, "running", { action: "bun test src/net" }),
      ],
      3.8,
    ),
  ],
  { isWorking: true },
);

const PACKAGES = ["net", "ui", "store", "router", "i18n", "icons", "tests"];
const MANY = chat(
  [
    user("Review each package for unused exports", 3),
    group(
      PACKAGES.map((name, index) =>
        agent(`Package ${name}`, 2.9, index < 3 ? "completed" : "running", { ran: 0.5 + index * 0.2 }),
      ),
      2.9,
    ),
  ],
  { isWorking: true },
);

const DONE = chat([
  user(prompt, 12),
  group(
    AUDIT.map((name, index) => agent(name, 11.8, "completed", { ran: 1 + index * 0.5 })),
    11.8,
  ),
  assistant("All four areas are covered. Two timeouts are too short; the rest is fine.", 9),
  summary(9, { status: "completed", durationMs: 180_000 }),
]);

/** Opens the first group and waits for its `count` subagent lines. */
const openGroup = (count: number) => async (ctx: PlayContext) => {
  await ctx.click({ selector: ".cv-subagents" });
  await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-subagent").length === count);
};

export default agentPaneEntry({
  id: "agent-pane.subagents",
  title: "Subagents",
  area: "Agent pane",
  height: 420,
  // The header and the composer stay put while a group opens below or a popover opens over them.
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentGroup.tsx",
    "agent-session/acpmux/summary/SummaryButton.tsx#SummaryButton",
    "agent-session/acpmux/summary/SummaryPopover.tsx#SummaryPopover",
    "agent-session/acpmux/summary/SummarySection.tsx#SummarySection",
    "agent-session/acpmux/summary/SubagentStack.tsx#SubagentStack",
  ],
  variants: {
    running: {
      note: "Four subagents started together, all still working.",
      snapshot: chat(
        [
          user(prompt, 2),
          group(
            AUDIT.map((name) => agent(name, 1.8, "running", { action: `Read ${name.toLowerCase()} code` })),
            1.8,
          ),
        ],
        { isWorking: true },
      ),
    },
    mixed: { note: "Some done, one failed, one still working.", snapshot: MIXED },
    single: {
      note: "One subagent: no avatar stack overflow, singular count.",
      snapshot: chat([user("Find every caller of request()", 1), group([agent("Find callers", 0.9)], 0.9)], {
        isWorking: true,
      }),
    },
    many: { note: "Seven subagents: three avatars, then +4.", snapshot: MANY },
    done: { note: "An ended turn: the group stays in view above the reply, outside Worked for.", snapshot: DONE },
    stopped: {
      note: "A turn stopped while subagents ran: cancelled and disconnected.",
      snapshot: chat([
        user(prompt, 6),
        group(
          [
            agent("Retry policy", 5.8, "completed", { ran: 0.8 }),
            agent("Error parsing", 5.8, "cancelled", { ran: 1.1 }),
            agent("Timeouts", 5.8, "disconnected", { ran: 0.4 }),
          ],
          5.8,
        ),
        summary(4.7, { status: "cancelled" }),
      ]),
    },
    "two-batches": {
      note: "Text between spawns starts a second group.",
      snapshot: chat(
        [
          user(prompt, 8),
          group([agent("Retry policy", 7.8, "completed"), agent("Error parsing", 7.8, "completed", { ran: 2 })], 7.8),
          assistant("Both reviews are in. Now checking timeouts and tests in parallel.", 5.6),
          group([agent("Timeouts", 5.5), agent("Test coverage", 5.5, "running", { action: "bun test src/net" })], 5.5),
        ],
        { isWorking: true },
      ),
    },
    open: {
      note: "The mixed group opened: a line per subagent with its state or current action.",
      snapshot: MIXED,
      play: openGroup(4),
    },
    "open-many": {
      note: "Seven subagents opened: the list grows below, the lines above stay put.",
      height: 640,
      snapshot: MANY,
      play: openGroup(PACKAGES.length),
    },
    "open-done": {
      note: "An ended turn's group opened: the reply below moves down without a layout shift.",
      snapshot: DONE,
      play: openGroup(AUDIT.length),
    },
    summary: {
      note: "The header summary: its Subagents section stacks the groups' subagents with their counts.",
      snapshot: MIXED,
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-summary-button" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-summary-popover .acpmux-summary-subagents"));
      },
    },
  },
});

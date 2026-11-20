// l10n-allow-file: gallery fixtures (sample prompts, subagent names and tasks), not shipped UI.
// Settings > Agent Chat > Subagents (`agentPane.display.subagents`, chatDisplay.ts): a Claude chat
// whose native Task/Agent calls started subagents (acpmux sends `subagent_spawned`, and the
// subagent fold draws the subagent in place of the call). Under `transcript` each batch draws as a
// card in the transcript where it started (SubagentGroup.tsx), running, done or failed, as Claude's
// desktop app nests them under the parent chat (Leo: "Claude Code (and the Claude desktop app's Code
// tab) shows subagents and sub-sessions nested under the parent chat."), and the running tray over
// the composer has no line for them. `tray`, the default, is today's look, for comparison.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, summary, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo, recentRun } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS_DISPLAY_KEY } from "../chatDisplay";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { RUNNING_TRAY_LINE } from "./subagentSelectors";

const prompt = "Audit the fetch helper: retries, errors, timeouts and tests";

/** A Claude Task subagent started `minutes` ago, ended `ran` minutes later when it is no longer running. */
function agent(
  name: string,
  kind: string,
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
    kind,
    state,
    ...(state === "running" ? { startedAt: minutesAgo(minutes) } : recentRun(minutes, ran)),
    ...rest,
  };
}

const group = (agents: Subagent[], minutes: number) => row(SUBAGENTS, minutes, { subagents: agents });

/** A running turn: one subagent done, one failed, two still working. */
const MIXED = chat(
  [
    user(prompt, 4),
    assistant("I'll split the audit across four subagents.", 3.9),
    group(
      [
        agent("Retry policy", "Explore", 3.8, "completed", { ran: 1.2 }),
        agent("Error parsing", "general-purpose", 3.8, "running", { action: "Read src/net/errors.ts" }),
        agent("Timeouts", "Explore", 3.8, "failed", { ran: 0.6 }),
        agent("Test coverage", "general-purpose", 3.8, "running", { action: "bun test src/net" }),
      ],
      3.8,
    ),
  ],
  { isWorking: true },
);

/** A running turn: every subagent still working. */
const RUNNING = chat(
  [
    user("Find where retries are configured and check the docs agree", 2),
    group(
      [
        agent("Find retry config", "Explore", 1.9, "running", { action: "Search for retryCount" }),
        agent("Check the docs", "general-purpose", 1.9, "running", { action: "Read docs/net.md" }),
      ],
      1.9,
    ),
  ],
  { isWorking: true },
);

/** An ended turn: the card stays where the subagents started, above the reply. */
const DONE = chat([
  user(prompt, 12),
  group(
    [
      agent("Retry policy", "Explore", 11.8, "completed", { ran: 1 }),
      agent("Error parsing", "general-purpose", 11.8, "completed", { ran: 1.5 }),
      agent("Timeouts", "Explore", 11.8, "failed", { ran: 0.6 }),
    ],
    11.8,
  ),
  assistant("Two of three audits finished; the timeouts audit failed, so I read that code myself.", 9),
  summary(9, { status: "completed", durationMs: 180_000 }),
]);

const transcript = { [SUBAGENTS_DISPLAY_KEY]: "transcript" };

/** The subagents draw as a card in the transcript, and the tray has no line for them. */
const inTranscript = (count: number) => async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-subagents").length > 0);
  if (ctx.document.querySelector(RUNNING_TRAY_LINE))
    throw new Error("a subagent drawn in the transcript must not also have a running tray line");
  // A group of a working turn starts open: a line per subagent.
  await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-subagent").length === count);
};

export default agentPaneEntry({
  id: "agent-pane.subagents-display",
  title: "Subagents setting: tray or transcript",
  area: "Agent pane",
  height: 520,
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: ["agent-session/acpmux/subagents/SubagentGroup.tsx"],
  variants: {
    tray: {
      note: "The default (Subagents: In the Running Tray): running subagents sit in the tray over the composer.",
      snapshot: MIXED,
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(RUNNING_TRAY_LINE));
        if (ctx.document.querySelector(".cv-subagents"))
          throw new Error("the default draws no subagent card in the transcript");
      },
    },
    "transcript-mixed": {
      note: "Subagents: In the Transcript: Claude's Task subagents as a card where they started, done, failed and working.",
      snapshot: MIXED,
      display: transcript,
      play: inTranscript(4),
    },
    "transcript-running": {
      note: "Subagents: In the Transcript, every subagent still working: the card is open, a line per agent.",
      snapshot: RUNNING,
      display: transcript,
      play: inTranscript(2),
    },
    "transcript-done": {
      note: "Subagents: In the Transcript after the turn ended: the card stays above the reply, one failed.",
      snapshot: DONE,
      display: transcript,
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".cv-subagents"));
        if (ctx.document.querySelector(RUNNING_TRAY_LINE))
          throw new Error("a subagent drawn in the transcript must not also have a running tray line");
      },
    },
  },
});

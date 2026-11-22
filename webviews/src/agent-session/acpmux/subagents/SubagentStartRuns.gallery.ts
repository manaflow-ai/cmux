// l10n-allow-file: gallery fixtures (prompts and subagent names), not shipped UI.
// A group's start lines (SubagentStartedLine.tsx, runningTray.ts `withSubagentLines`). Leo,
// 2026-11-22, with a picture of his chat's "lane_place: brief path not inlined started working"
// line: "in these cases currently ... there's like a secondary animation that shifts as it
// recalculates to shrink stuff. idk. with better designs this won't happen". One line named every
// agent of a group, so each agent that joined rewrote it: the names already drawn shrank to make
// room and "started working" moved. Now a line names the agents one record started and no others;
// an agent started later gets its own line under the rows that came before it, and a line drawn
// never changes. Synthetic data.
import { agentPaneEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { activity, assistant, chat, row, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../model";
import { SUBAGENTS, type Subagent } from "./subagentFold";

const NAMES = [
  "lane_place: brief path not inlined",
  "Audit chat row renderings",
  "Prepush gate cost and offload",
  "Find palette/onboarding registration",
  "Build non-admin AWS runner image",
];

/// Agent `index`, started `minutes` ago.
const agent = (index: number, minutes: number): Subagent => ({
  id: `gallery-session/toolu_start_runs_${index}`,
  parent: null,
  name: NAMES[index]!,
  task: NAMES[index]!,
  kind: "general-purpose",
  prompt: NAMES[index]!,
  state: "running",
  background: true,
  startedAt: minutesAgo(minutes),
});

const opening = (agents: Subagent[], between: AcpmuxRow[] = []): AcpmuxRow[] => [
  user("Fix the lane tools, each in its own subagent, and keep going while they run", 6, { id: "runs-prompt" }),
  assistant("Starting them now.", 5.9, { id: "runs-starting" }),
  row(SUBAGENTS, 5.8, { id: "runs-group", subagents: agents }),
  ...between,
];

const reads = (minutes: number, id: string) =>
  activity([tool("Read tools/lane_place.py", "read", "completed")], minutes, { id });

export default agentPaneEntry({
  id: "agent-pane.subagent-start-runs",
  title: "Subagent start lines",
  area: "Agent pane",
  height: 420,
  covers: [
    "agent-session/acpmux/subagents/SubagentStartedLine.tsx",
    "agent-session/acpmux/subagents/runningTray.ts#withSubagentLines",
  ],
  variants: {
    one: {
      note: "Leo's line: one background agent, its whole name in the chip.",
      snapshot: chat(opening([agent(0, 5.8)]), { isWorking: true }),
    },
    "one-after-another": {
      note: "Three agents started seconds apart: three lines, each whole; the first never shrank for the others.",
      snapshot: chat(opening([agent(0, 5.8), agent(1, 5.75), agent(2, 5.7)]), { isWorking: true }),
    },
    "together-then-later": {
      note: "Two agents one record started share a line; the one started later has its own under it.",
      snapshot: chat(opening([agent(0, 5.8), agent(1, 5.8), agent(2, 5.5)]), { isWorking: true }),
    },
    "later-after-rows": {
      note: "An agent started after the chat read a file and answered: its line sits under those rows, where it arrived.",
      snapshot: chat(
        opening(
          [agent(0, 5.8), agent(2, 5)],
          [reads(5.5, "runs-read"), assistant("The brief's path is read in `place()`.", 5.3, { id: "runs-note" })],
        ),
        { isWorking: true },
      ),
    },
    "five-together": {
      note: "Five agents one record started: one line, its chips cut to fit from the first frame.",
      snapshot: chat(opening(NAMES.map((_, index) => agent(index, 5.8))), { isWorking: true }),
    },
  },
});

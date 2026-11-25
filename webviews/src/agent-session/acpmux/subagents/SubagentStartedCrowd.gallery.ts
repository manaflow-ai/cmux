// l10n-allow-file: gallery fixtures (prompts, subagent tasks), not shipped UI.
// Seven subagents starting at once (SubagentStartedLine.tsx, startedLineCrowd.experiment.ts). Every
// name was a chip on one line, cut to a letter or two each. Leo, 2026-11-22: "this is so fucking
// awkward as ui. unilaterally, literally anything else would be a motherfucking improvement. go
// debate figure shit out. try some variants." Compare the arms with the entry's experiment.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { startedLineCrowd } from "./startedLineCrowd.experiment";

const running = (task: string, minutes: number): Subagent => ({
  id: `agent-${task.toLowerCase().replaceAll(/[^a-z]+/g, "-")}`,
  parent: null,
  name: "general-purpose",
  task,
  kind: "general-purpose",
  action: "Read the code",
  state: "running",
  background: true,
  startedAt: minutesAgo(minutes),
});

const seven = [
  "Mango sweep of the settings pane",
  "iOS build of the companion app",
  "inbox triage for open asks",
  "Theme pack loader review",
  "Sidebar scroll jank profile",
  "Empty state copy audit",
  "Linux installer verify",
].map((task) => running(task, 3));

const scene = (agents: Subagent[]) =>
  chat(
    [
      user("Fan out: one subagent per open item on the list", 4),
      row(SUBAGENTS, 3, { subagents: agents }),
      assistant("They run in the background; I'll gather what each one finds.", 1),
    ],
    { isWorking: true },
  );

const line = (ctx: PlayContext) => ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-started"));

export default agentPaneEntry({
  id: "agent-pane.subagent-started-crowd",
  title: "Many subagents started at once",
  area: "Agent pane",
  height: 320,
  widths: { narrow: 360 },
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/SubagentStartedLine.tsx",
    "agent-session/acpmux/subagents/startedLineCrowd.experiment.ts",
  ],
  experiment: {
    definition: startedLineCrowd,
    script: [{ name: "the start line", run: line }],
  },
  variants: {
    seven: {
      note: "Seven subagents start at once: one icon each, then `7 subagents started working`; each icon names and opens its own.",
      play: line,
      snapshot: scene(seven),
    },
    three: {
      note: "Three at once, the fewest the crowd look takes.",
      play: line,
      snapshot: scene(seven.slice(0, 3)),
    },
    two: {
      note: "Two still read as a sentence: `A and B started working`.",
      play: line,
      snapshot: scene(seven.slice(0, 2)),
    },
  },
});

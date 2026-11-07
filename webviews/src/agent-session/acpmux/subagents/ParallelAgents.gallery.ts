// l10n-allow-file: gallery fixtures (prompts, subagent tasks and replies), not shipped UI.
// Four background agents at once, each in its own state, in the running tray (SubagentTray.tsx,
// AgentLine.tsx). Leo, 2026-11-03, watching Claude Code Desktop run background agents in parallel:
// "yo wtf i want this kind of feature in cmux-next too", then, on keeping them out of the
// transcript: "Tray only, richer". Each running line says its title, its state (one that stopped to
// wait on background work of its own says so), its time and what it did last; the agents that ended
// leave their quiet line in the transcript. The `?mock` daemon's `mock-parallel-agents` chat
// (mockFixture.ts) plays the same scene live. Each line is one row (Leo, 2026-11-04: "how Claude code
// just has one lines too"), and the failed line leads the list (trayAttention.ts). Compare where the
// latest line sits (trayLatest.experiment.ts).
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, summary, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { trayLatestLook } from "./trayLatest.experiment";

const agent = (slug: string, task: string, minutes: number, fields: Partial<Subagent> = {}): Subagent => ({
  id: `agent-${slug}`,
  parent: null,
  name: "general-purpose",
  task,
  kind: "general-purpose",
  state: "running",
  background: true,
  startedAt: minutesAgo(minutes),
  ...fields,
});

const REPORT = [
  "## Publish step",
  "The publish step spends 4m 10s re-uploading the DMG it already uploaded.",
  "",
  "- The upload step runs twice: once in `build-nightly-app`, once in `publish`.",
  "- Dropping the second upload saves about 4 minutes per nightly.",
  "",
  "**Fix:** reuse the first upload's artifact in `publish`.",
].join("\n");

const FOUR: Subagent[] = [
  agent("cache", "Measure the build cache", 9, { action: "Read warm-sources.json" }),
  agent("signing", "Time the signing step", 9, {
    state: "completed",
    endedAt: minutesAgo(1.5),
    lastMessage: "Started the notarization run; I'll report when it settles.",
    reaction: { turn: "bg-signing", weight: "silent", interim: true },
  }),
  agent("publish", "Check the publish step", 9, { state: "completed", endedAt: minutesAgo(3), result: REPORT }),
  agent("compile", "Profile the Release compile", 9, {
    state: "failed",
    endedAt: minutesAgo(5),
    retryable: true,
    error: "Agent terminated early due to an API error. The request timed out after 600s.",
  }),
];

const scene = (agents: Subagent[]) =>
  chat([
    user("Audit the nightly pipeline end to end, in parallel.", 10),
    assistant("I'll run four agents at once: the cache, signing, publish and the compile.", 9.8),
    row(SUBAGENTS, 9, { subagents: agents }),
    assistant("Two agents are still on it; the publish step's report is in.", 2.5),
    summary(2.4, { status: "completed", durationMs: 30_000, toolCount: 4 }),
  ]);

// A lone line has no header (SubagentTray.tsx `headed`): open the header only where there is one.
const expanded = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray"));
  const head = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
  if (head && head.getAttribute("aria-expanded") !== "true")
    await ctx.click({ selector: ".acpmux-running-tray__head" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray .acpmux-agent-line"));
};

export default agentPaneEntry({
  id: "agent-pane.parallel-agents",
  title: "Parallel agents in the running tray",
  area: "Agent pane",
  height: 620,
  widths: { narrow: 360 },
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: [
    "agent-session/acpmux/subagents/AgentLine.tsx",
    "agent-session/acpmux/subagents/trayDetail.ts",
    "agent-session/acpmux/subagents/trayLatest.experiment.ts",
    "agent-session/acpmux/subagents/trayAttention.ts",
  ],
  experiment: {
    definition: trayLatestLook,
    script: [{ name: "the open tray", run: expanded }],
  },
  variants: {
    "four-agents": {
      note: "The pick. Two run (one stopped to wait on its own background work), one finished, one failed: each line is one row, its title, what it did last muted after it, then its state, time and Stop in their columns. The failed line leads, so the list's cap never hides it; the ended ones leave their quiet lines in the transcript.",
      play: expanded,
      snapshot: scene(FOUR),
    },
    "all-running": {
      note: "Four agents still running, each with its latest step after its title on its one row; the time and Stop keep their columns.",
      play: expanded,
      snapshot: scene(
        FOUR.map((one, index) => ({
          ...one,
          state: "running",
          endedAt: undefined,
          reaction: undefined,
          action: [
            "Read warm-sources.json",
            "Running gh run view 81234",
            "Grep upload publish.yml",
            "Read the compile timings",
          ][index],
        })),
      ),
    },
    "own-work": {
      note: "One agent that stopped to wait on background work of its own: 'Waiting on its background work', its clock still going, its last words after its title, and no 'Subagent finished' line yet.",
      play: expanded,
      snapshot: scene([FOUR[1]!]),
    },
  },
});

// l10n-allow-file: gallery fixtures, not shipped UI.
// The composer hat under bursts of calls (gallery/fixtures/HatBurstStage.tsx), one variant per
// hatStep.experiment.ts arm and Compare arms for all at once (Leo, 2026-11-22: "perhaps there is a case
// to be made for e.g. we dont show the exact calls, ever, at the top"). design/composer-hat-calm.md has
// the cases and numbers each arm was judged on.
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { HatBurstScene } from "../../../gallery/fixtures/HatBurstStage";
import { hatStepLook, type HatStepArm } from "./hatStep.experiment";

const clockPast = (ms: number) => async (ctx: PlayContext) => {
  await ctx.waitFor(() => {
    const text = ctx.document.querySelector('[data-stage="clock"]')?.textContent ?? "0";
    return Number.parseFloat(text) * 1000 >= ms;
  });
};

const script = [
  { name: "a single call, then a burst of 5", run: clockPast(6_500) },
  { name: "a burst of 50 calls 60 ms apart", run: clockPast(13_500) },
  { name: "a long command, a fetch, another command", run: clockPast(21_000) },
];

type Props = { scene?: HatBurstScene; arm?: HatStepArm };
const lone = (arm: HatStepArm): Props => ({ scene: "lone", arm });
const parallel = (arm: HatStepArm): Props => ({ scene: "parallel", arm });

export default componentEntry<Props>({
  id: "agent-pane.hat-burst",
  title: "Composer hat under a burst of calls: what a running subagent says it does",
  area: "Agent pane",
  covers: [
    "agent-session/acpmux/subagents/HatStepSlot.tsx",
    "agent-session/acpmux/subagents/hatStep.ts",
    "agent-session/acpmux/subagents/SubagentTray.tsx",
  ],
  load: () => import("../../../gallery/fixtures/HatBurstStage").then((module) => module.HatBurstStage),
  pane: true,
  height: 300,
  experiment: { definition: hatStepLook, script },
  variants: {
    phase: { note: "Default: one word for the kind of call, fixed width, held 1.6 s.", props: lone("phase") },
    quiet: { note: "Nothing per call: the task and its time.", props: lone("quiet") },
    sampled: { note: "The exact call at most every 2.5 s, cut to a fixed width.", props: lone("sampled") },
    exact: { note: "Before: every call's exact title slides in as it comes.", props: lone("exact") },
    "parallel-phase": { note: "Three subagents at once: the phase word per line.", props: parallel("phase") },
    "parallel-exact": { note: "Three subagents at once, before.", props: parallel("exact") },
    compare: { note: "No arm pinned: Compare arms draws every arm on the same timeline.", props: { scene: "lone" } },
  },
});

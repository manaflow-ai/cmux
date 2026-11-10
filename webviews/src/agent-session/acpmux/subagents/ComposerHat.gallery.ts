// l10n-allow-file: gallery fixtures, not shipped UI.
// The tucked composer hat (TrayPullTab.tsx) on its own over a stand-in composer: just the chevron,
// centred on the composer, while nothing runs; it grows into chevron and count when work runs, and
// shrinks back when it clears, as one transition. Four arms (composerHat.experiment.ts; view
// Compare arms): grow with the count sliding out (shipped), grow with it fading in place, a crossfade,
// a badge (Leo, 2026-11-07: "if there's no running work, it should just be
// centered, right? But when there is a number, it can, like, you know, grow into that").
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { composerHatLook } from "./composerHat.experiment";

type Props = { start?: number; waits?: boolean; before?: boolean; side?: "left" | "middle" | "right" };

const stage = (name: string) => ({ selector: `[data-stage="${name}"]` });
const count = (ctx: PlayContext) => ctx.document.querySelector(".acpmux-tray-pull__count")?.textContent ?? "";

export const composerHatScript = [
  {
    name: "three start running: the hat grows into chevron and count",
    run: async (ctx: PlayContext) => {
      await ctx.click(stage("count"));
      await ctx.waitFor(() => count(ctx) === "3");
    },
  },
  {
    name: "one more: the count ticks, the width holds",
    run: async (ctx: PlayContext) => {
      await ctx.click(stage("more"));
      await ctx.waitFor(() => count(ctx) === "4");
    },
  },
  {
    name: "everything ends: the hat shrinks back to the centred chevron",
    run: async (ctx: PlayContext) => {
      await ctx.click(stage("idle"));
      await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-tray-pull__count"));
    },
  },
];

export default componentEntry<Props>({
  id: "agent-pane.composer-hat",
  title: "Composer hat: tucked tab grows with the count",
  area: "Agent pane",
  covers: ["agent-session/acpmux/subagents/TrayPullTab.tsx"],
  load: () => import("../../../gallery/fixtures/ComposerHatStage").then((module) => module.ComposerHatStage),
  pane: true,
  height: 220,
  experiment: { definition: composerHatLook, script: composerHatScript },
  variants: {
    idle: {
      note: "Nothing runs: the hat is just the chevron, centred on the composer, with no count and no room kept for one.",
      props: {},
    },
    count: {
      note: "Three run: the hat is chevron and count, still centred on the composer.",
      props: { start: 3 },
    },
    "two-digits": {
      note: "Twelve run: the hat is wider by one tabular digit and still centred.",
      props: { start: 12 },
    },
    waiting: {
      note: "A chat waits on you: the needs-you dot takes the count's place.",
      props: { start: 2, waits: true },
    },
    // The card's top line stops at the pill's rim and never runs through its glass (Leo,
    // 2026-11-09: "theres a line behind the hat toggle. i dont mean the glass rim i mean there's a
    // line in the midle"). Theme switch for light and dark; test/composer-hat-line-gap.test.ts.
    "line-seven": {
      note: "Seven run (^ 7): the card's top line runs up to the pill's rim on each side, none behind its glass.",
      props: { start: 7 },
    },
    "line-many": {
      note: "128 run (^ 99+): the widest pill, and the gap in the line is as wide.",
      props: { start: 128 },
    },
    "line-left": {
      note: "The handle at the left (agentPane.display.trayHandle): the gap goes with it.",
      props: { start: 7, side: "left" },
    },
    "line-right": {
      note: "The handle at the right: the gap goes with it.",
      props: { start: 7, side: "right" },
    },
    "line-before": {
      note: "Before: the card's top line ran through the middle of the pill's glass.",
      props: { start: 7, before: true },
    },
    play: {
      note: "Idle → three run → four → idle: the hat grows into the count and shrinks back as one transition.",
      props: {},
      play: async (ctx) => {
        for (const step of composerHatScript) await step.run(ctx);
      },
    },
  },
});

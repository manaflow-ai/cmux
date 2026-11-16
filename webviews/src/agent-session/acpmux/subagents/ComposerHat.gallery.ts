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

type Props = {
  start?: number;
  waits?: boolean;
  before?: boolean;
  side?: "left" | "middle" | "right";
  surface?: "card" | "queue" | "codex-strip";
  narrow?: boolean;
  tucked?: boolean;
  bridge?: "none" | "seated" | "perched" | "before";
};

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
    // The gap follows the pill on every part it sits on, whatever that part's inset from the tab's
    // column: a narrow card reaches 8 px past it, Codex's location strip sits 22 px inside it, and a
    // queue's line moves on the pill's clock with it.
    "line-narrow": {
      note: "A narrow pane (under 298 px): the card reaches 8 px past the tab's column, and the gap stays under the pill.",
      props: { start: 7, narrow: true },
    },
    "line-narrow-left": {
      note: "A narrow pane with the handle at the left: the gap sits under the pill, not 8 px off it.",
      props: { start: 7, narrow: true, side: "left" },
    },
    "line-narrow-right": {
      note: "A narrow pane with the handle at the right.",
      props: { start: 7, narrow: true, side: "right" },
    },
    "line-strip": {
      note: "Codex's location strip under the pill, 22 px in from the card's sides: its top line stops at the pill.",
      props: { start: 7, surface: "codex-strip" },
    },
    "line-strip-left": {
      note: "Codex's location strip with the handle at the left: the gap sits under the pill, not 22 px off it.",
      props: { start: 7, surface: "codex-strip", side: "left" },
    },
    "line-strip-right": {
      note: "Codex's location strip with the handle at the right.",
      props: { start: 7, surface: "codex-strip", side: "right" },
    },
    "line-strip-narrow-left": {
      note: "Codex's strip in a narrow pane, the handle at the left.",
      props: { start: 7, surface: "codex-strip", narrow: true, side: "left" },
    },
    "line-queue": {
      note: "A queued prompt under the pill: the queue's top line stops at the pill's rim.",
      props: { start: 7, surface: "queue" },
    },
    "line-queue-many": {
      note: "128 run (^ 99+) over a queue: the queue's gap is the widest pill's width.",
      props: { start: 128, surface: "queue" },
    },
    "line-queue-narrow-left": {
      note: "A queue in a narrow pane, the handle at the left: the queue reaches 8 px past the column too.",
      props: { start: 7, surface: "queue", narrow: true, side: "left" },
    },
    "line-tuck": {
      note: "Twelve run and the hat is out: Tuck the hat, and the gap is the pill's whole width from its first frame.",
      props: { start: 12, tucked: false },
    },
    // No line of the pill's own beside it (Leo, 2026-11-11: "did this line behind the count box get
    // removed yet?"): where the pill sits on the card's line. `bridge-none` ships; theme switch for
    // light and dark; test/composer-hat-line-gap.test.ts.
    "bridge-none": {
      note: "Shipped: 41 run (^ 41) and the pill hangs no stub; the card's line runs up to its rim, 2px under its middle.",
      props: { start: 41 },
    },
    "bridge-seated": {
      note: "Candidate: no stubs and no lift, the pill centred on the card's line.",
      props: { start: 41, bridge: "seated" },
    },
    "bridge-perched": {
      note: "Candidate: no stubs, the pill lifted till its foot stands on the card's line.",
      props: { start: 41, bridge: "perched" },
    },
    "bridge-before": {
      note: "Before (Leo's capture): 8px stubs at the pill's middle ran 2px over the card's line, a second line poking out on both sides.",
      props: { start: 41, bridge: "before" },
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

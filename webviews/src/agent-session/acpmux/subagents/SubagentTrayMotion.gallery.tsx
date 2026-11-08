// l10n-allow-file: gallery fixtures, not shipped UI.
// The subagent tray's motion next to a new message arriving (trayMotion.tsx; Leo 2026-10-26: "Like
// why is this not animating and, like, following along with the exact same things as everything
// else?"): the card eases in as the first subagent starts, its header ticks as a second joins, its
// list folds and opens, and it leaves on a kept snapshot when the last one ends. Three arms
// (trayMotion.experiment.ts; view Compare arms): the message's own rise (shipped), a tight fade, a
// slight spring.
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { trayMotionLook } from "./trayMotion.experiment";

type Props = { start?: number };

const stage = (name: string) => ({ selector: `[data-stage="${name}"]` });
const tray = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray:not([aria-hidden])");
const lines = (ctx: PlayContext) => ctx.document.querySelectorAll(".acpmux-running-tray:not([aria-hidden]) li").length;

const script = [
  {
    name: "the first subagent starts: the card eases in",
    run: async (ctx: PlayContext) => {
      await ctx.click(stage("start"));
      await ctx.waitFor(() => tray(ctx));
    },
  },
  {
    name: "a message arrives beside it",
    run: async (ctx: PlayContext) => {
      await ctx.click(stage("message"));
      await ctx.waitFor(() => ctx.document.querySelector(".acpmux-row--enter"));
    },
  },
  {
    name: "a second starts: a header, its count ticks, and the list folds to it",
    run: async (ctx: PlayContext) => {
      await ctx.click(stage("start"));
      await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
      await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-running-tray__fold"));
    },
  },
  {
    name: "open the list",
    run: async (ctx: PlayContext) => {
      await ctx.click({ selector: ".acpmux-running-tray__head" });
      await ctx.waitFor(() => lines(ctx) === 2);
    },
  },
  {
    name: "fold it again",
    run: async (ctx: PlayContext) => {
      await ctx.click({ selector: ".acpmux-running-tray__head" });
      await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-running-tray__fold"));
    },
  },
  {
    name: "the last ones end: the card leaves on its snapshot",
    run: async (ctx: PlayContext) => {
      await ctx.click(stage("end-all"));
      await ctx.waitFor(() => !tray(ctx));
    },
  },
];

export default componentEntry<Props>({
  id: "agent-pane.subagent-tray-motion",
  title: "Subagent tray motion",
  area: "Agent pane",
  covers: ["agent-session/acpmux/subagents/trayMotion.tsx"],
  load: () =>
    import("../../../gallery/fixtures/SubagentTrayMotionStage").then((module) => module.SubagentTrayMotionStage),
  pane: true,
  height: 420,
  checks: {
    layoutShiftMax: { value: 1, reason: "the bottom stack takes the card's height in one frame, by design" },
    anchorMovePx: { value: 400, reason: "the transcript's rows sit above the stack that grows" },
  },
  experiment: { definition: trayMotionLook, script },
  variants: {
    "enter-exit": {
      note: "Empty chat: Start subagent eases the card in as a new message rises, End all lets it go on a kept snapshot.",
      props: {},
      play: async (ctx) => {
        for (const step of script) await step.run(ctx);
      },
    },
    "start-empty": {
      note: "Empty chat, nothing played yet: press Start subagent, New message, the header and End all to watch each motion.",
      props: {},
    },
    "line-joins": {
      note: "Two subagents running, list open: a third starts and its line rises into the list on the same entrance as a new transcript row (cv-enter), not the popup's.",
      props: { start: 2 },
      play: async (ctx) => {
        // Headed trays start folded; this variant is explicitly the open-list joining case.
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
        const head = ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
        if (head?.getAttribute("aria-expanded") !== "true") {
          await ctx.click({ selector: ".acpmux-running-tray__head" });
        }
        await ctx.waitFor(() => lines(ctx) === 2);
        await ctx.click(stage("start"));
        await ctx.waitFor(() => lines(ctx) === 3);
      },
    },
    "two-running": {
      note: "Two subagents running: the header's spinner turns, and folding or opening the list moves its height on the shared fold.",
      props: { start: 2 },
    },
  },
});

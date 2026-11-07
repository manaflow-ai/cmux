// l10n-allow-file: gallery fixtures, not shipped UI.
// The composer hat keeps what ended for a while and moves its lines in and out, after Leo, 2026-11-07:
// "they, like, disappear instantly. So, like, if you have it expanded, then it just, like, it
// disappears, which is, like, bad ... the things coming, they shouldn't just, like, pop in, burst in,
// like, appear instantly, and, like, disappear instantly." A finished command stays as done with its
// time; while the hat is open nothing expires; folded, it goes after its grace (2 s here, 2 min in the
// app, trayLinger.ts). Three arms for how a line joins and leaves (hatParts.experiment.ts
// `hatRowMotionLook`; view Compare arms): height and fade (shipped), the same with a rise, fade only.
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { ComposerHatLingerState } from "../../../gallery/fixtures/ComposerHatLingerStage";
import { hatRowMotionLook } from "./hatParts.experiment";

type Props = { start?: ComposerHatLingerState; grace?: number };

const GRACE = 2_000;
const stage = (name: string) => ({ selector: `[data-stage="${name}"]` });
const head = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
const rows = (ctx: PlayContext) => [...ctx.document.querySelectorAll(".acpmux-running-tray__list > li")];
const doneLine = (ctx: PlayContext) => ctx.document.querySelector('.acpmux-agent-line[data-status="done"]');
/// Resolves after `ms`, as a wait the play measures.
const after = (ctx: PlayContext, ms: number) => {
  const until = Date.now() + ms;
  return ctx.waitFor(() => Date.now() >= until, { capMs: ms + 2_000 });
};

export const composerHatLingerScript = [
  {
    name: "open: the hat expands with the running command and subagent",
    run: async (ctx: PlayContext) => {
      await ctx.click({ selector: ".acpmux-running-tray__head" });
      await ctx.waitFor(() => head(ctx)?.getAttribute("aria-expanded") === "true");
    },
  },
  {
    name: "a subagent joins: its line grows in, the others move down with it",
    run: async (ctx: PlayContext) => {
      await ctx.click(stage("join"));
      await ctx.waitFor(() => rows(ctx).length === 3 && !ctx.document.querySelector("[data-fold-clip]"));
    },
  },
  {
    name: "the command finishes: it stays as done, with its time",
    run: async (ctx: PlayContext) => {
      await ctx.click(stage("finish"));
      await ctx.waitFor(() => doneLine(ctx));
    },
  },
  {
    name: "open past the grace: nothing expires while the hat is held",
    run: async (ctx: PlayContext) => {
      await after(ctx, GRACE + 500);
      if (!doneLine(ctx)) throw new Error("the finished command expired while the hat was open");
    },
  },
  {
    name: "a subagent leaves: its line folds away, the others move up with it",
    run: async (ctx: PlayContext) => {
      await ctx.click(stage("leave"));
      await ctx.waitFor(() => ctx.document.querySelector("li[data-leaving]"));
      await ctx.waitFor(() => !ctx.document.querySelector("li[data-leaving]"));
    },
  },
  {
    name: "fold: the finished command goes after its grace",
    run: async (ctx: PlayContext) => {
      await ctx.click({ selector: ".acpmux-running-tray__head" });
      await ctx.waitFor(() => head(ctx)?.getAttribute("aria-expanded") === "false");
      // Under the pointer the hat is still held: the stage's button takes the pointer away.
      await ctx.hover(stage("run"));
      await ctx.waitFor(() => !ctx.document.querySelector('[data-hat-done], .acpmux-agent-line[data-status="done"]'), {
        capMs: GRACE + 3_000,
      });
    },
  },
];

const variants = {
  running: {
    note: "A command and a subagent run; folded, the header names them.",
    props: { start: "running" as const, grace: GRACE },
  },
  finished: {
    note: `The command finished: it stays as a done line with its time, and goes ${GRACE / 1000} s after it ended while the hat is not held (2 min in the app).`,
    props: { start: "finished" as const, grace: 60_000 },
  },
  three: {
    note: "Three subagents and a command: open it and use the stage's buttons to watch lines join and leave.",
    props: { start: "three" as const, grace: GRACE },
  },
  play: {
    note: "Open, a subagent joins, the command finishes and stays past the grace while open, a subagent leaves, fold: the command goes.",
    props: { start: "running" as const, grace: GRACE },
    play: async (ctx: PlayContext) => {
      for (const step of composerHatLingerScript) await step.run(ctx);
    },
  },
};

export default componentEntry<Props>({
  id: "agent-pane.composer-hat-linger",
  title: "Composer hat: finished lines linger; lines join and leave",
  area: "Agent pane",
  covers: ["agent-session/acpmux/subagents/SubagentTray.tsx"],
  load: () =>
    import("../../../gallery/fixtures/ComposerHatLingerStage").then((module) => module.ComposerHatLingerStage),
  pane: true,
  height: 300,
  experiment: { definition: hatRowMotionLook, script: composerHatLingerScript },
  variants,
});

// l10n-allow-file: gallery fixtures, not shipped UI.
// The composer hat keeps what ended for a while and moves its lines in and out, after Leo, 2026-11-07:
// "they, like, disappear instantly. So, like, if you have it expanded, then it just, like, it
// disappears, which is, like, bad ... the things coming, they shouldn't just, like, pop in, burst in,
// like, appear instantly, and, like, disappear instantly." A finished command stays as done with its
// time; while the hat is open nothing expires; folded, it goes after its grace (2 s here, 2 min in the
// app, trayLinger.ts). Three arms for how a line joins and leaves (hatParts.experiment.ts
// `hatRowMotionLook`; view Compare arms): height and fade (shipped), the same with a rise, fade only.
//
// The `ttl-*` variants compare how long a finished line stays, after Leo, 2026-11-08: "i also feel
// like the hat auto removing/auto hiding stuff that's super done is maybe a bit jarring? we can maybe
// increase the ttl just a tad/not remove it for a bit if the user recently looked at it". On a short
// stage clock (3 s stands for the app's 3 min): (a) a longer grace only; (b) plus a cooldown after
// each look, with the grace counting only while the hat could be seen; (c, shipped) (b) plus lines
// that run out close together leaving together, the last ones taking the hat with them in one fold.
// `last-leaves` is the hat's own leave: it folds its height away as it fades, so the composer under it
// moves once (test/composer-hat-leave-fold.test.ts measures it per frame).
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { ComposerHatLingerState } from "../../../gallery/fixtures/ComposerHatLingerStage";
import { hatRowMotionLook } from "./hatParts.experiment";

type Props = {
  start?: ComposerHatLingerState;
  grace?: number;
  cooldown?: number;
  together?: number;
  looks?: boolean;
};

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

/// The ttl arms' stage clock: 3 s for the app's 3 min (trayLinger.ts TRAY_LINGER_MS), a cooldown and
/// a together window long enough to watch.
const TTL = { grace: 3_000, cooldown: 1_500, together: 1_000 };
const tray = { selector: ".acpmux-running-tray:not(.acpmux-running-tray--ghost)" };
/// A look just before the line is due, then away: (a) takes it right after; (b) and (c) keep it the
/// cooldown first.
const lookLate = async (ctx: PlayContext) => {
  await ctx.click(stage("finish"));
  await ctx.waitFor(() => doneLine(ctx) ?? ctx.document.querySelector(".acpmux-running-tray"));
  await ctx.hover(stage("run"));
  await after(ctx, TTL.grace - 600);
  await ctx.hover(tray);
  await after(ctx, 300);
  await ctx.hover(stage("join"));
  await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-running-tray:not(.acpmux-running-tray--ghost)"), {
    capMs: TTL.grace + TTL.cooldown + 3_000,
  });
};
/// Three lines finish a little apart; folded and out from under the pointer, they leave.
const finishApart = async (ctx: PlayContext) => {
  await ctx.hover(stage("run"));
  await ctx.click(stage("finish"));
  await after(ctx, 400);
  await ctx.click(stage("agent-finish"));
  await after(ctx, 400);
  await ctx.click(stage("agent-finish"));
  await ctx.hover(stage("run"));
  // Folded, the header says what stays; past the grace only the running subagent is left.
  await after(ctx, TTL.grace + 500);
};

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
  "ttl-only": {
    note: "(a) A longer grace only (3 min in the app, 3 s here). A look just before it is due changes nothing: the line goes right after the pointer leaves.",
    props: { start: "lone" as const, grace: TTL.grace },
    play: lookLate,
  },
  "ttl-look": {
    note: "(b) The longer grace, plus a look's cooldown (30 s in the app): after a hover, focus or the hat folding, every line stays at least the cooldown more. The grace counts only while the hat could be seen (on screen, the page showing, the window focused).",
    props: { start: "lone" as const, grace: TTL.grace, cooldown: TTL.cooldown, looks: true },
    play: lookLate,
  },
  "ttl-look-together": {
    note: "(c, shipped) (b), plus lines that run out close together leave together (20 s in the app): two subagents and a command that finished a little apart go in one change, and the last ones take the hat with them in one fold.",
    props: { start: "three" as const, ...TTL, looks: true },
    play: finishApart,
  },
  "ttl-one-by-one": {
    note: "(b) on the same three lines, for comparison: they leave one by one, the header changing each time.",
    props: { start: "three" as const, grace: TTL.grace, cooldown: TTL.cooldown, looks: true },
    play: finishApart,
  },
  "last-leaves": {
    note: "The last line takes the hat with it: the hat folds its height away as it fades, on the settle, so the composer under it moves once, never a jump.",
    props: { start: "lone" as const, grace: 1_000 },
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

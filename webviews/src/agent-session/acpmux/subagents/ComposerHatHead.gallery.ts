// l10n-allow-file: gallery fixtures, not shipped UI.
// The composer hat's header (SubagentTray.tsx) over a stand-in composer, after Leo's notes of
// 2026-11-07: one subagent heads the hat as several do, so a click expands it ("when I click into it
// and it's only the one sub-agent, like the fact that it immediately brings me over to the sub-agent
// instead of expanding it is, like, ooh"); its step hands over as a status line does, the old sliding
// up and out as the new slides in ("That animation, I like that"); a joining subagent or command
// slides its name in and rolls the count; a finished one ends in a check and its time ("the done
// whatever minutes type thing ... just doesn't look that... Great"). Two entries: where the expand
// chevron sits, and how a finished line ends (hatParts.experiment.ts; view Compare arms).
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { ComposerHatHeadState } from "../../../gallery/fixtures/ComposerHatHeadStage";
import { hatChevronLook } from "./hatParts.experiment";

type Props = { start?: ComposerHatHeadState };

const stage = (name: string) => ({ selector: `[data-stage="${name}"]` });
const head = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-running-tray__head");
const latest = (ctx: PlayContext) =>
  ctx.document.querySelector(
    ".acpmux-running-tray__latest .acpmux-tick > span:last-child, .acpmux-running-tray__latest > span:last-child",
  )?.textContent ?? "";

export const composerHatHeadScript = [
  {
    name: "its step hands over: the old slides up and out as the new slides in",
    run: async (ctx: PlayContext) => {
      await ctx.click(stage("step"));
      await ctx.waitFor(() => latest(ctx) === "Read SubagentTray.tsx");
      await ctx.click(stage("step"));
      await ctx.waitFor(() => latest(ctx) === "Grep latestLine");
    },
  },
  {
    name: "a click expands the hat in place; the line inside opens it",
    run: async (ctx: PlayContext) => {
      await ctx.click({ selector: ".acpmux-running-tray__head" });
      await ctx.waitFor(() => head(ctx)?.getAttribute("aria-expanded") === "true");
      await ctx.click({ selector: ".acpmux-running-tray__head" });
      await ctx.waitFor(() => head(ctx)?.getAttribute("aria-expanded") === "false");
    },
  },
  {
    name: "a subagent joins: its name slides in, a count appears",
    run: async (ctx: PlayContext) => {
      await ctx.click(stage("join"));
      await ctx.waitFor(() => Boolean(ctx.document.querySelector(".acpmux-running-tray__more")));
    },
  },
  {
    name: "a command joins: its name slides in, the count rolls",
    run: async (ctx: PlayContext) => {
      await ctx.click(stage("command"));
      await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__more")?.textContent === "+2 more");
    },
  },
];

const variants = {
  running: {
    note: 'One subagent runs: the header names its task, what it does now ("Bash") and its time; a click expands the hat.',
    props: { start: "running" as const },
  },
  done: {
    note: "One subagent finished: its task, then the done mark and its total at the row's end; a click expands the hat.",
    props: { start: "done" as const },
  },
  two: {
    note: "Two run: the newest by name, then +1 more and the time since the first started.",
    props: { start: "two" as const },
  },
  play: {
    note: "Steps hand over, the hat expands and folds, a subagent and then a command join.",
    props: { start: "running" as const },
    play: async (ctx: PlayContext) => {
      for (const step of composerHatHeadScript) await step.run(ctx);
    },
  },
};

export default componentEntry<Props>({
  id: "agent-pane.composer-hat-head",
  title: "Composer hat: header, one item, transitions and chevron place",
  area: "Agent pane",
  covers: ["agent-session/acpmux/subagents/SubagentTray.tsx", "agent-session/acpmux/subagents/trayMotion.tsx"],
  load: () => import("../../../gallery/fixtures/ComposerHatHeadStage").then((module) => module.ComposerHatHeadStage),
  pane: true,
  height: 240,
  experiment: { definition: hatChevronLook, script: composerHatHeadScript },
  variants,
});

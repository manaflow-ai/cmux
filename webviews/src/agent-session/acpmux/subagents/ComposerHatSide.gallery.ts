// l10n-allow-file: gallery fixtures, not shipped UI.
// Where the composer hat's marks sit (HatRail.tsx, hatSide.experiment.ts). Leo, 2026-11-21, on the
// Rolodex hat (cmux#47923): "this is uncomfortably tight. didn't we say we wanted to move these to the
// side or smth?". Each arm puts the same marks in another place beside a stand-in composer with its
// bottom line (+, mic, Send): the hat on top (today), a rail at the right or left, or the bottom line.
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { ComposerHatHeadState } from "../../../gallery/fixtures/ComposerHatHeadStage";
import { hatSideLook } from "./hatSide.experiment";

type Props = { start?: ComposerHatHeadState; standIn?: boolean };

// The nth mark, in the hat's header (the `top` arm) or the rail: both carry the Rolodex key.
const mark = (index: number) => `[data-rolodex-key]:nth-child(${index + 1})`;
// A narrow hat (the `top` arm at 360) folds its marks into fewer, so the pointer takes the last one there.
const onMark = (index: number) => async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector("[data-rolodex-key]"));
  const drawn = ctx.document.querySelectorAll("[data-rolodex-key]").length;
  await ctx.hover({ selector: mark(Math.min(index, drawn - 1)) });
  await ctx.waitFor(() => ctx.document.querySelector("[data-rolodex-key][data-peeked]"));
};
const focusMark = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector("[data-rolodex-key]"));
  await ctx.focus({ selector: mark(0) });
};
const openList = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-hat-rail__list, .acpmux-running-tray__head"));
  await ctx.click({ selector: ".acpmux-hat-rail__list, .acpmux-running-tray__head" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray[data-open]"));
};

export default componentEntry<Props>({
  id: "agent-pane.composer-hat-side",
  title: "Composer hat: on top or to the side",
  area: "Agent pane",
  covers: [
    "agent-session/acpmux/subagents/HatRail.tsx",
    "agent-session/acpmux/subagents/hatRail.css",
    "agent-session/acpmux/subagents/hatSide.experiment.ts",
    "agent-session/acpmux/subagents/SubagentTray.tsx",
  ],
  load: () => import("../../../gallery/fixtures/ComposerHatHeadStage").then((module) => module.ComposerHatHeadStage),
  pane: true,
  height: 320,
  widths: { narrow: 360 },
  experiment: { definition: hatSideLook, script: [{ name: "the pointer on the second mark", run: onMark(1) }] },
  variants: {
    rest: {
      note: "Two subagents and a command running: where their marks sit beside the composer.",
      props: { start: "two-and-command", standIn: true },
    },
    "second-mark": {
      note: "The pointer on the second mark: it lifts and names that subagent and what it does now.",
      props: { start: "two-and-command", standIn: true },
      play: onMark(1),
    },
    "command-mark": {
      note: "The pointer on the commands' mark: it names the command; a click opens its terminal.",
      props: { start: "two-and-command", standIn: true },
      play: onMark(2),
    },
    "keyboard-focus": {
      note: "The first mark focused from the keyboard: its ring shows and it names its line.",
      props: { start: "two-and-command", standIn: true },
      play: focusMark,
    },
    "list-open": {
      note: "The list control (or the hat's header) opens every line over the composer.",
      props: { start: "two-and-command", standIn: true },
      play: openList,
    },
  },
});

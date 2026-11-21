// l10n-allow-file: gallery fixtures, not shipped UI.
// The shown composer hat's tuck control at its top middle (SubagentTray.tsx `onTuck`), over a stand-in
// composer. Leo, 2026-11-14, on the small chevron over "2 done…": "the tuck away chevron
// clickability/visuals should be improved somehow". Three looks (hatTuck.experiment.ts; view Compare
// arms): a tab hanging from the hat's top edge (picked), the tucked hat's glass pill, a band along
// the edge. Each variant shows it revealed (the pointer on the hat), hovered, pressed and focused.
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { ComposerHatHeadState } from "../../../gallery/fixtures/ComposerHatHeadStage";
import { hatTuckLook } from "./hatTuck.experiment";

type Props = { start?: ComposerHatHeadState; tuck?: boolean };

const TUCK = { selector: ".acpmux-running-tray__tuck" };
const shown = (ctx: PlayContext) => {
  const tuck = ctx.document.querySelector(".acpmux-running-tray__tuck");
  return tuck !== null && getComputedStyle(tuck).opacity === "1";
};

/// The pointer on the hat's header, away from the control: the hover reveal shows it at rest.
const revealed = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__head"));
  await ctx.hover({ selector: ".acpmux-running-tray__title" });
  await ctx.waitFor(() => shown(ctx));
};
const hovered = async (ctx: PlayContext) => {
  await revealed(ctx);
  await ctx.hover(TUCK);
};
const pressed = async (ctx: PlayContext) => {
  await hovered(ctx);
  await ctx.pointer.down(TUCK);
};
const focused = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray__tuck"));
  await ctx.focus(TUCK);
  await ctx.waitFor(() => shown(ctx));
};

export default componentEntry<Props>({
  id: "agent-pane.composer-hat-tuck",
  title: "Composer hat: the tuck control",
  area: "Agent pane",
  covers: ["agent-session/acpmux/subagents/SubagentTray.tsx", "agent-session/acpmux/subagents/hatTuck.experiment.ts"],
  load: () => import("../../../gallery/fixtures/ComposerHatHeadStage").then((module) => module.ComposerHatHeadStage),
  pane: true,
  height: 240,
  widths: { narrow: 360 },
  experiment: { definition: hatTuckLook, script: [{ name: "the pointer on the hat", run: revealed }] },
  variants: {
    revealed: {
      note: "The pointer on the hat: the tuck control shows at its top middle, at rest.",
      props: { start: "done", tuck: true },
      play: revealed,
    },
    hover: {
      note: "The pointer on the tuck control: its surface lights and its chevron takes the text colour.",
      props: { start: "done", tuck: true },
      play: hovered,
    },
    pressed: {
      note: "Pressed: the surface darkens until the click lands.",
      props: { start: "done", tuck: true },
      play: pressed,
    },
    focus: {
      note: "Keyboard focus: the control shows, outlined in the accent, without the pointer on the hat.",
      props: { start: "two", tuck: true },
      play: focused,
    },
  },
});

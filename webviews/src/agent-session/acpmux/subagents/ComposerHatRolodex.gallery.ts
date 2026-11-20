// l10n-allow-file: gallery fixtures, not shipped UI.
// The composer hat's stacked marks as a Rolodex (SubagentTray.tsx, hatRolodex.experiment.ts). Leo,
// 2026-11-20, on Lawrence's "ui for opening subagents is very confusing": "thumb through them like a
// Rolodex ... if you hover over them ... there's a slight pop ... the text itself maybe changes like on
// the top of the composer hat ... you can click into them and be able to open up that sub-agent". Each
// variant puts the pointer on one mark: the header names that line; a click on the mark opens it.
import { componentEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { ComposerHatHeadState } from "../../../gallery/fixtures/ComposerHatHeadStage";
import { hatRolodexLook } from "./hatRolodex.experiment";

type Props = { start?: ComposerHatHeadState };

const onMark = (index: number) => async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelectorAll("[data-rolodex-key]").length > index);
  await ctx.hover({ selector: `.acpmux-running-tray__thumb:nth-child(${index + 1})` });
  await ctx.waitFor(() => ctx.document.querySelector("[data-rolodex-key][data-peeked]"));
};

export default componentEntry<Props>({
  id: "agent-pane.composer-hat-rolodex",
  title: "Composer hat: thumb through the marks",
  area: "Agent pane",
  covers: [
    "agent-session/acpmux/subagents/SubagentTray.tsx",
    "agent-session/acpmux/subagents/hatRolodex.experiment.ts",
  ],
  load: () => import("../../../gallery/fixtures/ComposerHatHeadStage").then((module) => module.ComposerHatHeadStage),
  pane: true,
  height: 240,
  widths: { narrow: 360 },
  experiment: { definition: hatRolodexLook, script: [{ name: "the pointer on the second mark", run: onMark(1) }] },
  variants: {
    rest: {
      note: "Two subagents and a command, folded: the header leads with the longest-running one's name.",
      props: { start: "two-and-command" },
    },
    "first-mark": {
      note: "The pointer on the first mark: it lifts, and the header names that subagent and what it does now.",
      props: { start: "two-and-command" },
      play: onMark(0),
    },
    "second-mark": {
      note: "The pointer moves on to the second mark: the header's words slide to the second subagent.",
      props: { start: "two-and-command" },
      play: onMark(1),
    },
    "command-mark": {
      note: "The pointer on the commands' mark: the header names the command; a click opens its terminal.",
      props: { start: "two-and-command" },
      play: onMark(2),
    },
  },
});

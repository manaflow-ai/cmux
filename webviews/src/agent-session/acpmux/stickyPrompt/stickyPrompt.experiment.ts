// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The prompt you are reading the answer to, kept in sight while you scroll it, and a proper jump to
/// your last prompt. PROTOTYPE, gallery only until Leo picks (Leo, 2026-11-21: "i like how in the
/// terminal you can see the last promot you sent at the top as you scroll it's like pinned and
/// whatnot... smth like that/us properly doing a jump to last would be kinda cool. obv dont ship yet").
/// Gallery: `agent-pane.sticky-prompt` (view Compare arms). In the app: `cmux.experiments` =
/// `{"sticky-prompt":"chip"}` in the pane's web inspector, then reload.
/// Every arm: Option-Up and Option-Down go to the previous and next prompt, and the cost per scroll is
/// one binary search over the prompt rows' tops (no per-row observers).
export const stickyPrompt = defineExperiment({
  id: "sticky-prompt",
  title: "Sticky last prompt and jump to last prompt",
  description:
    "Scroll up through a long answer. Look at whether the prompt it answers stays readable without covering the answer, and whether getting back to your last prompt (or to the one before) is one obvious move.",
  arms: {
    off: {
      label: "Off (today)",
      description: "Nothing pinned; the keys still move between prompts.",
    },
    chip: {
      label: "Sticky chip",
      description:
        "A glass chip at the top end, the prompt's first line in the bubble's look, once its own row has scrolled away. Click: back to the prompt.",
    },
    line: {
      label: "Collapsed line",
      description:
        "A full-width one-line bar under the header with the prompt and a chevron; a click opens the whole prompt (up to six lines) in place, a second jumps to it.",
    },
    fade: {
      label: "Scroll-linked fade",
      description:
        "The terminal's look: the prompt pinned flat at the top, fading in as its row leaves and pushed out by the next prompt's row, as list section headers are.",
    },
    jump: {
      label: "Jump to last prompt",
      description:
        "No header: a labeled glass pill over the composer, 'Last prompt', with the keycap, next to Jump to latest. Option-Up and Option-Down step prompt by prompt.",
    },
    rail: {
      label: "Prompt rail",
      description: "A tick per prompt on the scrollbar's track, the current one lit; hover names it, click goes there.",
    },
  },
  defaultArm: "off",
});

export type StickyPromptArm = keyof typeof stickyPrompt.arms;

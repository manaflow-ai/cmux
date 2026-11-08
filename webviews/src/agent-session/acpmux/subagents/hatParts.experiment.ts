// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Where the composer hat's expand chevron sits (SubagentTray.tsx header). Leo, 2026-11-07: "I feel
/// like the chevron for the composer hat would maybe be nicer at the bottom. Do you think? I'm not
/// sure." Both points the way the hat opens: up while folded, down while open. Compare them in the
/// gallery's `agent-pane.composer-hat-head`.
export const hatChevronLook = defineExperiment({
  id: "composer-hat-chevron",
  title: "Composer hat: chevron place",
  description:
    "The hat header's expand chevron: at the row's end, in the column every line's chevron ends in, or centred on the hat's bottom edge, over the seam with the composer.",
  arms: {
    trailing: {
      label: "Row end",
      description:
        "At the header's end, in the lines' chevron column; it turns from up (folded) to down (open). Picked: the bottom centre floated mid-row over the header in the gallery.",
    },
    bottom: {
      label: "Bottom centre",
      description:
        "A small chevron centred on the hat's bottom edge, where the hat meets the composer; the row's end keeps only the time.",
    },
  },
  defaultArm: "trailing",
});

/// How a finished line ends (AgentLine.tsx trail, and a lone finished item's hat header). Leo,
/// 2026-11-07: "I still just, like, I just feel like there's something off about this, like, the done
/// whatever minutes type thing ... I know that the thing is aligned, but it just doesn't look that...
/// Great." Compare them in the gallery's `agent-pane.composer-hat-head`.
export const hatDoneLook = defineExperiment({
  id: "composer-hat-done",
  title: "Composer hat: a finished line's end",
  description:
    "A finished line's state and time: a check mark and the time, the words Done and the time, Done in the success colour, or the time alone.",
  arms: {
    check: {
      label: "Check and time",
      description:
        "A small check in the success colour, then the total in tabular figures; the word Done is for screen readers.",
    },
    words: {
      label: "Done · time",
      description: "As before: the muted word Done, a dot, the time.",
    },
    accent: {
      label: "Done in colour",
      description: "The word Done in the success colour at medium weight, then the time, muted and tabular.",
    },
    time: {
      label: "Time alone",
      description: "Only the total, muted and tabular; the word Done is for screen readers.",
    },
  },
  defaultArm: "check",
});

/// How a line joins and leaves the open hat (SubagentTray.tsx `TrayRow`). Leo, 2026-11-07: "when you
/// have your hat in the expandable state, right? Like, the things coming, they shouldn't just, like,
/// pop in, burst in, like, appear instantly, and, like, disappear instantly." Compare them in the
/// gallery's `agent-pane.composer-hat-linger`.
export const hatRowMotionLook = defineExperiment({
  id: "composer-hat-row-motion",
  title: "Composer hat: a line joining and leaving",
  description:
    "How a line enters and leaves the open hat: its height and opacity together, so the lines around it move with it; the same with a short rise; or a fade in place, the lines around it closing up after.",
  arms: {
    height: {
      label: "Height and fade",
      description:
        "Grows from 0 height as it fades in, folds to 0 as it fades out, on the pane's move duration; the lines around it move with it. Picked: no jump at either end.",
    },
    slide: {
      label: "Height, fade and rise",
      description: "As Height and fade, with the line rising a few points in as it joins and up as it leaves.",
    },
    fade: {
      label: "Fade only",
      description:
        "Fades in and out in place without its height moving; the lines around it jump once when it is gone.",
    },
  },
  defaultArm: "height",
});

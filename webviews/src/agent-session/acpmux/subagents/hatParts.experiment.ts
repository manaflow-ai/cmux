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

/// Where a finished item's check stands against the hat's other glyphs (DoneMark.tsx). Leo, 2026-11-08,
/// on "47s ✓": "it's just bc the alignment/whatever around the rest of the hat when you look at the
/// symbol and size/whatnot of it it just feels iffy how it's close the the number but idk if it should
/// be so close". Every arm draws the check at the hat's icon size and stroke on the full grid, so its
/// ink is the Stop square's size (it was a cropped row icon, a third wider), and a line keeps it in
/// Stop's column; the arms
/// differ on a lone finished item's folded header. Compare them in the gallery's
/// `agent-pane.composer-hat-done-check`.
export const hatDoneCheckPlace = defineExperiment({
  id: "composer-hat-done-check",
  title: "Composer hat: where the done check stands",
  description:
    "A lone finished item's folded header: the check one small gap after its time, in a Stop-wide column of its own after the time, or in the header's leading icon column with the time alone at the end.",
  arms: {
    column: {
      label: "Own column",
      description:
        "A Stop-wide column one tray gap after the time, the check centred in it: the time-to-check spacing of a line's time and its Stop square. Picked: it reads as the lines' rhythm and never hugs the digits.",
    },
    grid: {
      label: "After the time",
      description: "The check right after the time, one tray gap away, at the Stop square's ink size.",
    },
    leading: {
      label: "Leading column",
      description:
        "The check in the header's leading icon column, where the lines draw their own glyph; the time ends the row alone.",
    },
  },
  defaultArm: "column",
});

/// How the hat's step line hands over from one step to the next (trayMotion.tsx `Tick` slide: the
/// header's words and a line's latest step). Leo, 2026-11-11: "the composer hat the way it switches
/// between text is ugly bc it's too slow on the transitions and there's breif moments where it just
/// looks like a blank tear that then switches". Compare them in the gallery's
/// `agent-pane.composer-hat-step`.
export const hatStepLook = defineExperiment({
  id: "composer-hat-step",
  title: "Composer hat: a step handing over",
  description:
    "How the hat's line turns from one step to the next: the new words push the old up, both fully drawn; the old fade-and-slide; or a plain swap.",
  arms: {
    roll: {
      label: "Roll",
      description:
        "The new words rise from below and push the old up and out, both at full ink and clipped by the line, on the micro step (120 ms); there is always text in the line, never a blank between. A step that lands while one still rolls shows at once. Picked: fast, and never a blank.",
    },
    slide: {
      label: "Fade and slide",
      description:
        "As before: the old words fade as they slide up, the new fade in rising from below, on the move step (180 ms); midway both are faint.",
    },
    cut: {
      label: "Swap",
      description:
        "The new words replace the old in one frame; the line's width snaps with them, and what follows still glides.",
    },
  },
  defaultArm: "roll",
});

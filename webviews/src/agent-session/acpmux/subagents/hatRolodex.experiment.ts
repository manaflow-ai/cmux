// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// The composer hat's stacked marks as a Rolodex (SubagentTray.tsx `HeadMarks`). Leo, 2026-11-20, on
/// Lawrence's "ui for opening subagents is very confusing": "we need to be able to like thumb through
/// them like a Rolodex or whatever at the top ... if you hover over them ... on each one, it's like
/// there's a slight pop and something ... perhaps the text itself maybe changes like on the top of the
/// composer hat ... you can click into them and be able to open up that sub-agent". Folded or open, the
/// pointer runs along the header's marks: the mark under it lifts, the header's words become that
/// line's name and what it does now, and a click on the mark opens it (a subagent's view, a chat, a
/// lone command's terminal; the commands' shared mark opens the hat on its lines). Off the marks, the
/// header is the one control that folds and opens the hat, as before. Compare the arms in the gallery's
/// `agent-pane.composer-hat-rolodex`.
export const hatRolodexLook = defineExperiment({
  id: "composer-hat-rolodex",
  title: "Composer hat: thumb through the marks",
  description:
    "The hat header's marks as a Rolodex: hovering one lifts it and the header names that line; a click on a mark opens it.",
  arms: {
    pop: {
      label: "Lift and name",
      description:
        "The hovered mark lifts a little on a spring and the header's words slide to its name and what it does now; a click opens it.",
    },
    swap: {
      label: "Name only",
      description:
        "The header's words slide to the hovered mark's name; the mark itself does not move. A click opens it.",
    },
    off: {
      label: "Inert marks (before)",
      description: "The marks are decoration: the whole header folds and opens the hat, as before.",
    },
  },
  defaultArm: "pop",
});

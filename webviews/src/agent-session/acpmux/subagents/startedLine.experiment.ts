// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a group of subagents that started together reads in the transcript (SubagentStartedLine.tsx).
/// Leo, 2026-11-22, on "✧ M… , ✧ iO… , ✧ i… , ✧ T… , ✧ S… , ✧ E… , and ✧ Li… started working", seven
/// chips cut to a letter or two on one line: "this is so fucking awkward as ui. unilaterally, literally
/// anything else would be a motherfucking improvement. go debate figure shit out. try some variants."
/// Compare the arms in the gallery's `agent-pane.subagent-started-line`.
export const startedLineLook = defineExperiment({
  id: "subagent-started-line",
  title: "Subagents started: the grouped line",
  description:
    "A group of subagents that started at once: a count that opens to their names, every name whole on wrapping lines, one line per subagent, or the one-line list of cut chips it was.",
  arms: {
    count: {
      label: "Count, opens to names",
      description:
        'Two names read whole in the sentence. Three or more: their icons, then "7 subagents started working" and a chevron; a click opens one line per subagent, each name whole.',
    },
    wrap: {
      label: "Every name, wrapped",
      description: "Every name whole in the sentence, the line wrapping onto as many rows as the names need.",
    },
    lines: {
      label: "One line each",
      description: 'One "<name> started working" line per subagent, each with its own icon.',
    },
    before: {
      label: "Before",
      description: "As it was: every name on one line, each chip cut to fit, often to a letter or two.",
    },
  },
  defaultArm: "count",
});

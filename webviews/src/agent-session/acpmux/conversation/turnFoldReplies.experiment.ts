// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a closed "Worked for" draws the work around the replies it never hides. A reply to the person
/// is its own never-fold row (Leo, 2026-11-06: "your intermediate message got lost. that can never
/// happen", then "those intermediate messages should be counted differently than other tool calls
/// like it's a special never-fold type"); the arms differ only in the work between replies.
/// Compare in `agent-pane.turn-fold-replies`.
/// The `replies` arm draws a closed "Worked for" as chatgpt.com does: nothing beside it but what the
/// agent said to the person, never a tool call (2026-11-10: "it says 'worked for 36s' but if i hide
/// it, it still shows a bunch of tool calls"). The `answer` arm, the default, hides one step more, as
/// the Codex app ends a turn: only the final answer stays outside the closed fold, and the earlier
/// replies read in order once it opens (2026-11-11 standup: the closed fold "does not hide enough").
export const turnFoldReplies = defineExperiment({
  id: "turn-fold-replies",
  title: "Replies in a closed turn fold",
  description: "How a closed Worked for draws the work before, between and after the replies it keeps in sight.",
  arms: {
    answer: {
      label: "Final answer only",
      description: "Only the final answer stays in sight; every earlier reply folds under Worked for, as Codex does.",
    },
    groups: {
      label: "One line per stretch",
      description: "Each stretch of work between two replies folds into one closed line (Ran 4 commands).",
    },
    runs: {
      label: "One line per run",
      description: "Each run of calls between the replies keeps its own closed line, as an open fold draws it.",
    },
    replies: {
      label: "Replies only",
      description: "The replies stay in sight; all the work stays under Worked for.",
    },
  },
  defaultArm: "answer",
});

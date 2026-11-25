// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// What the composer footer says about the session beside its status dot (Leo, 2026-11-22: "hey
/// there's space at the bottom of the composer. what else could we add that fits? metadata about stuff
/// is one. because who wants to open up session info these days!?"). acpmux decides the facts
/// (`composerStatus.facts`); the arms only choose where they show. No arm touches the context ring or
/// the pickers. Gallery `agent-pane.composer-status-dot`, design/composer-status-dot.md.
export const composerFooterFacts = defineExperiment({
  id: "composer-footer-facts",
  title: "Composer footer facts",
  description: "Session facts in the status dot's card and, for live ones, as footer counters.",
  arms: {
    off: {
      label: "Off",
      description: "The dot says statuses only, as before.",
    },
    pulse: {
      label: "Pulse",
      description:
        "The card adds a Session list (folder, context, turn); running subagents and queued prompts show as counters beside the dot.",
    },
    door: {
      label: "Door",
      description: "The card's Session list only, behind a faint dot that is always there.",
    },
    strip: {
      label: "Strip",
      description:
        "A quiet line in the footer's free middle: machine, folder, branch, context, turn time; counters as in pulse.",
    },
  },
  defaultArm: "off",
});

// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a subagent's own composer says what it runs on and offers to switch it (SubagentForkChips.tsx).
/// Leo, 2026-11-22: "so for subagents, actually, are their permissions/model locked right then and
/// there? does it make sense to be able to reveal the fork or whatever switching model behaviour for
/// it?" A running subagent's model is fixed when it starts; a Claude subagent's permissions follow
/// its chat's live mode, a Codex one's were copied at its start. So its chips can only tell the truth,
/// and the one honest way to run it otherwise is to fork its context into a chat of its own. Compare
/// the arms in the gallery's `agent-pane.subagent-fork-chips`.
export const subagentForkChipsLook = defineExperiment({
  id: "subagent-fork-chips",
  title: "Subagent composer: model and mode, and forking",
  description:
    "What a subagent's composer shows of the model and permission mode it runs on, and how a person forks it into a chat of their own on another model or mode.",
  arms: {
    off: {
      label: "Off (as before)",
      description:
        "No chips on a subagent's composer, as before: the row has no model or mode and no way to fork the subagent.",
    },
    chips: {
      label: "Read-only chips + fork menu",
      description:
        "The chat's model and mode chips, greyed: the model it started on and the mode it runs in. Hovering says why it is fixed (or that it follows the chat); a click opens Fork with <model>… and Fork with <mode>…",
    },
    takeover: {
      label: "Take over button",
      description:
        "No chips: one Take over in new chat… button in the chips' place, which opens a model and mode picker and forks on its Fork.",
    },
    hover: {
      label: "Chips on hover",
      description:
        "The read-only chips show only while the pointer or focus is on the composer; the rest of the time the row is empty. Same fork menu.",
    },
  },
  defaultArm: "off",
});

// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How a finished MCP call with no friendlier line reads. Today it is Claude Code's "Used repo: repo
/// grep": the server, then the tool's name, which often repeats the server. The `plain` arm says the
/// call in a plain verb with what it acted on ("Searched repo for “retry”"), and names the server
/// once ("Used repo: blame") when the tool's name has no verb. Compare in
/// `agent-pane.claude-code-tool-rows`. `plain` ships (Leo, 2026-11-22: "the taste ones i agree with all actually"); `now` stays as an arm to compare against.
export const toolRowWords = defineExperiment({
  id: "tool-row-words",
  title: "Plain words on MCP tool rows",
  description: "Whether an MCP call with no friendlier line reads as Claude Code words it, or as a plain verb.",
  arms: {
    now: {
      label: "Claude Code's words",
      description: "Used repo: repo grep, as Claude Code words it, the earlier line.",
    },
    plain: {
      label: "Plain verb",
      description: "Searched repo for “cv-tool__icon”: a verb, what it acted on, the server named once.",
    },
  },
  defaultArm: "plain",
});

// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Where a background task's end and the agent's reaction to it go (Leo, 2026-11-03: "i mean can
/// these possibly be more graceful?" and "there's like... background tasks worth responding to and
/// not worth responding to"). acpmux weighs each end from the task's own event (silent, result,
/// failure; hub/background_cause.rs); the arms differ in how a quiet one draws. Every arm keeps a
/// failure on screen and a reply with something to say in the transcript. Compare them in the
/// gallery's `agent-pane.background-reactions`.
export const backgroundReactionLook = defineExperiment({
  id: "background-reaction-look",
  title: "Background reaction look",
  description:
    "Where a background task's end and the agent's reply to it go: on the call, a named line, or the folded run.",
  arms: {
    origin: {
      label: "On the call",
      description:
        "No transcript row: the call that started the task updates in place, a final result gets a small new mark until the next prompt, and the reply opens with the call.",
    },
    calm: {
      label: "On the call, no mark",
      description: "As On the call, without the new mark: the call's own check or Failed is the only sign.",
    },
    summary: {
      label: "Named line",
      description:
        "A step or interim stop draws nothing; a final result with nothing to say is one muted line in the task's own words.",
    },
    fold: {
      label: "Folded run (current)",
      description: "Every quiet background turn is a muted line, and a run of them folds into one counted line.",
    },
  },
  defaultArm: "origin",
});

/// Whether this arm puts a task's end on the call that started it, and whether it marks a result new.
export const reactsOnCall = (arm: string): boolean => arm === "origin" || arm === "calm";
export const marksNew = (arm: string): boolean => arm === "origin";

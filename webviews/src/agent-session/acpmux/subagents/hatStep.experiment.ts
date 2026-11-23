// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// What the composer hat says a running subagent is doing (SubagentTray.tsx, AgentLine.tsx). Leo,
/// 2026-11-22: "the swapping gets jarring. it's too adhd-ish ... perhaps there is a case to be made for
/// e.g. we dont show the exact calls, ever, at the top. then we therefore understand what will pop up
/// as they come. therefore we dont have humongous swings in text size that our yet-incapable animation
/// system cannot represent nicely, likewise with huge churn in numbers and symbols and messages being
/// sent." Claude Code's own status line never names a call either: the calls are rows in the
/// transcript and the line above the input holds still (design/composer-hat-calm.md). Compare the
/// arms in the gallery's `agent-pane.hat-burst`.
export const hatStepLook = defineExperiment({
  id: "composer-hat-step",
  title: "Composer hat: what a running subagent is doing",
  description:
    "How the hat says what each running subagent does now: one word for the kind of call in a fixed-width slot, nothing, the exact call sampled slowly, or every exact call as it comes (before).",
  arms: {
    phase: {
      label: "Kind of call",
      description:
        "One word from a short fixed list (Reading, Editing, Running, Fetching, Delegating, Working, Thinking), in a slot as wide as the widest word, held 1.5 s at least. No call counts or tokens; the exact call is in the line's details.",
    },
    quiet: {
      label: "Nothing",
      description: "The task, its state and its time only: nothing per call moves in the hat.",
    },
    sampled: {
      label: "Exact call, sampled",
      description:
        "The exact call, at most one change each 2.5 s, cross-faded in a fixed-width slot that cuts it. No call counts or tokens.",
    },
    exact: {
      label: "Every call (before)",
      description:
        "As before: each new call's exact title slides in as it arrives, its width sliding with it, with the call and token counts beside it.",
    },
  },
  defaultArm: "phase",
});

export type HatStepArm = "phase" | "quiet" | "sampled" | "exact";

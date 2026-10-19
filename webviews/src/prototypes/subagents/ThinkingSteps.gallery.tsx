// l10n-allow-file: gallery prototype fixtures, not shipped UI.
// Thinking and steps (Lawrence 2026-10-19): minimized to one shimmering line by default; a tap
// opens the details to the right, in place, in a card, or as a step rail. Steps is a toggle, off.
import { componentEntry } from "../../gallery/format";
import type { ThinkingStepsProps } from "./ThinkingSteps";

export default componentEntry<ThinkingStepsProps>({
  id: "subagents.thinking-steps",
  title: "Subagents: thinking and steps",
  area: "Subagent books",
  keywords: ["shimmer", "thinking", "reasoning", "steps", "collapsed", "details", "ios", "mac"],
  covers: ["prototypes/subagents/ThinkingSteps.tsx"],
  load: () => import("./ThinkingSteps").then((module) => module.ThinkingSteps),
  height: 920,
  widths: { narrow: 440, normal: 1280, wide: 1600 },
  options: [
    {
      id: "platform",
      label: "Frame",
      kind: "choice",
      choices: [
        { value: "mac", label: "Mac" },
        { value: "iphone", label: "iPhone" },
      ],
      defaultValue: "mac",
    },
    { id: "expanded", label: "Thinking open", kind: "toggle", defaultValue: false },
    { id: "steps", label: "Steps setting", kind: "toggle", defaultValue: false },
    {
      id: "phase",
      label: "Turn",
      kind: "choice",
      choices: [
        { value: "working", label: "Working" },
        { value: "finished", label: "Finished" },
      ],
      defaultValue: "working",
    },
    {
      id: "label",
      label: "Shimmer says",
      kind: "choice",
      choices: [
        { value: "step", label: "Current step" },
        { value: "thinking", label: "Thinking" },
      ],
      defaultValue: "step",
    },
  ],
  variants: {
    minimized: { note: "The default: one shimmering line, the current step's title.", props: { platform: "mac", design: "side" } },
    "side-open": { note: "Tap the line: the steps open in a column right of the transcript (iPhone: a sheet).", props: { platform: "mac", design: "side", expanded: true } },
    "inline-open": { note: "The steps open in place, under the line.", props: { platform: "mac", design: "inline", expanded: true } },
    "card-open": { note: "The steps open in a small card that floats over the transcript.", props: { platform: "mac", design: "card", expanded: true } },
    rail: { note: "Original: a step rail in the turn's gutter; a dot per step (filled thought, ring tool).", props: { platform: "mac", design: "rail" } },
    "finished-steps-off": { note: "Finished with Steps off (default): no steps line at all.", props: { platform: "mac", design: "side", phase: "finished" } },
    "finished-steps-on": { note: "Finished with Steps on: one quiet line, Thought for 38s · 7 steps.", props: { platform: "mac", design: "inline", phase: "finished", steps: true } },
  },
});

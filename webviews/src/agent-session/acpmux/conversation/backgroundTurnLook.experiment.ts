// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment, experimentArm } from "../../../experiments/experiment";

/// How a turn the agent ran on its own draws (backgroundTurns.ts; Leo, 2026-11-11: "i feel like it's
/// no longer worth having this special "background updates" thing. it should maybe arguably just be
/// treated like a normal tool call"). Compare the arms in the gallery's `transcript` `background-turns`.
export const backgroundTurnLook = defineExperiment({
  id: "background-turn-look",
  title: "Background turn look",
  description: "Whether a turn the agent ran on its own draws its tool calls inline or folds them under one line.",
  arms: {
    inline: {
      label: "As tool calls",
      description:
        'No "Background update", "Scheduled check" or "N background updates" line: the turn\'s tool calls draw where they ran, as any other call does. A quiet reply still draws nothing; a failure or a result keeps the line that names its task.',
    },
    line: {
      label: "One line (before)",
      description:
        "A quiet or running turn is one muted line that opens to its rows, and a run of them folds into one counted line.",
    },
  },
  defaultArm: "inline",
});

/// Whether a background turn's rows draw inline, with no line of their own over them.
export const backgroundTurnsInline = (arm: string): boolean => arm === "inline";

/// Whether the running look draws a background turn's line: a gallery play that hovers or opens that
/// line runs only then, so it never waits on a control the inline look does not draw.
export const drawsBackgroundTurnLines = (): boolean => !backgroundTurnsInline(experimentArm(backgroundTurnLook));

// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Where the composer hat's marks live (HatRail.tsx). Leo, 2026-11-21, on the Rolodex hat (cmux#47923):
/// "this is uncomfortably tight. didn't we say we wanted to move these to the side or smth?". "The
/// side" reads more than one way, so each reading is an arm: the hat over the composer as today, the
/// running lines' marks in a slim rail beside the composer (right or left), or the marks on the
/// composer's own bottom line beside + and Send. In every side arm a mark lifts and names its line on
/// hover or focus, a click opens it (the same open path as the hat's marks, SubagentTray.tsx
/// `openHatMark`), and the rail's list control shows the hat's full list over the composer. Compare
/// the arms in the gallery's `agent-pane.composer-hat-side`.
export const hatSideLook = defineExperiment({
  id: "composer-hat-side",
  title: "Composer hat: on top or to the side",
  description:
    "Where the running lines' marks sit: the hat over the composer (today), a slim rail at the composer's right or left, or the composer's bottom line.",
  arms: {
    top: {
      label: "Hat on top (today)",
      description: "The hat sits over the composer, its marks in its header.",
    },
    "right-rail": {
      label: "Right rail",
      description:
        "The marks stand in a slim column at the composer's right, so the composer keeps its full height; hovering one names it, a click opens it, the rail's list control shows every line.",
    },
    "left-rail": {
      label: "Left rail",
      description: "The same rail at the composer's left.",
    },
    "bottom-line": {
      label: "Composer bottom line",
      description:
        "The marks sit on the composer's bottom line between + and the send controls; no hat above. Hovering one names it above the line.",
    },
  },
  defaultArm: "top",
});

export type HatSide = "right-rail" | "left-rail" | "bottom-line";

// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the capture bar lays out its choices (CaptureBar.tsx; Leo, 2026-11-07: "could we also have a
/// more native screenshot/screensharer (ergonomic one)/video recording of the app type thing/route?").
/// Every arm takes the same captures and sends them to the same places; they differ in how many
/// clicks a capture costs and how much room the bar takes. Compare them in the gallery's
/// `agent-pane.capture-bar`.
export const captureBarLook = defineExperiment({
  id: "capture-bar",
  title: "Capture bar",
  description:
    "The capture bar over the composer: one band where each target is its own button, a mode switch with one Capture button, or a small row of icons.",
  arms: {
    band: {
      label: "Band",
      description:
        "One band in the composer hat's glass: Region, Window, Pane and cmux each take the screenshot on a click; Record with Pointer and Clicks beside it; Chat, Copy or Save at the end.",
    },
    segmented: {
      label: "Mode switch",
      description:
        "Screenshot or Record first, then a target and Capture: the system screenshot toolbar's order, one more click a capture.",
    },
    chip: {
      label: "Icons",
      description:
        "A small row of icons, one per target and Record, with names in tooltips. The least room taken; the destination is the last one picked.",
    },
  },
  defaultArm: "band",
});

export type CaptureBarLook = "band" | "segmented" | "chip";

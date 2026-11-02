// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";
import { RAIL_HEIGHTS, type RailHeightArm } from "./model";

/// The compact rail's initial and maximum height. Leo asked for a rail that grows toward ChatGPT's
/// nearly full-pane rail instead of tracking the visible transcript slice. The gallery compares four
/// choices; `initial-320-max-92` is the selected balance between a generous first view and room for the
/// transcript's own edge mask. Dogfood switches from `cmux.experiments` with this experiment id.
export const threadMinimapHeight = defineExperiment({
  id: "thread-minimap-height",
  title: "Thread minimap height",
  description: "How tall the compact prompt rail starts and how close its maximum gets to the pane height.",
  arms: {
    "initial-240-max-80": {
      label: "240px / 80%",
      description: "A modest initial rail, capped at 80% of the pane.",
    },
    "initial-320-max-92": {
      label: "320px / 92%",
      description: "A tall initial rail that grows close to the pane while preserving edge clearance.",
    },
    "initial-400-max-96": {
      label: "400px / 96%",
      description: "A larger initial rail with a near-full-pane maximum.",
    },
    "initial-480-max-full": {
      label: "480px / full",
      description: "The tallest initial rail, using all available cleared pane room.",
    },
  },
  defaultArm: "initial-320-max-92",
});

export const railHeightConfig = (arm: RailHeightArm) => RAIL_HEIGHTS[arm];

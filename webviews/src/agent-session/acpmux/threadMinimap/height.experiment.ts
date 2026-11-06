// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";
import { DEFAULT_RAIL_HEIGHT, RAIL_HEIGHTS, type RailHeightArm, type RailHeightConfig } from "./model";

/// The compact rail's initial and maximum height. Leo first asked for a rail that grows toward
/// ChatGPT's nearly full-pane rail instead of tracking the visible transcript slice
/// (`initial-320-max-92` shipped for that). Then, 2026-11-04: "the left side session rail should just
/// be having a nicer max height instead of going all the way up and down. make it look like codex's
/// size." and "the height of the left scroll rail should never be affected by anything". The `fixed-*`
/// arms are one height for every chat, whatever its prompt count or the pane's height; `fixed-240`
/// shipped. Leo, 2026-11-05: "this can maybe be proportionally like double of what it is rn";
/// `fixed-480` now ships with twice the height and tick pitch. Dogfood switches from `cmux.experiments` with this experiment id.
export const threadMinimapHeight = defineExperiment({
  id: "thread-minimap-height",
  title: "Thread minimap height",
  description: "How tall the compact prompt rail starts and how close its maximum gets to the pane height.",
  arms: {
    "fixed-200": {
      label: "Fixed 200px",
      description: "One short height for every chat; longer chats scroll the rail's own list.",
    },
    "fixed-240": {
      label: "Fixed 240px",
      description: "The Codex rail's size: one height for every chat, unaffected by prompt count or pane height.",
    },
    "fixed-360": {
      label: "Fixed 360px / 15px pitch",
      description: "One and a half times the original height and tick spacing.",
    },
    "fixed-480": {
      label: "Fixed 480px / 20px pitch",
      description: "Twice the original height and tick spacing, with the same resting tick lengths and tones.",
    },
    "fixed-280": {
      label: "Fixed 280px",
      description: "One slightly taller height for every chat.",
    },
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
  defaultArm: DEFAULT_RAIL_HEIGHT,
});

export const railHeightConfig = (arm: RailHeightArm): RailHeightConfig => RAIL_HEIGHTS[arm];

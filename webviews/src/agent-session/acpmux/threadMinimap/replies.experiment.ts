// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How the prompt rail draws the agent's replies once it shows them (model.ts `RailShow`; Leo,
/// 2026-11-21: "why cant you see an agents'? why cant you filter it? customize it immediately? ... debate
/// on the appearance"). Three designs were argued and compared in threadMinimapShow.gallery.ts:
/// `lens` (the default) draws every entry as the person's tick, in the one column, and names what the
/// rail shows from a control at its head; `ruler` draws replies as shorter, dimmer minor ticks between
/// the prompts, with no head control; `lanes` sets replies in a second, inner lane, with the head
/// control. Dogfood switches from `cmux.experiments`: {"thread-minimap-replies":"ruler"}.
export const threadMinimapReplies = defineExperiment({
  id: "thread-minimap-replies",
  title: "Prompt rail: the agent's replies",
  description:
    "How the prompt rail draws the agent's replies: as every tick, as minor ticks, or in a lane of their own.",
  arms: {
    lens: {
      label: "One list, one look",
      description: "Every tick drawn alike in one column; the head control names what the rail shows.",
    },
    ruler: {
      label: "Minor ticks",
      description: "Replies draw shorter and dimmer between the prompts; only the right-click menu changes it.",
    },
    lanes: {
      label: "Two lanes",
      description: "Replies draw in an inner lane beside the prompts, with the head control.",
    },
  },
  defaultArm: "lens",
});

export type RepliesLook = keyof typeof threadMinimapReplies.arms;

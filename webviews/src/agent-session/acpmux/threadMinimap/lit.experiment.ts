// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// How bright the compact rail draws the prompts on screen (the lit band), over resting ticks at
/// 40%. #22228 lit them at 60%, which read as barely brighter than rest, so the band hardly showed
/// where the reader was. The gallery compares the arms side by side; 75% (the default) is a clear
/// step over rest that still sits well under a hovered or focused tick (100%). Dogfood switches from
/// `cmux.experiments`: {"thread-minimap-lit":"lit-60"}.
export const threadMinimapLit = defineExperiment({
  id: "thread-minimap-lit",
  title: "Thread minimap lit band",
  description: "How bright the compact rail draws the prompts on screen, over resting ticks at 40%.",
  arms: {
    "lit-60": { label: "60%", description: "The lit band at 60%, as #22228 drew it." },
    "lit-70": { label: "70%", description: "The lit band at 70%." },
    "lit-75": { label: "75%", description: "The lit band at 75%: a clear step over rest, under a hovered tick." },
    "lit-85": { label: "85%", description: "The lit band at 85%, close to a hovered tick." },
  },
  defaultArm: "lit-75",
});

/// Each arm's opacity for a lit tick's bar (threadMinimap.css, --acpmux-minimap-lit).
export const LIT_OPACITY: Record<keyof typeof threadMinimapLit.arms, number> = {
  "lit-60": 0.6,
  "lit-70": 0.7,
  "lit-75": 0.75,
  "lit-85": 0.85,
};

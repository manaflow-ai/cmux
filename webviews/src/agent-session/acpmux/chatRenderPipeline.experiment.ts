// l10n-allow-file: experiment descriptions appear in the developer gallery.
import { defineExperiment } from "../../experiments/experiment";

export const chatRenderPipeline = defineExperiment({
  id: "chat-render-pipeline",
  title: "Chat render pipeline",
  description: "Whether offscreen rows from completed turns skip browser rendering.",
  arms: {
    off: { label: "Off", description: "Render every mounted row." },
    on: { label: "On", description: "Let the browser skip settled rows using their indexed height." },
  },
  defaultArm: "off",
});

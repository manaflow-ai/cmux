// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment, experimentArm } from "../../../experiments/experiment";

/// A depth layer behind the New Tab page (DepthBackground.tsx, depth.css). Leo's reference, through
/// the motion-backgrounds lane: "bold dark cards, and a live layer behind the UI for depth". Off by
/// default: the page stays as it ships until an arm is picked. Home is native Swift
/// (design/home.md), so only New Tab carries it. Compare the arms in the gallery
/// (agent-pane.new-tab-depth). No arm runs anything while the page is still: no infinite animation and
/// no frame loop; the moving arms move only on pointer events and stand still under Reduce Motion.
export const newTabDepth = defineExperiment({
  id: "new-tab-depth",
  title: "New Tab depth layer",
  description:
    "What sits behind the New Tab page for depth: layered gradients with pointer parallax, grain and vignette, accent fields that shift on a card's hover, or the window's picture behind bold dark cards.",
  arms: {
    off: { label: "Off", description: "Today: the theme, or the window's picture, and nothing behind the page." },
    layers: {
      label: "Layers + parallax",
      description:
        "Soft accent gradients at two depths lean a few px toward the pointer, only while it moves (ui/motion DepthLayer).",
    },
    grain: { label: "Grain + vignette", description: "A still film grain and a vignette that darkens the edges." },
    fields: {
      label: "Accent fields",
      description: "Soft color fields from the theme accent; hovering a chat card shifts them once and they rest.",
    },
    backdrop: {
      label: "Picture + bold cards",
      description:
        "The window's own picture shows through with an edge scrim; the chat cards turn solid, dark and raised over it.",
    },
  },
  defaultArm: "off",
});

export type NewTabDepthArm = keyof typeof newTabDepth.arms;

export const newTabDepthArm = (): NewTabDepthArm => experimentArm(newTabDepth);

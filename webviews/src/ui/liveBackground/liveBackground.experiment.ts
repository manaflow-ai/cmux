// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// A live background behind the agent pane (liveBackground.ts): a slow shader in the place of the
/// still picture "Set Background…" shows. Leo, 2026-11-01: "but also we literally have backgrounds
/// embedde inside today". Off by default: it replaces the person's own picture while it runs, and
/// the host has no setting for it yet. To try one, set `cmux.experiments` to
/// `{"live-background":"aurora"}` in the pane's web inspector and reload.
export const liveBackground = defineExperiment({
  id: "live-background",
  title: "Live background",
  description:
    "A slow shader behind the chat, frosted by the glass like the picture. Look at whether the motion stays calm enough to read over, and at the glass over it.",
  arms: {
    off: { label: "Off", description: "Today: the person's picture, or the theme, and nothing moving." },
    aurora: { label: "Aurora", description: "Bands in the accent sway and fold slowly over a deep field." },
    drift: { label: "Drift", description: "Four soft blobs of the palette wander: a mesh gradient in motion." },
    grain: { label: "Grain", description: "Drift with a fine film grain under 3%." },
  },
  defaultArm: "off",
});

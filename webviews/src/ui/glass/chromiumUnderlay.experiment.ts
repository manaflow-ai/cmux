// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../experiments/experiment";

/// Chromium over the window glass (Leo 2026-10-22: "we can't be having unstyled main chat panes"):
/// how much of the theme surface a floating glass lays under its tint in a see-through Chromium
/// page, so the page text under it fades instead of reading crisp through the tint (glass.css,
/// "CHROMIUM OVER THE WINDOW GLASS"). WebKit and an opaque window never draw it. desktop.ts puts the
/// arm on `<html>` as data-glass-underlay; to try another, set `cmux.experiments` to
/// `{"chromium-glass-underlay":"light"}` in the pane's web inspector and reload.
export const chromiumGlassUnderlay = defineExperiment({
  id: "chromium-glass-underlay",
  title: "Chromium glass underlay",
  description:
    "In a see-through Chromium page, the theme surface a menu, a hover card, the composer or Session Info lays under its tint. Look at the transcript text under the glass: crisp text through it is the defect; more surface hides it but shows less of the window glass.",
  arms: {
    none: { label: "None", description: "The tint alone, as before: the text under the glass reads crisp through it." },
    light: { label: "Light", description: "The surface at 50% under the tint." },
    medium: { label: "Medium", description: "The surface at 70% under the tint: the text under it is a faint trace." },
    heavy: { label: "Heavy", description: "The surface at 85% under the tint: close to a solid card." },
  },
  defaultArm: "medium",
});

// l10n-allow-file: gallery notes, not shipped UI.
// Glass Controls (appearance.glassControls, Taste Board #164): the knobs of the Settings page's
// switches and sliders drawn as glass. `off` is the default and must look exactly as before; read
// each variant over light and dark, and over no picture and a picture, with the env's controls.
import { settingsPageEntry, type SettingsPageVariant } from "../../gallery/format";
import { GLASS_CONTROLS_KEY } from "./glassControls";

function variant(section: string, on: boolean, note: string, focus?: string): SettingsPageVariant {
  return {
    section,
    ...(focus ? { focus } : {}),
    options: { values: on ? { [GLASS_CONTROLS_KEY]: true } : {} },
    note,
    play: async (ctx) => {
      await ctx.waitFor(() =>
        on
          ? ctx.document.querySelector(".settings[data-glass-controls] .ui-switch")
          : ctx.document.querySelector(".settings:not([data-glass-controls]) .ui-switch"),
      );
    },
  };
}

export default settingsPageEntry({
  id: "pages.settings.glass-controls",
  title: "Glass Controls: switch and slider knobs drawn as glass",
  area: "Settings",
  height: 760,
  covers: ["page:cmux.settings", "pages/settings/glassControls.css", "pages/settings/glassControls.ts"],
  variants: {
    "switches-off": variant(
      "experimental",
      false,
      "Off (the default): today's switches, a solid knob on the grey or accent track.",
      GLASS_CONTROLS_KEY,
    ),
    "switches-on": variant(
      "experimental",
      true,
      "On: each switch knob is a translucent lit bead with a specular rim; the track's grey or accent shows through it.",
      GLASS_CONTROLS_KEY,
    ),
    "sliders-off": variant("appearance", false, "Off (the default): today's white slider knobs."),
    "sliders-on": variant(
      "appearance",
      true,
      "On: the slider knobs are glass over the filled track; switches on the same page match.",
    ),
  },
});

// l10n-allow-file: gallery fixtures, not shipped UI.
// The title area tone on a page that draws its own sidebar (Leo, 2026-11-12: "fixing up the whole,
// like, polish of the two-tone mode"): under Subtle Tone the Settings sidebar takes the chrome's
// shade and the current category joins the content panel. Each variant is one join of the real
// stylesheet (look.css, `data-settings-folder-tab` on the root); `one-color` is the default tone,
// which must look as it did before. Read each over light and dark and over no picture and a picture
// with the env's colorScheme and background controls.
import { settingsPageEntry, type SettingsPageVariant } from "../../gallery/format";

type Join = "folder" | "folder-rim" | "lifted" | "pill";

function join(name: Join | null, note: string): SettingsPageVariant {
  return {
    section: "appearance",
    titleAreaTone: name === null ? "one-color" : "subtle-tone",
    note,
    play: async (ctx) => {
      const root = ctx.document.documentElement;
      // `folder` is the stylesheet's default: no attribute.
      if (name === null || name === "folder") delete root.dataset.settingsFolderTab;
      else root.dataset.settingsFolderTab = name;
      await ctx.waitFor(() => ctx.document.querySelector(".settings .section-link[aria-current]"));
    },
  };
}

export default settingsPageEntry({
  id: "appearance.two-tone",
  title: "Two-tone: the selected row's join",
  area: "Settings",
  height: 760,
  covers: ["page:cmux.settings", "pages/settings/look.css"],
  variants: {
    folder: join(
      "folder",
      "Subtle Tone, the default join: the current category is the content's surface cut out of the sidebar's shade, square into the panel, no rim.",
    ),
    "folder-rim": join("folder-rim", "Subtle Tone: the folder tab with the chrome divider along its outer sides."),
    lifted: join("lifted", "Subtle Tone: the content's surface at the row's own size, raised by the low elevation."),
    pill: join("pill", "Subtle Tone, before: the selection pill on the shade."),
    "one-color": join(null, "One Color (the default tone): the selection pill, no shade, exactly as before."),
  },
});

// l10n-allow-file: gallery fixtures and layout diagnostics, not shipped UI.
import { settingsPageEntry, type SettingsPageVariant } from "../../gallery/format";

const key = "appearance.metrics.chromeFontSize";
const metrics = ["sidebarWidth", "columnGap", "dividerThickness"];

function sizeVariant(size: number): SettingsPageVariant {
  return {
    section: "appearance",
    focus: key,
    options: { values: { [key]: size } },
    note: `Interface Size ${size}: labels stay readable beside or above their sliders in a narrow pane.`,
    play: async (ctx) => {
      ctx.document.documentElement.style.setProperty("--cmux-interface-scale", String(size / 12));
      await ctx.waitFor(() => {
        for (const metric of metrics) {
          const row = ctx.find({ selector: `[data-row-key="appearance.metrics.${metric}"]` });
          const label = row.querySelector<HTMLElement>(".row-label")!;
          const slider = row.querySelector<HTMLInputElement>(".slider")!;
          const left = label.getBoundingClientRect();
          const right = slider.getBoundingClientRect();
          if (label.scrollWidth > label.clientWidth + 1) return false;
          if (left.left < right.right && left.right > right.left && left.top < right.bottom && left.bottom > right.top)
            return false;
        }
        return true;
      });
    },
  };
}

export default settingsPageEntry({
  id: "pages.settings-interface-size",
  title: "Settings Interface Size",
  area: "Settings",
  height: 760,
  widths: { narrow: 446 },
  covers: ["page:cmux.settings", "pages/settings/refined.css"],
  variants: { default: sizeVariant(12), enlarged: sizeVariant(16) },
});

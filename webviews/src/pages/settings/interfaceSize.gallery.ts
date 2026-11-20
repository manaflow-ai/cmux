// l10n-allow-file: gallery fixtures and layout diagnostics, not shipped UI.
import { settingsPageEntry, type SettingsPageVariant } from "../../gallery/format";

const key = "appearance.metrics.chromeFontSize";

function sizeVariant(size: number): SettingsPageVariant {
  return {
    // Appearance's slider rows (Interface Size, motion, color transition). Text Size itself is drawn by
    // Personalization's density card, so a focus on it would open Personalization: the page sets the
    // scale below instead.
    section: "appearance",
    options: { values: { [key]: size } },
    note: `Interface Size ${size}: labels stay readable beside or above their sliders in a narrow pane.`,
    play: async (ctx) => {
      ctx.document.documentElement.style.setProperty("--cmux-interface-scale", String(size / 12));
      await ctx.waitFor(() => {
        // Every slider row the page shows (rows behind a closed More Options are inert, not shown).
        const rows = [...ctx.document.querySelectorAll<HTMLElement>(".content [data-row-key]")].filter(
          (row) => row.querySelector(".slider") && row.querySelector(".row-label") && !row.closest("[inert]"),
        );
        if (rows.length === 0) return false;
        for (const row of rows) {
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

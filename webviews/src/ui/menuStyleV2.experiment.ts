// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../experiments/experiment";

/** The page-drawn menus' look, v2 (Leo's taste build list, lane taste-menus-v2): a rounded pill
 * highlight inset from the panel's edge, a right-aligned shortcut column in the secondary text
 * colour, a submenu flush with its parent row, icons all-or-none per divider group, destructive rows
 * last and red, and in dark a hairline edge instead of a shadow. Compact: 28 px rows, a 10 px panel.
 * The arm is a data attribute on the menu's root (`data-menu-style`), styled in popupSurface.css;
 * `off` draws no attribute, so today's menus are unchanged. Dogfood: set `cmux.experiments` to
 * `{"menu-style-v2":"v2"}` in the pane's web inspector and reload.
 * @status experimental
 */
export const menuStyleV2 = defineExperiment({
  id: "menu-style-v2",
  title: "Menu style v2",
  description:
    "The page-drawn menus (Menu, ContextMenu): inset pill highlight, shortcut column, flush submenu, icons all-or-none per group, destructive last, dark hairline edge.",
  arms: {
    off: { label: "Off", description: "Today's menus, unchanged." },
    v2: {
      label: "V2",
      description:
        "Inset pill rows (28 px), 10 px panel, flush submenu, icons all-or-none per group, destructive last in red; dark: 1 px hairline, no shadow.",
    },
    "v2-glass": {
      label: "V2 glass",
      description: "V2's rows on a clearer, more frosted 12 px panel that keeps a soft shadow in dark too.",
    },
  },
  defaultArm: "off",
});

export type MenuStyleArm = keyof typeof menuStyleV2.arms;

/// The v2 panel's inset (the pill's distance from the panel's edge), in px: popupSurface.css's
/// `--menu-v2-inset` and the flush submenu's offsets (Menu.tsx Submenu) use the same number.
export const MENU_V2_INSET = 4;

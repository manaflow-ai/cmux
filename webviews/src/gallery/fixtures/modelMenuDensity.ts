// The compact model menu's density versions (Leo 2026-10-28: "AND I THINK IT'S ALL SO STUPIDLY
// SPACED AND STYLED IT'S FUCKING TONKA TOYS"). `native` ships in modelPicker.css: a macOS menu's
// 28px rows, 24px in submenus and 13px chrome type. The others override it for comparison:
// `tight` is a denser list, `roomy` a step up, and `before` the menu as it was (36px rows in the
// transcript's content size).
export type MenuDensity = "native" | "tight" | "roomy" | "before";

export const MENU_DENSITIES: readonly MenuDensity[] = ["native", "tight", "roomy", "before"];

export const DENSITY_CSS: Record<MenuDensity, string> = {
  native: "",
  tight: `
.acpmux-quick-menu { --ui-row-height: 24px; }
.acpmux-quick-menu.acpmux-quick-submenu { --ui-row-height: 22px; }
`,
  roomy: `
.acpmux-quick-menu { --ui-row-height: 32px; }
.acpmux-quick-menu.acpmux-quick-submenu { --ui-row-height: 28px; }
`,
  before: `
.acpmux-quick-menu, .acpmux-quick-menu.acpmux-quick-submenu { --ui-row-height: 36px; font-size: var(--text-content); padding: 6px; border-radius: 12px; }
.acpmux-quick-menu .ui-menu-item.acpmux-quick-item, .acpmux-quick-search input, .acpmux-quick-rail-tab { font-size: var(--text-content); }
.acpmux-quick-menu .ui-menu-item.acpmux-quick-item { border-radius: 8px; gap: 8px; }
.acpmux-quick-rail-tab { padding: var(--ui-popup-padding); border-radius: 6px; }
.acpmux-quick-rail { gap: 4px; padding: 6px; }
.acpmux-quick-fast-toggle { width: 30px; height: calc(var(--ui-row-height) * 0.65); }
.acpmux-quick-fast-toggle > span, .acpmux-quick-fast-toggle::after { width: calc(var(--ui-row-height) * 0.5); height: calc(var(--ui-row-height) * 0.5); }
`,
};

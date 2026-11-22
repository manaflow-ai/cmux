// Settings > Appearance's presets (Leo, 10-20: "good presets"): one pick sets the window's Opacity
// and Material and puts every surface's opacity back on the window's, so a look is one click and
// one Undo instead of a slider per surface. A preset never touches the background or the theme.
import type { KeyState } from "./appearanceHistory";
import { rowsByKey } from "./schema";
import type { SettingsState } from "./store";

export const OPACITY_KEY = "appearance.backgroundOpacity";
export const MATERIAL_KEY = "appearance.backgroundBlur";
const SURFACE_OPACITY = /^appearance\.surfaces\.[A-Za-z]+\.opacity$/;

export interface AppearancePreset {
  id: string;
  /** The preset's name in the strings catalog. */
  nameKey: string;
  opacity: number;
  /** One of appearance.backgroundBlur's choices. */
  material: string;
}

export const APPEARANCE_PRESETS: readonly AppearancePreset[] = [
  { id: "solid", nameKey: "settingsPage.presets.solid", opacity: 1, material: "none" },
  { id: "frosted", nameKey: "settingsPage.presets.frosted", opacity: 0.8, material: "frosted" },
  { id: "glass", nameKey: "settingsPage.presets.glass", opacity: 0.6, material: "glass" },
  { id: "clear", nameKey: "settingsPage.presets.clear", opacity: 0.35, material: "glass-clear" },
];

let surfaceKeys: string[] | null = null;
/** Every surface's opacity key (each inherits the window's while unset). */
export function surfaceOpacityKeys(): string[] {
  surfaceKeys ??= [...rowsByKey.keys()].filter((key) => SURFACE_OPACITY.test(key));
  return surfaceKeys;
}

/** The states a preset puts the window and the surfaces in. */
export function presetTargets(state: SettingsState, preset: AppearancePreset): KeyState[] {
  return [
    { kind: "setting", key: MATERIAL_KEY, value: preset.material, customized: true },
    { kind: "setting", key: OPACITY_KEY, value: preset.opacity, customized: true },
    ...surfaceOpacityKeys().flatMap((key) => {
      const row = state.rows.get(key);
      return row ? [{ kind: "setting" as const, key, value: row.default, customized: false }] : [];
    }),
  ];
}

/** The preset the page's values match now, or null when the person's look is their own. */
export function activePreset(state: SettingsState): string | null {
  const opacity = state.rows.get(OPACITY_KEY);
  const material = state.rows.get(MATERIAL_KEY);
  if (!opacity?.customized || !material?.customized) return null;
  if (surfaceOpacityKeys().some((key) => state.rows.get(key)?.customized)) return null;
  const match = APPEARANCE_PRESETS.find(
    (preset) => preset.opacity === opacity.value && preset.material === material.value,
  );
  return match?.id ?? null;
}

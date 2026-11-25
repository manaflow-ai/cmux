// Glass Controls (Taste Board #164): `appearance.glassControls`, off by default. On, the page's
// `.settings` root carries `data-glass-controls` and glassControls.css draws the knobs of its
// switches and sliders as glass. Off, the attribute is absent and the controls are today's.
import { valueOf, type SettingsState } from "./store";

export const GLASS_CONTROLS_KEY = "appearance.glassControls";

/** Whether the page draws glass knobs: only an explicit `true` turns them on. */
export function glassControlsOn(state: SettingsState): boolean {
  return valueOf(state, GLASS_CONTROLS_KEY) === true;
}

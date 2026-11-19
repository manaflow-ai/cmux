// The Settings switches that pick an experiment's arm (Settings > Experimental > Experiments,
// schemas/settings/source/experiments.json). The app sends every `experiments.*` switch that is on,
// by name, with each page's theme (WebTheme.experiments): `window.cmuxExperimentSettings` is set
// before the page's modules run, and a `cmux-experiment-settings` event follows each change.
// experimentArm reads the arms here after the host's own overrides (`cmuxExperiments`, the gallery)
// and before the localStorage debug key, so a switch that is off changes nothing.
//
// A new switch: one toggle row in experiments.json and one line in SETTING_ARMS.

/** `experiments.<name>` switch name to the experiment id and the arm it runs while on. */
export const SETTING_ARMS: Readonly<Record<string, { experiment: string; arm: string }>> = {
  menuStyleV2: { experiment: "menu-style-v2", arm: "v2" },
  menuRowStates: { experiment: "menu-row-states", arm: "on" },
};

/** The page event the theme bootstrap dispatches when the switches change. */
export const EXPERIMENT_SETTINGS_EVENT = "cmux-experiment-settings";

declare global {
  // eslint-disable-next-line no-var -- a host-installed global (WebTheme's bootstrap), read per lookup.
  var cmuxExperimentSettings: Record<string, unknown> | undefined;
}

/** Experiment id to arm, from the switches that are on now. */
export function settingArms(
  settings: Record<string, unknown> | undefined = globalThis.cmuxExperimentSettings,
): Record<string, string> {
  const arms: Record<string, string> = {};
  if (!settings) return arms;
  for (const [name, on] of Object.entries(settings)) {
    const entry = Object.hasOwn(SETTING_ARMS, name) ? SETTING_ARMS[name] : undefined;
    if (entry && on === true) arms[entry.experiment] = entry.arm;
  }
  return arms;
}

/** Calls `listener` after each change of the switches; returns the unsubscribe. */
export function subscribeExperimentSettings(listener: () => void): () => void {
  const target = globalThis.window;
  if (!target?.addEventListener) return () => {};
  target.addEventListener(EXPERIMENT_SETTINGS_EVENT, listener);
  return () => target.removeEventListener(EXPERIMENT_SETTINGS_EVENT, listener);
}

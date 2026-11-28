// Which experiment arm a Settings > Advanced > Experiments switch runs while it is on. The switches
// themselves live in switches.ts; agent pages get them from the agent bridge (applyExperiments), and
// every other page (Settings, the sidebar, any page that draws a menu) from its theme
// (WebTheme.experiments): `window.cmuxExperimentSettings` is set before the page's modules run, and a
// `cmux-experiment-settings` event follows each change. This module hands that object to switches.ts,
// so both routes fill one store.
// experimentArm reads the arms here after the host's own overrides (`cmuxExperiments`, the gallery)
// and before the localStorage debug key, so a switch that is off changes nothing.
//
// A switch that picks an arm: its row in schemas/settings/source/experiments.json and one entry in
// SETTING_ARMS.
import { experimentSwitches, experimentSwitchOn, setExperimentSwitches, experimentSwitchOff } from "./switches";

type SettingArm = { experiment: string; arm: string };
type SettingArmEntry = SettingArm | readonly SettingArm[];

/** `experiments.<name>` switch name to the experiment arm(s) it runs while on. */
export const SETTING_ARMS: Readonly<Record<string, SettingArmEntry>> = {
  menuStyleV2: { experiment: "menu-style-v2", arm: "v2" },
  menuRowStates: { experiment: "menu-row-states", arm: "on" },
  toastGlass: { experiment: "toast-glass", arm: "host" },
  composerHatGroups: { experiment: "subagent-tray-fold-head", arm: "line" },
  forumCallCard: { experiment: "forum-call-card", arm: "card" },
};

/**
 * The arm(s) a switch that is on by default runs when the person turns it off. Its on arms are the
 * experiments' defaults, so a page with no host (the gallery, tests) draws the shipped look.
 * composerHatGroups: on by default since Leo, 2026-11-25 ("did u guys fix the composer hat yet :( let's
 * go ahead on those"); off keeps the earlier tally header.
 */
export const SETTING_OFF_ARMS: Readonly<Record<string, SettingArmEntry>> = {
  composerHatGroups: { experiment: "subagent-tray-fold-head", arm: "tally" },
};

function armsFor(entry: SettingArmEntry): readonly SettingArm[] {
  // Array.isArray does not narrow a readonly array; "experiment" in entry does.
  return "experiment" in entry ? [entry] : entry;
}

/** The page event the theme bootstrap dispatches when the switches change. */
export const EXPERIMENT_SETTINGS_EVENT = "cmux-experiment-settings";

declare global {
  // eslint-disable-next-line no-var -- a host-installed global (WebTheme's bootstrap), read on change.
  var cmuxExperimentSettings: Record<string, unknown> | undefined;
}

// settingArms() with the store's own reads, kept against the switches object it came from: every
// experimentArm() call on a render path asks for it (a chat switch made thousands of calls, 2-3 ms of
// rebuilt maps), and the store swaps in a new object on any change, so identity is the whole key.
let cached: { switches: ReturnType<typeof experimentSwitches>; arms: Readonly<Record<string, string>> } | undefined;

/** Experiment id to arm, from the switches that are on now, and those on by default turned off. */
export function settingArms(
  on: (name: string) => boolean = experimentSwitchOn,
  off: (name: string) => boolean = experimentSwitchOff,
): Readonly<Record<string, string>> {
  if (on !== experimentSwitchOn || off !== experimentSwitchOff) return buildSettingArms(on, off);
  const switches = experimentSwitches();
  if (cached?.switches !== switches) cached = { switches, arms: Object.freeze(buildSettingArms(on, off)) };
  return cached.arms;
}

function buildSettingArms(on: (name: string) => boolean, off: (name: string) => boolean): Record<string, string> {
  const arms: Record<string, string> = {};
  for (const [name, entry] of Object.entries(SETTING_ARMS)) {
    if (!on(name)) continue;
    for (const arm of armsFor(entry)) arms[arm.experiment] = arm.arm;
  }
  for (const [name, entry] of Object.entries(SETTING_OFF_ARMS)) {
    if (!off(name)) continue;
    for (const arm of armsFor(entry)) arms[arm.experiment] = arm.arm;
  }
  return arms;
}

/** The switch that picks an arm of `experimentId`, if any. */
const ALL_SETTING_ARMS: Readonly<Record<string, SettingArmEntry>> = { ...SETTING_ARMS, ...SETTING_OFF_ARMS };

export function switchFor(experimentId: string): string | undefined {
  const all = ALL_SETTING_ARMS;
  return Object.keys(all).find((name) => armsFor(all[name]!).some((arm) => arm.experiment === experimentId));
}

// The theme route: what the bootstrap set before this module ran, then each change. A page with no
// theme bootstrap (the gallery, tests) never sets the global, so nothing here touches its switches.
const target = globalThis.window;
if (target?.addEventListener) {
  if (globalThis.cmuxExperimentSettings !== undefined) setExperimentSwitches(globalThis.cmuxExperimentSettings);
  target.addEventListener(EXPERIMENT_SETTINGS_EVENT, () => setExperimentSwitches(globalThis.cmuxExperimentSettings));
}

// The composer bar's controls from the keyboard (Lawrence 2026-11-19: "hovering on each of the
// things should show keyboard shortcuts like cmd ctrl m, give all of them keyboard shortcuts").
// Each is an app action (`agentPane.composer.*`, Ctrl-Opt-Cmd and a letter by default, bound in
// Settings and cmux.json); the host sends the page `composer.<control>` and the page opens the
// control through its registered opener (pickerOpeners.ts), the path a click and automation take.
import { openPicker } from "./pickerOpeners";
import { SHORTCUT_ACTIONS, useShortcut } from "./shortcuts";
import type { StringKey } from "./i18n";

/// The controls a shortcut opens, by the name the host's command carries.
export type ComposerControl =
  | "addMenu"
  | "chooseFolder"
  | "chooseComputer"
  | "switchMode"
  | "togglePlan"
  | "agentOptions"
  | "showContextUsage";

/// The Plan and Build toggle's opener name (ComposerPickers): a toggle, so its "opener" flips it.
export const PLAN_TOGGLE_OPENER = "PlanToggle";

/// The location chips by the opener names they register (`useLocationOpener`), with the control
/// each belongs to: the folder chip, and the one computer chip the composer shows (Computer on
/// this Mac, Machine or Environment in the cloud, Run where it asks where to run).
const LOCATION_MENUS: Readonly<Record<string, ComposerControl>> = {
  Location: "chooseFolder",
  Computer: "chooseComputer",
  Machine: "chooseComputer",
  Environment: "chooseComputer",
  Run: "chooseComputer",
};

/// The opener names a control may be registered under, in the order the page tries them. A name
/// in `StringKey` form is the chip's translated label (`translate`).
const OPENERS: Readonly<Record<ComposerControl, readonly ({ key: StringKey } | string)[]>> = {
  addMenu: [{ key: "composer.add" }],
  chooseFolder: ["Location"],
  chooseComputer: ["Computer", "Machine", "Environment", "Run"],
  switchMode: [{ key: "picker.mode" }],
  togglePlan: [PLAN_TOGGLE_OPENER],
  agentOptions: [{ key: "picker.options" }],
  showContextUsage: [{ key: "context.title" }],
};

/// The action whose shortcut runs `control`, for its chip's tooltip.
export const COMPOSER_CONTROL_ACTIONS: Readonly<Record<ComposerControl, string>> = {
  addMenu: SHORTCUT_ACTIONS.composerAddMenu,
  chooseFolder: SHORTCUT_ACTIONS.composerChooseFolder,
  chooseComputer: SHORTCUT_ACTIONS.composerChooseComputer,
  switchMode: SHORTCUT_ACTIONS.composerSwitchMode,
  togglePlan: SHORTCUT_ACTIONS.composerTogglePlan,
  agentOptions: SHORTCUT_ACTIONS.composerAgentOptions,
  showContextUsage: SHORTCUT_ACTIONS.composerShowContextUsage,
};

/// The action a location chip's shortcut runs, by the opener name it registers ("Location"), or
/// undefined for a chip no shortcut opens.
export function locationMenuAction(menu: string | undefined): string | undefined {
  const control = menu ? LOCATION_MENUS[menu] : undefined;
  return control ? COMPOSER_CONTROL_ACTIONS[control] : undefined;
}

/// Opens the control a host command names (`composer.chooseFolder` names `chooseFolder`): true
/// when a mounted control took it, false when the composer shows none (a started chat's folder
/// chip, a harness with no options), so the key does nothing.
export function openComposerControl(command: string, translate: (key: StringKey) => string): boolean {
  const names = Object.hasOwn(OPENERS, command) ? OPENERS[command as ComposerControl] : undefined;
  if (!names) return false;
  return names.some((name) => openPicker(typeof name === "string" ? name : translate(name.key)));
}

/// The keycaps of the shortcut that opens the location chip registered as `menu`, for its tooltip.
export function useLocationShortcut(menu: string | undefined): string | undefined {
  return useShortcut(locationMenuAction(menu) ?? "");
}

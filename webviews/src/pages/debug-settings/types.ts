// Wire types of the `cmux.debug.tunables` page namespace. The Swift tunable registry
// (CmuxNextDesign Tunables, TunableCatalog) is the source of truth; DebugSettingsModel+Page.swift
// encodes it. The page draws every row from `control`, so a new tunable needs no page code.

export type TunableUnit = "points" | "seconds" | "fraction" | "multiplier" | "pointsPerSecond" | "count";

export interface NumberLimits {
  min: number;
  max: number;
  step: number;
  unit: TunableUnit;
}

export interface SpringLimits extends NumberLimits {
  label: string;
}

export interface ChoiceOption {
  value: string;
  title: string;
  /** Color choices: the role's color in the window theme (`#RRGGBB`). */
  swatch?: string;
}

export type TunableControl =
  | ({ type: "number" } & NumberLimits)
  | { type: "bool"; on: string; off: string }
  | { type: "choice"; options: ChoiceOption[] }
  | { type: "color"; options: ChoiceOption[] }
  | { type: "spring"; response: SpringLimits; damping: SpringLimits };

export interface SpringValue {
  response: number;
  dampingFraction: number;
}

export type TunableValue = number | boolean | string | SpringValue;

export interface TunableRow {
  key: string;
  section: string;
  label: string;
  help: string;
  control: TunableControl;
  value: TunableValue;
  default: TunableValue;
  changed: boolean;
  /** The value as the Swift window shows it (unit, option title). */
  value_text: string;
  /** "Default: …", localized. */
  default_text: string;
}

export interface TunableSectionInfo {
  id: string;
  title: string;
  /** SF Symbol name (the native sidebar's icon). */
  symbol: string;
  count: number;
  changed: number;
}

export interface TunableGroup {
  id: string;
  title: string;
  rows: TunableRow[];
}

/** `cmux.debug.tunables.state`: the view state the app owns and the rows it shows. */
export interface DebugSettingsState {
  query: string;
  /** `all`, `changed` or a section id. */
  selection: string;
  total: number;
  changed: number;
  visible: number;
  sections: TunableSectionInfo[];
  groups: TunableGroup[];
  notice?: string;
}

export const DebugTunablesOps = {
  state: "cmux.debug.tunables.state",
  viewSet: "cmux.debug.tunables.view.set",
  set: "cmux.debug.tunables.set",
  reset: "cmux.debug.tunables.reset",
  export: "cmux.debug.tunables.export",
  changed: "cmux.debug.tunables.changed",
} as const;

/** The native op for the pasteboard, when the page origin cannot use the async clipboard. */
export const CLIPBOARD_WRITE = "cmux.app.clipboard.write";

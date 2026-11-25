// The intro walk's writes (hq RFD 0057): the look bundles, the trust and noise rows and Tidy, as plain
// data over settings paths. Every click is one `cmux.onboarding.makeItYours.walk` op, which the host
// writes in one publish; Skip puts every path back as it was when the window opened.
//
// A bundle sets a whole look in one click. It writes every path any bundle sets: its own values, and the
// window's opening values for the rest, so moving from one tile to another never leaves the last one's
// settings behind and House is exactly what the person had. Only paths whose value changes are sent.
// No pick flips a default by itself: each row opens on what the settings hold (the shipped value on a
// new Mac), and Tidy is off unless the person already has it.
import type { MakeItYoursState } from "./ops";

export type WalkValue = string | number | boolean | null;
/** Settings by dotted path; null (or absent): unset, the shipped default. */
export type WalkValues = Record<string, WalkValue>;
export interface WalkWrite {
  path: string;
  /** null removes the setting (its shipped default). */
  value: WalkValue;
}

export const WALK_PATHS = {
  template: "tabs.newTabTemplate",
  density: "appearance.density",
  background: "appearance.background",
  opacity: "appearance.backgroundOpacity",
  material: "appearance.backgroundBlur",
  permission: "agents.defaultPermissionMode",
  desktop: "notifications.desktop",
  sound: "notifications.sound",
  twoTone: "appearance.twoTone",
  calm: "ui.calm",
  animations: "ui.animations.enabled",
  archive: "agents.chats.archiveInactive",
  autoArchive: "workspaces.autoArchive.style",
  settle: "sidebar.settleFinished",
} as const;
const P = WALK_PATHS;

/** What an unset path means (schemas/defaults/cmux-next.json), so an unset value and its default match. */
const SHIPPED: WalkValues = {
  [P.template]: null,
  [P.density]: "cozy",
  [P.background]: null,
  [P.opacity]: null,
  [P.material]: null,
  [P.permission]: "fullAccess",
  [P.desktop]: "unlessFocused",
  [P.sound]: "default",
  [P.twoTone]: "off",
  [P.calm]: "off",
  [P.animations]: true,
  [P.archive]: "never",
  [P.autoArchive]: "manual",
  [P.settle]: false,
};

/** The step's settings now, by dotted path: its own choices and the host's `walk` values. */
export function walkValues(choices: MakeItYoursState): WalkValues {
  const walk = (choices.walk ?? {}) as WalkValues;
  const values: WalkValues = {};
  for (const path of Object.values(P)) values[path] = walk[path] ?? null;
  values[P.template] = choices.workStyle === "terminal" ? "terminal" : null;
  values[P.density] = choices.density;
  values[P.background] = choices.background;
  values[P.opacity] = choices.opacitySet ? choices.opacity : null;
  values[P.material] = choices.material;
  return values;
}

const effective = (values: WalkValues, path: string): WalkValue => values[path] ?? SHIPPED[path] ?? null;

/** `target` at `path`, written as the opening value when they mean the same (so the file keeps its
 * own form: an unset default stays unset). */
function resolve(opened: WalkValues, path: string, target: WalkValue): WalkValue {
  return effective(opened, path) === (target ?? SHIPPED[path] ?? null) ? (opened[path] ?? null) : target;
}

/** The writes that take `current` to `targets`, dropping the ones already true. */
function diff(targets: WalkValues, current: WalkValues): WalkWrite[] {
  return Object.entries(targets)
    .filter(([path, value]) => effective(current, path) !== (value ?? SHIPPED[path] ?? null))
    .map(([path, value]) => ({ path, value }));
}

// MARK: Look bundles

export type WalkBundleId = "house" | "glasshouse" | "twoToneStudio" | "quietSolid" | "denseOperator";

export interface WalkBundleDef {
  id: WalkBundleId;
  /** The tile's name and line (Localizable.xcstrings). */
  nameKey: string;
  lineKey: string;
  /** What the one write sets; every other bundle path goes back to its opening value. */
  sets: WalkValues;
  /** How its miniature draws (walkArms.tsx `Miniature`). */
  traits: { glass?: boolean; twoTone?: boolean; solid?: boolean; dense?: boolean };
}

const K = "onboarding.makeItYours.bundle.";

/** The five look tiles, House (what the person has) first. */
export const LOOK_BUNDLES: readonly WalkBundleDef[] = [
  { id: "house", nameKey: `${K}house`, lineKey: `${K}house.line`, sets: {}, traits: {} },
  {
    id: "glasshouse",
    nameKey: `${K}glasshouse`,
    lineKey: `${K}glasshouse.line`,
    sets: { [P.background]: null, [P.material]: "glass-clear", [P.opacity]: 0.9, [P.twoTone]: "off" },
    traits: { glass: true },
  },
  {
    id: "twoToneStudio",
    nameKey: `${K}twoTone`,
    lineKey: `${K}twoTone.line`,
    sets: { [P.twoTone]: "auto", [P.background]: null },
    traits: { twoTone: true },
  },
  {
    id: "quietSolid",
    nameKey: `${K}quietSolid`,
    lineKey: `${K}quietSolid.line`,
    sets: {
      [P.background]: null,
      [P.material]: "none",
      [P.twoTone]: "off",
      [P.calm]: "calm",
      [P.desktop]: "whenInactive",
      [P.permission]: "ask",
    },
    traits: { solid: true },
  },
  {
    id: "denseOperator",
    nameKey: `${K}dense`,
    lineKey: `${K}dense.line`,
    sets: { [P.template]: "terminal", [P.density]: "ultraCompact", [P.animations]: false, [P.sound]: "none" },
    traits: { dense: true },
  },
];

/** Every path some bundle sets. */
const BUNDLE_PATHS = [...new Set(LOOK_BUNDLES.flatMap((bundle) => Object.keys(bundle.sets)))];

function bundleTargets(bundle: WalkBundleDef, opened: WalkValues): WalkValues {
  return Object.fromEntries(
    BUNDLE_PATHS.map((path) => [
      path,
      path in bundle.sets ? resolve(opened, path, bundle.sets[path]!) : (opened[path] ?? null),
    ]),
  );
}

/** The one write that makes `bundle` the look. */
export function bundleWrites(bundle: WalkBundleDef, opened: WalkValues, current: WalkValues): WalkWrite[] {
  return diff(bundleTargets(bundle, opened), current);
}

/** The bundle the settings show now (House when nothing changed); null once a row was changed past one. */
export function pickedBundle(opened: WalkValues, current: WalkValues): WalkBundleId | null {
  return LOOK_BUNDLES.find((bundle) => bundleWrites(bundle, opened, current).length === 0)?.id ?? null;
}

// MARK: Tidy (a bundle that stacks on any look; off by default)

const TIDY: WalkValues = { [P.archive]: "7d", [P.autoArchive]: "suggest", [P.settle]: true };

export function tidyOn(current: WalkValues): boolean {
  return diff(TIDY, current).length === 0;
}

/** On: the three tidy settings. Off: what was set at open (the shipped values when that was tidy too). */
export function tidyWrites(on: boolean, opened: WalkValues, current: WalkValues): WalkWrite[] {
  if (on) return diff(TIDY, current);
  const openedTidy = tidyOn(opened);
  return diff(
    Object.fromEntries(Object.keys(TIDY).map((path) => [path, openedTidy ? null : (opened[path] ?? null)])),
    current,
  );
}

// MARK: Trust: the agents' permission

export type WalkPermission = "ask" | "standard" | "fullAccess";
export const PERMISSIONS: readonly WalkPermission[] = ["ask", "standard", "fullAccess"];

export function permission(current: WalkValues): WalkPermission {
  const value = effective(current, P.permission);
  return PERMISSIONS.includes(value as WalkPermission) ? (value as WalkPermission) : "fullAccess";
}

export function permissionWrites(value: WalkPermission, opened: WalkValues, current: WalkValues): WalkWrite[] {
  return diff({ [P.permission]: resolve(opened, P.permission, value) }, current);
}

// MARK: Noise: banners and sound as one three-way row

export type WalkNoise = "quiet" | "banners" | "bannersSound";
export const NOISES: readonly WalkNoise[] = ["quiet", "banners", "bannersSound"];

export function noise(current: WalkValues): WalkNoise {
  if (effective(current, P.desktop) === "never") return "quiet";
  return effective(current, P.sound) === "none" ? "banners" : "bannersSound";
}

/** Banners keep the opening banner rule (the shipped one when it was off); sound keeps the opening
 * sound (the shipped one when it was none). */
export function noiseWrites(value: WalkNoise, opened: WalkValues, current: WalkValues): WalkWrite[] {
  const desktop = effective(opened, P.desktop) === "never" ? null : (opened[P.desktop] ?? null);
  const sound = effective(opened, P.sound) === "none" ? null : (opened[P.sound] ?? null);
  const targets: WalkValues =
    value === "quiet"
      ? { [P.desktop]: "never", [P.sound]: "none" }
      : value === "banners"
        ? { [P.desktop]: desktop, [P.sound]: "none" }
        : { [P.desktop]: desktop, [P.sound]: sound };
  return diff(targets, current);
}

// MARK: The screens

/** The walk's four screens, in order: look bundles first (hq RFD 0057). */
export type MakeItYoursScreen = "look" | "work" | "trust" | "tune";
export const MAKE_IT_YOURS_SCREENS: readonly MakeItYoursScreen[] = ["look", "work", "trust", "tune"];

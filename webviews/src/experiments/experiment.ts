// Experiments: named sets of alternative implementations ("arms") of one behavior or look, so a
// person can compare them side by side in the gallery (view `compare`) and pick one.
//
// An experiment is defined in code next to the component it varies (`<name>.experiment.ts`): an
// id, a description, its arms (each with a one-line description) and the DEFAULT arm, which is the
// one that ships. The component asks `experimentArm(experiment)` which arm to run. The winner
// ships by changing `defaultArm`; a losing arm is deleted from the definition and its code path.
//
// The chosen arm comes from one place, in this order:
//   1. an override the host installs before the page loads (`globalThis.cmuxExperiments`: the
//      gallery's stage frame sets it from its `arm` query key);
//   2. a Settings switch that is on (Settings > Advanced > Experiments, `experiments.*`;
//      hostSettings.ts maps each to its experiment's arm; useExperimentArm follows a change live);
//   3. the debug key `cmux.experiments` in localStorage, a JSON object `{ "<id>": "<arm>" }`
//      (for dogfood in the app: set it in the web inspector and reload the pane);
//   4. the experiment's `defaultArm`.
// An unknown arm id anywhere falls through to the next source, so a stale key never breaks a page.

import { settingArms } from "./hostSettings";

export type ExperimentArm = {
  /** Short name for the gallery cell header (English: the gallery is a developer tool). */
  label: string;
  /** One line: what this arm does differently. */
  description: string;
};

export type Experiment<Arm extends string = string> = {
  /** Lower kebab case, unique (experiments/registry.ts checks it): `diff-tree-disclosure`. */
  id: string;
  title: string;
  /** One or two sentences: what behavior the arms vary and what to look for. */
  description: string;
  arms: Record<Arm, ExperimentArm>;
  /** The arm that ships. */
  defaultArm: NoInfer<Arm>;
};

/** Identity helper that keeps the arm ids as a literal union. */
export function defineExperiment<const Arm extends string>(experiment: Experiment<Arm>): Experiment<Arm> {
  return experiment;
}

export const EXPERIMENT_ID = /^[a-z0-9]+(-[a-z0-9]+)*$/;
export const ARM_ID = /^[a-z0-9]+(-[a-z0-9]+)*$/;
/** The localStorage debug key. */
export const EXPERIMENTS_STORAGE_KEY = "cmux.experiments";

export type ArmOverrides = Record<string, string>;

declare global {
  // eslint-disable-next-line no-var -- a host-installed global, read once per lookup.
  var cmuxExperiments: ArmOverrides | undefined;
}

// The debug key's parse, kept against its raw text: a lookup on a render path reads the key on
// every call, and parsing it each time cost a chat switch milliseconds. A changed value re-parses.
let stored: { text: string | null | undefined; overrides: Readonly<ArmOverrides> } | undefined;

function storedOverrides(): Readonly<ArmOverrides> {
  let text: string | null | undefined;
  try {
    text = globalThis.localStorage?.getItem(EXPERIMENTS_STORAGE_KEY);
  } catch {
    // No storage (a sandboxed page): no override.
    return {};
  }
  if (stored !== undefined && stored.text === text) return stored.overrides;
  let overrides: ArmOverrides = {};
  try {
    const parsed: unknown = text ? JSON.parse(text) : undefined;
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) overrides = parsed as ArmOverrides;
  } catch {
    // A malformed value: no override.
  }
  stored = { text, overrides: Object.freeze(overrides) };
  return stored.overrides;
}

// The debug key as one pass read it (`withExperimentPass`): a chat's open shapes every turn, and each turn asked
// localStorage again for every experiment it reads (384 reads for 47 turns), though the key cannot change mid-pass.
let passStored: Readonly<ArmOverrides> | undefined;

/** Runs `run` with the debug key read once: every experimentArm() inside it takes that read. Nests. */
export function withExperimentPass<T>(run: () => T): T {
  if (passStored !== undefined) return run();
  passStored = storedOverrides();
  try {
    return run();
  } finally {
    passStored = undefined;
  }
}

/** The arm ids of an experiment, in definition order. */
export function armIds<Arm extends string>(experiment: Experiment<Arm>): Arm[] {
  return Object.keys(experiment.arms) as Arm[];
}

export function isArm<Arm extends string>(experiment: Experiment<Arm>, id: unknown): id is Arm {
  return typeof id === "string" && Object.hasOwn(experiment.arms, id);
}

/** The arm to run: the host override, else a Settings switch, else the debug key, else the default. */
export function experimentArm<Arm extends string>(
  experiment: Experiment<Arm>,
  sources: { overrides?: ArmOverrides; settings?: ArmOverrides; stored?: ArmOverrides } = {},
): Arm {
  const overrides = sources.overrides ?? globalThis.cmuxExperiments ?? {};
  if (isArm(experiment, overrides[experiment.id])) return overrides[experiment.id] as Arm;
  const settings = sources.settings ?? settingArms();
  if (isArm(experiment, settings[experiment.id])) return settings[experiment.id] as Arm;
  const stored = sources.stored ?? passStored ?? storedOverrides();
  if (isArm(experiment, stored[experiment.id])) return stored[experiment.id] as Arm;
  return experiment.defaultArm;
}

/** Problems with a set of experiments: ids, arms and defaults the URL and the registry rely on. */
export function validateExperiments(experiments: readonly Experiment[]): string[] {
  const problems: string[] = [];
  const seen = new Set<string>();
  for (const experiment of experiments) {
    if (!EXPERIMENT_ID.test(experiment.id)) problems.push(`${experiment.id}: the id must be lower kebab case`);
    if (seen.has(experiment.id)) problems.push(`${experiment.id}: duplicate id`);
    seen.add(experiment.id);
    const arms = armIds(experiment);
    if (arms.length < 2) problems.push(`${experiment.id}: an experiment needs at least two arms`);
    for (const arm of arms) {
      if (!ARM_ID.test(arm)) problems.push(`${experiment.id}#${arm}: arm ids are lower kebab case`);
      if (!experiment.arms[arm].description.trim()) problems.push(`${experiment.id}#${arm}: no description`);
    }
    const fallback: string = experiment.defaultArm;
    if (!Object.hasOwn(experiment.arms, fallback))
      problems.push(`${experiment.id}: the default arm ${fallback} is not an arm`);
  }
  return problems;
}

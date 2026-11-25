// Every experiment in the webviews, by id. Each `<name>.experiment.ts(x)` under src/ is found here on
// its own (Vite's import.meta.glob when the page is built; a scan of the same files under bun's test
// runner, which has no import.meta.glob), so a lane adds its experiment file and edits nothing here.
// Every exported `defineExperiment(...)` value of such a file is an experiment.
// Removing an experiment (its winner shipped as the plain code path) removes its file or its export.
import { type Experiment } from "./experiment";

type ExperimentModules = Record<string, Record<string, unknown>>;

function experimentModules(): ExperimentModules {
  // Vite replaces this call with the files when it builds; bun has no import.meta.glob and throws.
  try {
    return import.meta.glob<Record<string, unknown>>("../**/*.experiment.{ts,tsx}", { eager: true });
  } catch {
    return scannedExperimentModules();
  }
}

/** Under bun (tests, scripts): the same files, read from disk and loaded in place. */
function scannedExperimentModules(): ExperimentModules {
  const bun = (globalThis as { Bun?: typeof Bun }).Bun;
  if (!bun) return {};
  const root = `${import.meta.dir}/..`;
  const modules: ExperimentModules = {};
  for (const file of new bun.Glob("**/*.experiment.{ts,tsx}").scanSync({ cwd: root })) {
    modules[`../${file}`] = import.meta.require(`${root}/${file}`) as Record<string, unknown>;
  }
  return modules;
}

function isExperiment(value: unknown): value is Experiment {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Partial<Experiment>;
  return (
    typeof candidate.id === "string" &&
    typeof candidate.defaultArm === "string" &&
    !!candidate.arms &&
    typeof candidate.arms === "object"
  );
}

/** The experiments in `modules`, by file path and then by export order. */
export function experimentsIn(modules: ExperimentModules): Experiment[] {
  return Object.keys(modules)
    .sort((a, b) => a.localeCompare(b))
    .flatMap((path) => Object.values(modules[path]).filter(isExperiment));
}

export const EXPERIMENTS: readonly Experiment[] = experimentsIn(experimentModules());

export function experimentById(id: string): Experiment | undefined {
  return EXPERIMENTS.find((experiment) => experiment.id === id);
}

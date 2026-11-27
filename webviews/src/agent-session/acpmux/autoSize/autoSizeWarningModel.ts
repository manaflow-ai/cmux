/** The known-heavy precheck warning from acpmux's `heavy_precheck::Warning`. */
export type AutoSizeWarningProject = "chromium" | "llvm" | "rustc";
export type AutoSizeWarningShort = "disk" | "memory";

export type AutoSizeWarning = {
  command: string;
  project?: AutoSizeWarningProject;
  short: AutoSizeWarningShort[];
  needsDisk?: number;
  needsMemory?: number;
  text: string;
};

const PROJECTS: ReadonlySet<AutoSizeWarningProject> = new Set(["chromium", "llvm", "rustc"]);
const SHORTAGES: ReadonlySet<AutoSizeWarningShort> = new Set(["disk", "memory"]);

function positiveNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : undefined;
}

/** Reads the Rust payload without allowing malformed host data into the warning row. */
export function readAutoSizeWarning(value: unknown): AutoSizeWarning | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const raw = value as Record<string, unknown>;
  if (typeof raw.command !== "string" || !raw.command.trim()) return undefined;
  if (typeof raw.text !== "string" || !raw.text.trim()) return undefined;
  if (!Array.isArray(raw.short)) return undefined;
  const short = raw.short.filter(
    (item): item is AutoSizeWarningShort => typeof item === "string" && SHORTAGES.has(item as AutoSizeWarningShort),
  );
  if (short.length === 0 || short.length !== raw.short.length) return undefined;
  const project =
    raw.project === undefined
      ? undefined
      : PROJECTS.has(raw.project as AutoSizeWarningProject)
        ? (raw.project as AutoSizeWarningProject)
        : undefined;
  if (raw.project !== undefined && project === undefined) return undefined;
  const needsDisk = raw.needsDisk === undefined ? undefined : positiveNumber(raw.needsDisk);
  const needsMemory = raw.needsMemory === undefined ? undefined : positiveNumber(raw.needsMemory);
  if (raw.needsDisk !== undefined && needsDisk === undefined) return undefined;
  if (raw.needsMemory !== undefined && needsMemory === undefined) return undefined;
  return {
    command: raw.command,
    ...(project === undefined ? {} : { project }),
    short,
    ...(needsDisk === undefined ? {} : { needsDisk }),
    ...(needsMemory === undefined ? {} : { needsMemory }),
    text: raw.text,
  };
}

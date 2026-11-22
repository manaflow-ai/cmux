// A project's worktree recipe and a worktree's setup run, as the session host serves them
// (cmux-tui `git_ops/worktree_recipe.rs` and `worktree_setup.rs`; ops `git.worktree.setup` and
// `project.update` field `worktree`, spec/resource-operations-v2.json). Shared by the agent pane
// (a new worktree chat's setup line) and Settings (the Worktree Setup card); other surfaces import
// the types from here rather than restating them.

/** A recipe as one source spells it: the repository's files, or the project's saved override.
 *  A saved command wins over the repository's; a saved empty command turns the repository's off;
 *  saved `include` lines are added after the repository's. */
export type WorktreeRecipe = {
  setup?: string;
  run?: string;
  teardown?: string;
  /** `.worktreeinclude` lines: the ignored files copied from the main checkout. */
  include?: string[];
};

/** The recipe a new worktree gets: the merged commands, and each source as it is. */
export type ResolvedWorktreeRecipe = {
  setup: string | null;
  run: string | null;
  teardown: string | null;
  include: string[];
  /** What `.worktreeinclude` and `.cmux/worktree.toml` say. */
  repository: WorktreeRecipe;
  /** The project's saved override, when it has one. */
  saved?: WorktreeRecipe;
  /** The repository files read (relative to the main checkout). */
  files: string[];
  /** A file the session host could not read, in its own words. */
  problems?: string[];
};

/** `none`: the recipe copies and runs nothing. `copying` and `running` are live; the rest are final. */
export type WorktreeSetupState = "none" | "copying" | "running" | "succeeded" | "failed" | "timed_out" | "interrupted";

export type WorktreeIncludeReport = { copied: number; kept: number; outside: string[]; problems: string[] };

/** One read of a worktree's setup: its state, and its output from the read's `since`. */
export type WorktreeSetupRun = {
  state: WorktreeSetupState;
  port?: number;
  /** The setup command it runs (none: the recipe only copies files). */
  setup?: string;
  exitCode?: number;
  include?: WorktreeIncludeReport;
  startedMs?: number;
  finishedMs?: number;
  /** The output from `outputStart` to `outputEnd` (at most the host's last 64 KiB). */
  output: string;
  outputStart: string;
  /** The byte offset to read from next (`since`). */
  outputEnd: string;
};

export type WorktreeSetupRead = {
  root: string;
  mainRoot?: string;
  recipe?: ResolvedWorktreeRecipe;
  run: WorktreeSetupRun;
};

const STATES = new Set<WorktreeSetupState>([
  "none",
  "copying",
  "running",
  "succeeded",
  "failed",
  "timed_out",
  "interrupted",
]);

/** True once nothing changes any more: reading again shows the same state. */
export function isFinalSetupState(state: WorktreeSetupState): boolean {
  return state !== "copying" && state !== "running";
}

/** How often a live setup is read again, and the read's own stop: the host's 30-minute deadline
 *  ends every setup, so a reader past it stops whatever the last read said. */
export const SETUP_READ_INTERVAL_MS = 1000;
export const SETUP_READ_DEADLINE_MS = 31 * 60 * 1000;
/** The output a reader keeps: the host's own cap on one read. */
export const SETUP_OUTPUT_CAP = 64 * 1024;

const record = (value: unknown): Record<string, unknown> | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
const text = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined);
const count = (value: unknown): number | undefined => {
  const number = typeof value === "string" && value !== "" ? Number(value) : value;
  return typeof number === "number" && Number.isFinite(number) ? number : undefined;
};
const lines = (value: unknown): string[] =>
  Array.isArray(value) ? value.filter((line): line is string => typeof line === "string") : [];

export function setupState(value: unknown): WorktreeSetupState {
  return typeof value === "string" && STATES.has(value as WorktreeSetupState) ? (value as WorktreeSetupState) : "none";
}

/** A recipe from the wire, keeping only the fields it names. */
export function readRecipe(value: unknown): WorktreeRecipe {
  const source = record(value) ?? {};
  const recipe: WorktreeRecipe = {};
  for (const key of ["setup", "run", "teardown"] as const) {
    const command = text(source[key]);
    if (command !== undefined) recipe[key] = command;
  }
  if (Array.isArray(source.include)) recipe.include = lines(source.include);
  return recipe;
}

export function readResolvedRecipe(value: unknown): ResolvedWorktreeRecipe | undefined {
  const source = record(value);
  if (!source) return undefined;
  const nullable = (field: unknown) => text(field) ?? null;
  const saved = record(source.saved);
  const problems = lines(source.problems);
  return {
    setup: nullable(source.setup),
    run: nullable(source.run),
    teardown: nullable(source.teardown),
    include: lines(source.include),
    repository: readRecipe(source.repository),
    ...(saved ? { saved: readRecipe(saved) } : {}),
    files: lines(source.files),
    ...(problems.length > 0 ? { problems } : {}),
  };
}

export function readSetupRun(value: unknown): WorktreeSetupRun {
  const source = record(value) ?? {};
  const include = record(source.include);
  const port = count(source.port);
  const exitCode = count(source.exit_code);
  const startedMs = count(source.started_ms);
  const finishedMs = count(source.finished_ms);
  const setup = text(source.setup);
  return {
    state: setupState(source.state),
    ...(port !== undefined ? { port } : {}),
    ...(setup ? { setup } : {}),
    ...(exitCode !== undefined ? { exitCode } : {}),
    ...(include
      ? {
          include: {
            copied: count(include.copied) ?? 0,
            kept: count(include.kept) ?? 0,
            outside: lines(include.outside),
            problems: lines(include.problems),
          },
        }
      : {}),
    ...(startedMs !== undefined ? { startedMs } : {}),
    ...(finishedMs !== undefined ? { finishedMs } : {}),
    output: text(source.output) ?? "",
    outputStart: text(source.output_start) ?? "0",
    outputEnd: text(source.output_end) ?? "0",
  };
}

/** A `git.worktree.setup` reply (its `value`, or the result itself). */
export function readSetupReply(reply: unknown): WorktreeSetupRead | undefined {
  const outer = record(reply);
  const source = record(outer?.value) ?? outer;
  const root = text(source?.root);
  if (!source || !root) return undefined;
  const mainRoot = text(source.main_root);
  const recipe = readResolvedRecipe(source.recipe);
  return {
    root,
    ...(mainRoot ? { mainRoot } : {}),
    ...(recipe ? { recipe } : {}),
    run: readSetupRun(source.run),
  };
}

/** The output so far after one more read: a read that starts past what was kept (the host dropped
 *  the middle) starts over from its own start; the kept text never grows past the cap in UTF-8
 *  bytes, as the host counts it. */
export function appendSetupOutput(kept: string, keptEnd: string, read: WorktreeSetupRun): string {
  const joined = read.outputStart === keptEnd ? kept + read.output : read.output;
  // UTF-8 takes at most 3 bytes per UTF-16 unit: a short text is under the cap without encoding it.
  if (joined.length * 3 <= SETUP_OUTPUT_CAP) return joined;
  const bytes = new TextEncoder().encode(joined);
  if (bytes.length <= SETUP_OUTPUT_CAP) return joined;
  // The last cap's worth of bytes, starting on a character's first byte.
  let start = bytes.length - SETUP_OUTPUT_CAP;
  while (start < bytes.length && (bytes[start]! & 0xc0) === 0x80) start += 1;
  return new TextDecoder().decode(bytes.subarray(start));
}

/** The last non-empty line of `output`, for a one-line tail. */
export function lastOutputLine(output: string): string {
  const all = output.split(/\r?\n/);
  for (let index = all.length - 1; index >= 0; index -= 1) {
    const line = all[index]!.trim();
    if (line) return line;
  }
  return "";
}

/** The saved override a project would hold after an edit, or null for none (clears it). */
export function savedRecipe(edit: WorktreeRecipe): WorktreeRecipe | null {
  const out: WorktreeRecipe = {};
  for (const key of ["setup", "run", "teardown"] as const) if (edit[key] !== undefined) out[key] = edit[key];
  const include = (edit.include ?? []).map((line) => line.trim()).filter(Boolean);
  if (include.length > 0) out.include = include;
  return Object.keys(out).length > 0 ? out : null;
}

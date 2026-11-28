// A wrap-up answer that runs `cmux customize` instead of sending its label (wrapUp.ts): the
// agent's `{label, run}` action, with `run` one of four typed requests the daemon allows
// (`_acpmux/customize_run`, cmux-tui acpmux customize_run.rs). The page never builds a command
// line: it sends the typed request, and the daemon checks it again. Leo, 2026-11-24: "A MOTHERFUCKING
// THING AT TURN END OF A WAY TO TRY ON THE CUSTOMIZATION. FUCKING BOOM. AND A WAY TO SAVE IT OR SHARE IT."

export type CustomizeRun =
  | { customize: "try"; target: string; minutes?: number }
  | { customize: "keep" }
  | { customize: "revert" }
  // Go: the PR tried on is merge-ready at the head the person saw (`cmux customize go pr:N`).
  // Leo, 2026-11-25: "have that one click merge ready, or like one click readiness to merge, like
  // the go button for that to happen".
  | { customize: "go"; target: string };

export const MAX_MINUTES = 240;

// The daemon's own check (customize_run.rs `valid_target`): never a flag, never a control character.
const TARGET =
  // eslint-disable-next-line no-control-regex
  /^(?:pr:\d+|sha:[0-9a-fA-F]{7,40}|branch:[A-Za-z0-9._/][A-Za-z0-9._/-]*|dir:[^-\u0000-\u001f\u007f][^\u0000-\u001f\u007f]*|[a-z0-9_][a-z0-9_-]*)$/;

/// `value` as a run, or undefined when it is not one the daemon would take (the same allowlist).
export function readRun(value: unknown): CustomizeRun | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const { customize, target, minutes } = value as Record<string, unknown>;
  if (customize === "keep" || customize === "revert") return { customize };
  if (customize === "go")
    return typeof target === "string" && /^pr:\d{1,9}$/.test(target) ? { customize, target } : undefined;
  if (customize !== "try" || typeof target !== "string" || target.length > 400 || !TARGET.test(target))
    return undefined;
  if (minutes === undefined || minutes === null) return { customize, target };
  if (typeof minutes !== "number" || !Number.isInteger(minutes) || minutes < 1 || minutes > MAX_MINUTES)
    return undefined;
  return { customize, target, minutes };
}

/// Where a card's customize buttons stand. After a try-on succeeds the card offers Keep and
/// Revert, and Go first when what was tried is a PR; any of them ends it.
export type RunPhase = "idle" | "running" | "tried" | "kept" | "reverted" | "went";
export type RunState = {
  phase: RunPhase;
  /** the phase to return to when the run fails */ back: RunPhase;
  failed: boolean;
  /** the PR the last try-on put on (`pr:N`), which Go marks merge-ready */ pr?: string;
  /** what the last successful try-on put on, for Share */ target?: string;
};
export type RunEvent = { type: "start" } | { type: "done"; run: CustomizeRun; ok: boolean };

export const idleRun: RunState = { phase: "idle", back: "idle", failed: false };

export function runReducer(state: RunState, event: RunEvent): RunState {
  if (event.type === "start") {
    return state.phase === "running" ? state : { ...state, phase: "running", back: state.phase, failed: false };
  }
  const kept = {
    ...(state.target === undefined ? {} : { target: state.target }),
    ...(state.pr === undefined ? {} : { pr: state.pr }),
  };
  if (!event.ok) return { phase: state.back, back: state.back, failed: true, ...kept };
  const { run } = event;
  if (run.customize === "try") {
    const pr = /^pr:\d+$/.test(run.target) ? { pr: run.target } : {};
    return { phase: "tried", back: "tried", failed: false, target: run.target, ...pr };
  }
  const phase: RunPhase = run.customize === "keep" ? "kept" : run.customize === "go" ? "went" : "reverted";
  return { phase, back: phase, failed: false, ...kept };
}

/// The one line that puts `target` on someone else's cmux, for Share when the daemon cannot say:
/// code anyone with the repo can fetch (`pr:N`, `branch:B`, `sha:S`). A folder or a profile name
/// lives on this Mac, so only the daemon's Share (customize_run.rs `share`) has a line for it: the
/// setup repo it writes from the profile, or the branch the folder's checkout is pushed to.
export function shareLine(target: string | undefined): string | undefined {
  if (!target || !/^(?:pr|branch|sha):/.test(target)) return undefined;
  const run = readRun({ customize: "try", target });
  return run ? `cmux customize try ${target}` : undefined;
}

/// The card's own Share button (never an agent's action: `readRun` does not take it).
export type ShareRun = { customize: "share"; target: string };
export type RunResult = { ok: boolean; output: string; line?: string };

type Runner = {
  /// Whether the daemon serves `_acpmux/customize_run` now: when not, a typed answer sends its label.
  available(): boolean;
  run(run: CustomizeRun | ShareRun): Promise<RunResult>;
};
let runner: Runner | undefined;

/// The pane's client sets it; tests set their own. Without one a run settles `{ok: false}`.
export function setCustomizeRunner(next: Runner | undefined): void {
  runner = next;
}

export function hasCustomizeRunner(): boolean {
  return runner?.available() === true;
}

export async function runCustomize(run: CustomizeRun | ShareRun): Promise<RunResult> {
  if (!runner) return { ok: false, output: "" };
  try {
    return await runner.run(run);
  } catch {
    return { ok: false, output: "" };
  }
}

/// What Share copies and says for `target`: the daemon's line (a profile's setup repo, a folder's
/// pushed branch, code as it is), else the page's own for code; `note` is the daemon's words, where
/// the setup repo is or why there is no line.
export async function shareTarget(target: string): Promise<{ line?: string; note: string }> {
  const fallback = shareLine(target);
  if (!hasCustomizeRunner()) return { line: fallback, note: "" };
  const result = await runCustomize({ customize: "share", target });
  if (result.ok && result.line) return { line: result.line, note: result.output };
  return { line: fallback, note: fallback ? "" : result.output };
}

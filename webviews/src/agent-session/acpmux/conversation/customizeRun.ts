// A wrap-up answer that runs `cmux customize` instead of sending its label (wrapUp.ts): the
// agent's `{label, run}` action, with `run` one of three typed requests the daemon allows
// (`_acpmux/customize_run`, cmux-tui acpmux customize_run.rs). The page never builds a command
// line: it sends the typed request, and the daemon checks it again. Leo, 2026-11-24: "A MOTHERFUCKING
// THING AT TURN END OF A WAY TO TRY ON THE CUSTOMIZATION. FUCKING BOOM. AND A WAY TO SAVE IT OR SHARE IT."

export type CustomizeRun =
  | { customize: "try"; target: string; minutes?: number }
  | { customize: "keep" }
  | { customize: "revert" };

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
  if (customize !== "try" || typeof target !== "string" || target.length > 400 || !TARGET.test(target))
    return undefined;
  if (minutes === undefined || minutes === null) return { customize, target };
  if (typeof minutes !== "number" || !Number.isInteger(minutes) || minutes < 1 || minutes > MAX_MINUTES)
    return undefined;
  return { customize, target, minutes };
}

/// Where a card's customize buttons stand. After a try-on succeeds the card offers Keep and
/// Revert; either ends it.
export type RunPhase = "idle" | "running" | "tried" | "kept" | "reverted";
export type RunState = {
  phase: RunPhase;
  /** the phase to return to when the run fails */ back: RunPhase;
  failed: boolean;
};
export type RunEvent = { type: "start" } | { type: "done"; run: CustomizeRun; ok: boolean };

export const idleRun: RunState = { phase: "idle", back: "idle", failed: false };

export function runReducer(state: RunState, event: RunEvent): RunState {
  if (event.type === "start") {
    return state.phase === "running" ? state : { phase: "running", back: state.phase, failed: false };
  }
  if (!event.ok) return { phase: state.back, back: state.back, failed: true };
  const phase: RunPhase =
    event.run.customize === "try" ? "tried" : event.run.customize === "keep" ? "kept" : "reverted";
  return { phase, back: phase, failed: false };
}

type Runner = {
  /// Whether the daemon serves `_acpmux/customize_run` now: when not, a typed answer sends its label.
  available(): boolean;
  run(run: CustomizeRun): Promise<{ ok: boolean; output: string }>;
};
let runner: Runner | undefined;

/// The pane's client sets it; tests set their own. Without one a run settles `{ok: false}`.
export function setCustomizeRunner(next: Runner | undefined): void {
  runner = next;
}

export function hasCustomizeRunner(): boolean {
  return runner?.available() === true;
}

export async function runCustomize(run: CustomizeRun): Promise<{ ok: boolean; output: string }> {
  if (!runner) return { ok: false, output: "" };
  try {
    return await runner.run(run);
  } catch {
    return { ok: false, output: "" };
  }
}

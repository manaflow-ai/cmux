// The Add Machine card's checklist (plans/cmux-next/add-machine-DESIGN.md): the steps of one
// `cmux-tui acp host enroll|doctor --json` run, filled in live from the CLI's JSON lines the host
// relays. Before a step's line arrives it is pending; the first pending step after the last
// finished one is running. A step this build does not know joins after the last line that
// arrived, by its raw name.

export type HostStepState = "ok" | "fixed" | "fail" | "warn" | "skip";

/** One finished step: `{"step","state","detail","fix","reason"}`. */
export interface HostStepResult {
  step: string;
  state: HostStepState;
  detail: string;
  /** A sentence for a person; never a command cmux runs for them. */
  fix?: string;
  reason?: string;
}

/** The last line of a run: `{"report":{...}}`. */
export interface HostReport {
  name: string;
  host: string;
  ok: boolean;
  steps: HostStepResult[];
}

export type HostLine = { step: HostStepResult } | { report: HostReport };

/** The steps in the order they run. A newer cmux-tui may send others; they show by their raw name. */
export const KNOWN_STEPS = [
  "reach",
  "install",
  "daemon",
  "update",
  "harness",
  "peer",
  "peer-back",
  "identity",
  "approvals",
] as const;

const STATES: readonly string[] = ["ok", "fixed", "fail", "warn", "skip"];

/** A state this build does not know reads as a warning: shown, never a pass. */
function state(value: unknown): HostStepState {
  return typeof value === "string" && STATES.includes(value) ? (value as HostStepState) : "warn";
}

function stepResult(value: unknown): HostStepResult | undefined {
  if (!value || typeof value !== "object") return undefined;
  const raw = value as Record<string, unknown>;
  if (typeof raw.step !== "string" || typeof raw.state !== "string") return undefined;
  const fix = typeof raw.fix === "string" && raw.fix !== "" ? raw.fix : undefined;
  return {
    step: raw.step,
    state: state(raw.state),
    detail: typeof raw.detail === "string" ? raw.detail : "",
    ...(fix ? { fix } : {}),
    ...(typeof raw.reason === "string" ? { reason: raw.reason } : {}),
  };
}

/** Reads one stdout line; undefined for a blank line or anything that is not a step or a report. */
export function parseHostLine(line: string): HostLine | undefined {
  const text = line.trim();
  if (!text.startsWith("{")) return undefined;
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    return undefined;
  }
  if (!value || typeof value !== "object") return undefined;
  const report = (value as { report?: unknown }).report;
  if (report && typeof report === "object") {
    const raw = report as Record<string, unknown>;
    if (
      typeof raw.name === "string" &&
      typeof raw.host === "string" &&
      typeof raw.ok === "boolean" &&
      Array.isArray(raw.steps)
    ) {
      const steps = raw.steps.map(stepResult);
      if (steps.every((step) => step))
        return { report: { name: raw.name, host: raw.host, ok: raw.ok, steps: steps as HostStepResult[] } };
    }
    return undefined;
  }
  const step = stepResult(value);
  return step ? { step } : undefined;
}

export type RowStatus = { kind: "pending" } | { kind: "running" } | { kind: "done"; state: HostStepState };

export interface ChecklistRow {
  step: string;
  status: RowStatus;
  detail: string;
  fix?: string;
}

const pending: RowStatus = { kind: "pending" };
const running: RowStatus = { kind: "running" };
const isDone = (row: ChecklistRow) => row.status.kind === "done";
const isDoneAs = (row: ChecklistRow, value: HostStepState) => row.status.kind === "done" && row.status.state === value;

export class Checklist {
  rows: ChecklistRow[];

  /** Every step of `steps` pending: the card before a run starts. */
  constructor(steps: readonly string[] = KNOWN_STEPS) {
    this.rows = steps.map((step) => ({ step, status: pending, detail: "" }));
  }

  /** A run starts: every row of `steps` pending, the first running. */
  start(steps: readonly string[] = KNOWN_STEPS): void {
    this.rows = steps.map((step) => ({ step, status: pending, detail: "" }));
    this.markNextRunning();
  }

  /** One step line arrived. */
  apply(result: HostStepResult): void {
    const row: ChecklistRow = {
      step: result.step,
      status: { kind: "done", state: result.state },
      detail: result.detail,
      ...(result.fix ? { fix: result.fix } : {}),
    };
    for (const each of this.rows) if (each.status.kind === "running") each.status = pending;
    const index = this.rows.findIndex((each) => each.step === result.step);
    if (index >= 0) this.rows[index] = row;
    else this.rows.splice(this.lastDone() + 1, 0, row);
    this.markNextRunning();
  }

  /** The report line: its steps are the truth, and a step it does not name was not run. */
  finish(report: HostReport): void {
    for (const step of report.steps) this.apply(step);
    for (const row of this.rows) if (!isDone(row)) row.status = { kind: "done", state: "skip" };
  }

  /** The run stopped without a report: the running step fails with `detail`, the rest stay pending. */
  stop(detail: string): void {
    let index = this.rows.findIndex((row) => row.status.kind === "running");
    if (index < 0) index = this.rows.findIndex((row) => row.status.kind === "pending");
    // With no row left open (a joined machine's check starts with none), a Check it row carries why.
    if (index < 0) {
      this.rows.push({ step: "check", status: pending, detail: "" });
      index = this.rows.length - 1;
    }
    this.rows[index] = { step: this.rows[index]!.step, status: { kind: "done", state: "fail" }, detail };
  }

  /** Shows `step` as running again (the app installs its own cmux-tui build). */
  run(step: string): void {
    const index = this.rows.findIndex((row) => row.step === step);
    if (index < 0) return;
    for (const row of this.rows) if (row.status.kind === "running") row.status = pending;
    this.rows[index] = { step, status: running, detail: "" };
  }

  row(step: string): ChecklistRow | undefined {
    return this.rows.find((row) => row.step === step);
  }

  /** The first failed row: the one a failed card keeps open with its fix. */
  get failing(): ChecklistRow | undefined {
    return this.rows.find((row) => isDoneAs(row, "fail"));
  }

  /** A run in one line: steps finished, of how many, and the one running now. */
  get summary(): { done: number; total: number; current?: string } {
    const current = this.rows.find((row) => row.status.kind === "running")?.step;
    return { done: this.rows.filter(isDone).length, total: this.rows.length, ...(current ? { current } : {}) };
  }

  /** A step failed or warned: the card opens the whole checklist with its fixes. */
  get needsPerson(): boolean {
    return this.rows.some((row) => isDoneAs(row, "fail") || isDoneAs(row, "warn"));
  }

  private lastDone(): number {
    for (let index = this.rows.length - 1; index >= 0; index--) if (isDone(this.rows[index]!)) return index;
    return -1;
  }

  private markNextRunning(): void {
    for (let index = this.lastDone() + 1; index < this.rows.length; index++) {
      if (this.rows[index]!.status.kind === "pending") {
        this.rows[index]!.status = running;
        return;
      }
    }
  }
}

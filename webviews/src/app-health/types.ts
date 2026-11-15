// The app health snapshot the host pushes (the shared health contract: the Rust health model's
// `snapshot {}` answer, fed by the Swift host). Names match the contract exactly. Only non-healthy
// parts are listed, so a snapshot stays small; times are the model's monotonic clock (ms), never
// wall time, so the page shows no clock times.

export type HealthState = "healthy" | "slow" | "stuck" | "repairing" | "failed";
export type HealthKind = "page" | "renderer" | "sessionDaemon" | "acpmux" | "pageHost" | "roster";
export type HealthAction =
  | "reloadPage"
  | "restartRenderer"
  | "reconnect"
  | "restartConnection"
  | "restartPageHost"
  | "holdReplace"
  | "none";

export interface HealthPart {
  id: string;
  kind: HealthKind;
  /** The part in plain words ("Agent chat", "Session daemon"). */
  label: string;
  state: HealthState;
  sinceMs: number;
  /** One or two sentences a person reads: what is wrong and what the app does about it. */
  detail: string;
  action: HealthAction;
  attempt: number;
  maxAttempts: number;
  nextAtMs: number | null;
  /** The person's Repair may run (`cmux.app.health.repair_now`); false for a restore that still makes progress. */
  canRepair: boolean;
}

export interface HealthReceipt {
  atMs: number;
  id: string;
  action: HealthAction;
  outcome: "started" | "ok" | "failed" | "gaveUp";
  detail: string;
}

/** A person's action the host queued while the session daemon or page host is unreachable. */
export interface HealthPending {
  id: string;
  /** What will happen when the link is back, as a verb phrase ("close Background task"). */
  label: string;
  sinceMs: number;
}

export interface HealthSnapshot {
  worst: HealthState;
  parts: HealthPart[];
  /** The last 64 repairs, newest first. */
  receipts: HealthReceipt[];
  /** Newest first, at most 8; `pendingMore` counts the rest. */
  pending?: HealthPending[];
  pendingMore?: number;
}

export const HealthOps = {
  /** Stream: one `HealthSnapshot` per change, the current one first. */
  snapshot: "cmux.app.health.snapshot",
  /** `{id}` → null: the person's Repair or Repair now for one part. Their own click only. */
  repairNow: "cmux.app.health.repair_now",
} as const;

/** The popover's route on the server card page (`cmux-page://cmux.server-cards/#/app-health`). */
export const APP_HEALTH_ROUTE = "app-health";

import { ProviderNetworkFullError, providerConflictKind } from "./drivers/types";

/**
 * Explicit wait state for a Cloud VM create that found no room.
 *
 * Leo, 2026-11-28: "Queue with an explicit wait state instead of failing
 * after provider start/address exhaustion."
 *
 * A create that opts in (`waitForCapacity` plus an idempotency key) and finds
 * its private network full at admission, or is refused by the provider's
 * start capacity before any machine exists, is answered 202
 * `vm_create_waiting` with a retry-after instead of a 409/503. The row is
 * failed as before (so it holds no address and no pool reservation), and
 * `providerMetadata.createWait` records why it waits (`waiting_for_address`
 * or `waiting_for_capacity`), when the wait began and when it ends.
 *
 * The same-key retry is the drain: it replaces the failed row, re-runs
 * admission and starts the machine once an address or capacity is free. The
 * first deadline carries forward, so retries never extend the bound. A retry
 * past the deadline fails terminally with `vm_create_wait_expired`. Starting
 * needs the caller's request-scoped inputs (provider credential, model-plane
 * gateway), which are never stored, so the server cannot start a waiting
 * machine on its own.
 */

export const CREATE_WAIT_METADATA_KEY = "createWait";
/** Longest a create waits for an address or capacity before it fails. */
export const VM_CREATE_WAIT_MAX_MS = 10 * 60 * 1000;
/** How long a waiting client sleeps before its next same-key retry. */
export const VM_CREATE_WAIT_RETRY_AFTER_SECONDS = 15;
/** Terminal failure code for a wait that ran past its deadline. */
export const VM_CREATE_WAIT_EXPIRED_FAILURE_CODE = "vm_create_wait_expired";

export type VmCreateWaitState = "waiting_for_address" | "waiting_for_capacity";

export type VmCreateWait = {
  readonly state: VmCreateWaitState;
  /** Epoch ms the create first waited. */
  readonly since: number;
  /** Epoch ms past which a retry fails with `vm_create_wait_expired`. */
  readonly deadline: number;
};

/** The wait recorded on a create row, or null when the row is not waiting. */
export function createWaitFromMetadata(metadata: Record<string, unknown> | null | undefined): VmCreateWait | null {
  const raw = metadata?.[CREATE_WAIT_METADATA_KEY];
  if (!raw || typeof raw !== "object") return null;
  const record = raw as { state?: unknown; since?: unknown; deadline?: unknown };
  if (record.state !== "waiting_for_address" && record.state !== "waiting_for_capacity") return null;
  if (typeof record.since !== "number" || typeof record.deadline !== "number") return null;
  return { state: record.state, since: record.since, deadline: record.deadline };
}

/** Which wait a create refusal means, or null when the refusal is not a lack of room. */
export function createWaitStateForCause(cause: unknown): VmCreateWaitState | null {
  let current = cause;
  for (let depth = 0; depth < 8 && current; depth += 1) {
    if (current instanceof ProviderNetworkFullError) return "waiting_for_address";
    if (typeof current !== "object") break;
    current = (current as { cause?: unknown }).cause;
  }
  return providerConflictKind(cause) === "capacity" ? "waiting_for_capacity" : null;
}

/**
 * The wait to record now: a row already waiting keeps its first `since` and
 * its deadline (a retry never extends the bound), a new wait starts the clock.
 */
export function nextCreateWait(state: VmCreateWaitState, previous: VmCreateWait | null, now: number): VmCreateWait {
  if (previous) return { state, since: previous.since, deadline: previous.deadline };
  return { state, since: now, deadline: now + VM_CREATE_WAIT_MAX_MS };
}

export function isCreateWaitExpired(wait: VmCreateWait, now: number): boolean {
  return now >= wait.deadline;
}

/**
 * Client contract of the 202 `vm_create_waiting` answer (the create and
 * workspace routes). Retry the same request with the same idempotency key
 * after `retryAfterSeconds`; past `waitDeadline` the retry fails with
 * `vm_create_wait_expired`.
 */
export type VmCreateWaitingBody = {
  readonly error: "vm_create_waiting";
  readonly message: string;
  readonly retryable: true;
  readonly retryAfterSeconds: number;
  readonly waitState: VmCreateWaitState;
  /** Epoch ms the create first waited. */
  readonly waitingSince: number;
  /** Epoch ms the wait ends. */
  readonly waitDeadline: number;
};

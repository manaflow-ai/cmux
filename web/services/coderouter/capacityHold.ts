// Capacity hold: keep a request on the same model while upstream capacity
// recovers, instead of failing fast.
//
// A capacity blip (429, 5xx/529, an overloaded SSE event, a dropped
// connection) used to cool every account and hand the guest a 503. Agent CLIs
// show that as a final error and end the turn. Switching models is not an
// acceptable fallback because it discards the prompt cache, so the proxies
// hold the request instead: wait with jittered exponential backoff, honoring
// the soonest account cooldown (which already carries the upstream
// `retry-after`), then try the same body again. The hold never starts after
// response bytes reach the client; the pre-output probes guarantee that.
//
// The hold is bounded by a long overall budget and by the route's header
// deadline, so the function always has time to answer before `maxDuration`.

export const CAPACITY_HOLD_ENV = "CODEROUTER_CAPACITY_HOLD_MS";
/** Long enough to ride out a capacity storm, short of the 25-minute header budget. */
export const DEFAULT_CAPACITY_HOLD_MS = 20 * 60_000;
const MAX_CAPACITY_HOLD_MS = 25 * 60_000;
const HOLD_BASE_DELAY_MS = 1_000;
const HOLD_MAX_BACKOFF_MS = 30_000;
/** Jitter added on top of an account cooldown so held requests do not herd. */
const HOLD_COOLDOWN_JITTER_MS = 1_000;
/** A hold must leave at least this much header time for the next attempt. */
const HOLD_ATTEMPT_RESERVE_MS = 10_000;

export function capacityHoldBudgetMs(
  env: Record<string, string | undefined> = process.env,
): number {
  const raw = env[CAPACITY_HOLD_ENV]?.trim();
  if (!raw || !/^\d+$/.test(raw)) return DEFAULT_CAPACITY_HOLD_MS;
  const parsed = Number(raw);
  if (!Number.isSafeInteger(parsed)) return DEFAULT_CAPACITY_HOLD_MS;
  return Math.min(MAX_CAPACITY_HOLD_MS, parsed);
}

/** How long a request waited for capacity, and how many times. */
export type CapacityHoldStats = { readonly heldMs: number; readonly holdCount: number };

/** Telemetry fields for a request that may not have held at all. */
export function capacityHoldTelemetry(stats: CapacityHoldStats | undefined): CapacityHoldStats {
  return stats ?? { heldMs: 0, holdCount: 0 };
}

export type CapacityHoldRuntime = {
  readonly now: () => number;
  readonly sleep: (ms: number, signal: AbortSignal) => Promise<void>;
  readonly random: () => number;
};

export const defaultCapacityHoldRuntime: Omit<CapacityHoldRuntime, "now"> = {
  sleep: sleepWithSignal,
  random: Math.random,
};

/**
 * Tracks one request's hold: how many times it waited and for how long.
 * `wait` returns false when the request should stop holding and answer with
 * its last failure.
 */
export class CapacityHold {
  private rounds = 0;
  private heldTotalMs = 0;
  private readonly deadlineAt: number;

  constructor(
    private readonly runtime: CapacityHoldRuntime,
    startedAt: number,
    budgetMs: number,
    headerDeadlineAt: number,
  ) {
    this.deadlineAt = Math.min(startedAt + budgetMs, headerDeadlineAt - HOLD_ATTEMPT_RESERVE_MS);
  }

  get holdCount(): number {
    return this.rounds;
  }

  get heldMs(): number {
    return Math.round(this.heldTotalMs);
  }

  /**
   * Sleeps before the next routing round. `retryAfterMs` is the soonest time
   * an account becomes usable again; `null` means no account will recover on
   * its own (for example every account has a revoked credential), so holding
   * is pointless. `undefined` means unknown, which backs off without a floor.
   */
  async wait(retryAfterMs: number | null | undefined, signal: AbortSignal): Promise<boolean> {
    if (retryAfterMs === null) return false;
    const now = this.runtime.now();
    const floorMs = retryAfterMs === undefined
      ? 0
      : Math.max(0, retryAfterMs) + this.runtime.random() * HOLD_COOLDOWN_JITTER_MS;
    const backoffMs = Math.min(HOLD_MAX_BACKOFF_MS, HOLD_BASE_DELAY_MS * 2 ** Math.min(this.rounds, 16));
    // Equal jitter: at least half the backoff, so held requests spread out
    // without collapsing to an immediate retry.
    const jitteredMs = backoffMs / 2 + this.runtime.random() * (backoffMs / 2);
    const delayMs = Math.ceil(Math.max(floorMs, jitteredMs));
    if (now + delayMs > this.deadlineAt) return false;
    const sleepStartedAt = this.runtime.now();
    await this.runtime.sleep(delayMs, signal);
    this.rounds += 1;
    this.heldTotalMs += Math.max(delayMs, this.runtime.now() - sleepStartedAt);
    return true;
  }
}

export async function sleepWithSignal(ms: number, signal: AbortSignal): Promise<void> {
  if (signal.aborted) throw signal.reason ?? new DOMException("The operation was aborted.", "AbortError");
  await new Promise<void>((resolve, reject) => {
    const abort = () => {
      clearTimeout(timer);
      reject(signal.reason ?? new DOMException("The operation was aborted.", "AbortError"));
    };
    const timer = setTimeout(() => {
      signal.removeEventListener("abort", abort);
      resolve();
    }, ms);
    signal.addEventListener("abort", abort, { once: true });
  });
}

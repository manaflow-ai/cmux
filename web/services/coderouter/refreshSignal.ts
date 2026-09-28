// Refresh-completion signal for coderouter credential refresh leases.
//
// A refresh lease lives in Postgres (`coderouter_accounts.refresh_lease_*`).
// A sticky session that loses the lease race should wait for the winner and
// then reuse the fresh credential, because moving the session discards its
// prompt cache. The winner may run on this instance or on another serverless
// instance, so the wait has two sources:
//
// 1. An in-process registry. The repository calls `settled(accountId)` after
//    it clears a lease on this instance, which wakes local waiters at once.
// 2. A bounded re-read of the lease row with exponential backoff, for leases
//    held by another instance. The delays go through an injected clock and are
//    cancelled by the request's AbortSignal.
//
// Postgres LISTEN/NOTIFY is not used: the web app reaches PlanetScale through
// a transaction-mode pooler (`prepare: false`), which does not keep LISTEN
// registrations, and a dedicated listener connection per serverless instance
// would cost a direct connection for a sub-second wait.

import { addCoderouterBreadcrumb } from "./observability";

/** Upper bound on one sticky session's wait for an in-flight refresh. */
export const STICKY_REFRESH_PATIENCE_MS = 2_000;
/** Upper bound on settled-then-busy-again cycles inside the patience window. */
export const STICKY_REFRESH_MAX_WAITS = 4;
const INITIAL_LEASE_PROBE_DELAY_MS = 100;
const MAX_LEASE_PROBE_DELAY_MS = 500;

/** Time source for refresh waits. Tests inject a fake; production uses timers. */
export type RefreshWaitClock = {
  readonly now: () => number;
  /** Resolves after `ms`; rejects with `signal.reason` when the signal aborts first. */
  readonly sleep: (ms: number, signal: AbortSignal) => Promise<void>;
};

export const systemRefreshWaitClock: RefreshWaitClock = {
  now: () => performance.now(),
  sleep: (ms, signal) => new Promise<void>((resolve, reject) => {
    if (signal.aborted) {
      reject(abortReason(signal));
      return;
    }
    const abort = () => {
      clearTimeout(timer);
      reject(abortReason(signal));
    };
    const timer = setTimeout(() => {
      signal.removeEventListener("abort", abort);
      resolve();
    }, ms);
    signal.addEventListener("abort", abort, { once: true });
  }),
};

export type RefreshCompletionRegistry = {
  /** Wakes every waiter for the account. Called after a lease is cleared. */
  readonly settled: (accountId: string) => void;
  /** Resolves on the account's next settle; rejects with the abort reason. */
  readonly next: (accountId: string, signal: AbortSignal) => Promise<void>;
};

export type RefreshCompletionRegistryOptions = {
  /** Test hook: runs after a waiter is registered. */
  readonly onWait?: (accountId: string) => void;
};

export function createRefreshCompletionRegistry(
  options: RefreshCompletionRegistryOptions = {},
): RefreshCompletionRegistry {
  const waiters = new Map<string, Set<() => void>>();
  return {
    settled: (accountId) => {
      const accountWaiters = waiters.get(accountId);
      if (!accountWaiters) return;
      waiters.delete(accountId);
      for (const wake of accountWaiters) wake();
    },
    next: (accountId, signal) => new Promise<void>((resolve, reject) => {
      if (signal.aborted) {
        reject(abortReason(signal));
        return;
      }
      const accountWaiters = waiters.get(accountId) ?? new Set<() => void>();
      waiters.set(accountId, accountWaiters);
      const cleanup = () => {
        accountWaiters.delete(wake);
        if (accountWaiters.size === 0 && waiters.get(accountId) === accountWaiters) {
          waiters.delete(accountId);
        }
        signal.removeEventListener("abort", abort);
      };
      const wake = () => {
        cleanup();
        resolve();
      };
      const abort = () => {
        cleanup();
        reject(abortReason(signal));
      };
      accountWaiters.add(wake);
      signal.addEventListener("abort", abort, { once: true });
      options.onWait?.(accountId);
    }),
  };
}

/** Process-wide registry that the lease repository notifies. */
export const refreshCompletionRegistry = createRefreshCompletionRegistry();

export type StickyRefreshPatienceDependencies = {
  readonly registry: RefreshCompletionRegistry;
  /** True while an unexpired refresh lease is held on the account row. */
  readonly leaseActive: (accountId: string, signal: AbortSignal) => Promise<boolean>;
  readonly clock: RefreshWaitClock;
  readonly budgetMs?: number;
  readonly maxWaits?: number;
};

export type StickyRefreshPatienceInput = {
  readonly accountId: string;
  readonly signal?: AbortSignal;
};

/**
 * Runs `attempt`; while it fails with `CodeRouterRefreshBusy`, waits for the
 * account's refresh to settle and runs it again. The last busy error is
 * rethrown at the deadline so the caller moves the session to another account.
 */
export type StickyRefreshPatience = <T>(
  input: StickyRefreshPatienceInput,
  attempt: () => Promise<T>,
) => Promise<T>;

type WaitOutcome = "settled" | "deadline";

export function createStickyRefreshPatience(
  dependencies: StickyRefreshPatienceDependencies,
): StickyRefreshPatience {
  const budgetMs = dependencies.budgetMs ?? STICKY_REFRESH_PATIENCE_MS;
  const maxWaits = dependencies.maxWaits ?? STICKY_REFRESH_MAX_WAITS;
  const waitForSettle = settleWaiter(dependencies);
  return async (input, attempt) => {
    let deadlineAt: number | null = null;
    for (let waits = 0; ; waits += 1) {
      throwIfAborted(input.signal);
      try {
        return await attempt();
      } catch (error) {
        if (!isRefreshBusy(error) || waits >= maxWaits) throw error;
        deadlineAt ??= dependencies.clock.now() + budgetMs;
        const outcome = await waitForSettle(input.accountId, deadlineAt, input.signal);
        if (outcome === "deadline") throw error;
      }
    }
  };
}

function settleWaiter(
  dependencies: StickyRefreshPatienceDependencies,
): (accountId: string, deadlineAt: number, signal: AbortSignal | undefined) => Promise<WaitOutcome> {
  const probeLease = leaseProber(dependencies);
  return async (accountId, deadlineAt, signal) => {
    throwIfAborted(signal);
    // One scope per wait: whichever source wins, the other stops at once.
    const scope = new AbortController();
    const scoped = signal ? AbortSignal.any([signal, scope.signal]) : scope.signal;
    try {
      return await Promise.race([
        dependencies.registry.next(accountId, scoped).then((): WaitOutcome => "settled"),
        probeLease(accountId, deadlineAt, scoped),
      ]);
    } finally {
      scope.abort();
    }
  };
}

function leaseProber(
  dependencies: StickyRefreshPatienceDependencies,
): (accountId: string, deadlineAt: number, signal: AbortSignal) => Promise<WaitOutcome> {
  return async (accountId, deadlineAt, signal) => {
    let delayMs = INITIAL_LEASE_PROBE_DELAY_MS;
    for (;;) {
      const remainingMs = deadlineAt - dependencies.clock.now();
      if (remainingMs <= 0) return "deadline";
      await dependencies.clock.sleep(Math.min(delayMs, remainingMs), signal);
      if (!await leaseStillActive(dependencies, accountId, signal)) return "settled";
      delayMs = Math.min(delayMs * 2, MAX_LEASE_PROBE_DELAY_MS);
    }
  };
}

/**
 * A failed re-read counts as "still held": the wait stays bounded by the
 * deadline, and the caller then moves the session as it did before.
 */
async function leaseStillActive(
  dependencies: StickyRefreshPatienceDependencies,
  accountId: string,
  signal: AbortSignal,
): Promise<boolean> {
  try {
    return await dependencies.leaseActive(accountId, signal);
  } catch (error) {
    if (signal.aborted) throw abortReason(signal);
    addCoderouterBreadcrumb("refresh", "Refresh lease re-read failed", {
      error: error instanceof Error ? error.name : "unknown",
    }, "warning");
    return true;
  }
}

function isRefreshBusy(error: unknown): boolean {
  return typeof error === "object" && error !== null && "_tag" in error &&
    (error as { _tag: unknown })._tag === "CodeRouterRefreshBusy";
}

function throwIfAborted(signal: AbortSignal | undefined): void {
  if (signal?.aborted) throw abortReason(signal);
}

function abortReason(signal: AbortSignal): unknown {
  return signal.reason ?? new DOMException("The operation was aborted.", "AbortError");
}

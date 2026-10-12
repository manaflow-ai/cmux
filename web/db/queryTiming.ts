/**
 * Per-query pool timing for the postgres.js client, so a request that waited
 * for a pooled connection can be told apart from one that waited on a slow
 * query or on a provider. `acquireWaitMs` is the time from the query's
 * creation to the moment postgres.js assigns it a statement on a connection
 * (it is sent); `durationMs` runs to its settlement. postgres.js pipelines
 * plain queries onto open connections, so the acquire wait grows only while
 * every connection is reserved (a transaction holds it) or still connecting:
 * exactly the pool starvation it is meant to expose. Time queued behind
 * another query on a pipelined connection shows in `durationMs` instead.
 */
export type CloudDbQueryTiming = {
  readonly acquireWaitMs: number;
  readonly durationMs: number;
  readonly failed: boolean;
};

/** Returns the recorder for the current request, if any, when a query is created. */
type CloudDbQueryObserver = () => ((timing: CloudDbQueryTiming) => void) | undefined;

let observer: CloudDbQueryObserver | undefined;

/** Installs the process-wide observer (the VM route layer does this once). */
export function setCloudDbQueryObserver(next: CloudDbQueryObserver | undefined): void {
  observer = next;
}

type ObservablePostgresJsQuery = {
  statement?: unknown;
  resolve?: (value: unknown) => unknown;
  reject?: (error: unknown) => unknown;
};

/**
 * Times one postgres.js query without changing when or how it runs: it never
 * calls `then` (postgres.js queries are lazy), it only wraps the query's own
 * statement assignment and settle callbacks.
 */
export function observePostgresJsQueryTiming(query: unknown, now: () => number = () => performance.now()): void {
  const report = observer?.();
  if (!report || !query || typeof query !== "object") return;
  const target = query as ObservablePostgresJsQuery;
  if (typeof target.resolve !== "function" || typeof target.reject !== "function") return;
  const createdAt = now();
  let sentAt: number | undefined;
  let statement = target.statement;
  try {
    Object.defineProperty(target, "statement", {
      configurable: true,
      enumerable: true,
      get: () => statement,
      set: (next: unknown) => {
        if (sentAt === undefined && next) sentAt = now();
        statement = next;
      },
    });
  } catch {
    // A query shape this hook cannot observe runs untimed, never broken.
    return;
  }
  let settled = false;
  const settle = (failed: boolean) => {
    if (settled) return;
    settled = true;
    const end = now();
    try {
      report({ acquireWaitMs: Math.max(0, (sentAt ?? end) - createdAt), durationMs: Math.max(0, end - createdAt), failed });
    } catch {
      // Diagnostics never change a query's outcome.
    }
  };
  const resolve = target.resolve;
  const reject = target.reject;
  target.resolve = (value: unknown) => { settle(false); return resolve(value); };
  target.reject = (error: unknown) => { settle(true); return reject(error); };
}

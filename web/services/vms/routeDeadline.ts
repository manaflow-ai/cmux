import * as Effect from "effect/Effect";
import { VmOperationDeadlineError, type VmWorkflowError } from "./errors";
import { currentVmRequestContext } from "./requestContext";

/**
 * Inline answer deadlines for VM read routes.
 *
 * A provider read can hang for minutes, and an answer after the client gave
 * up reaches no one. A read route answers inside its smallest caller's
 * timeout minus {@link VM_ROUTE_ANSWER_MARGIN_MS}, measured from the
 * request's start, with a 504 vm_provider_timeout.
 *
 * The deadline is inline: the read runs on the request's own fiber and is
 * interrupted at the budget. Nothing is forked, nothing continues after the
 * response, and no route's maxDuration changes. (The forked, after()-based
 * design of #19405 was reverted in #19467 after stats stalls in production;
 * mutations stay unbounded until a later stage.)
 */

/** Time left for the response to reach the client after the route answers. */
export const VM_ROUTE_ANSWER_MARGIN_MS = 5_000;

/** A read never gets less than this, even when auth and lookup spent the budget. */
export const VM_ROUTE_MIN_WINDOW_MS = 10_000;

/**
 * The smallest timeout among each read route's Mac, CLI and iOS callers. A
 * URLRequest without a timeoutInterval gives up after 60 s without a byte.
 */
export const VM_READ_ROUTE_DEADLINES = {
  /** CloudReadRequestCoordinator 30 s budget. */
  stats: { clientTimeoutMs: 30_000 },
  /** VMClient.networkPolicy 30 s. */
  networkRead: { clientTimeoutMs: 30_000 },
  /** VMClient.listSnapshots, 60 s URLRequest default. */
  snapshotList: { clientTimeoutMs: 60_000 },
  /** VMClient.status, 60 s URLRequest default. */
  getVm: { clientTimeoutMs: 60_000 },
  /** No native caller; the 60 s URLRequest default. */
  filesRead: { clientTimeoutMs: 60_000 },
  /** Tunnel read, 60 s URLRequest default. */
  tunnelRead: { clientTimeoutMs: 60_000 },
} as const satisfies Record<string, { readonly clientTimeoutMs: number }>;

export type VmReadRouteOperation = keyof typeof VM_READ_ROUTE_DEADLINES;

export type VmReadDeadline = {
  readonly operation: VmReadRouteOperation;
  /** Overrides the request-context elapsed time (tests, non-route callers). */
  readonly elapsedMs?: number;
};

/** What remains of a read's budget after `elapsedMs` went to auth and lookup; never below the floor. */
export function vmReadAnswerBudgetMs(operation: VmReadRouteOperation, elapsedMs: number): number {
  const total = VM_READ_ROUTE_DEADLINES[operation].clientTimeoutMs - VM_ROUTE_ANSWER_MARGIN_MS;
  return Math.max(Math.min(VM_ROUTE_MIN_WINDOW_MS, total), total - Math.max(0, elapsedMs));
}

/**
 * Bounds a read inline: at the budget the read is interrupted and the
 * answer is {@link VmOperationDeadlineError} (504 vm_provider_timeout). A
 * failure before the budget keeps its own error.
 */
export function withVmReadDeadline<A, R>(
  program: Effect.Effect<A, VmWorkflowError, R>,
  deadline: VmReadDeadline,
): Effect.Effect<A, VmWorkflowError, R> {
  const startedAtMs = currentVmRequestContext()?.startedAtMs;
  const elapsedMs = deadline.elapsedMs ?? (startedAtMs === undefined ? 0 : performance.now() - startedAtMs);
  const answerWithinMs = vmReadAnswerBudgetMs(deadline.operation, elapsedMs);
  return program.pipe(
    Effect.timeoutFail({
      duration: answerWithinMs,
      onTimeout: () => new VmOperationDeadlineError({ operation: deadline.operation, mutating: false, waitedMs: answerWithinMs }),
    }),
  );
}

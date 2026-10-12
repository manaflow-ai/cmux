import * as Clock from "effect/Clock";
import * as Effect from "effect/Effect";
import * as FiberRef from "effect/FiberRef";
import { currentVmRequestContext } from "./requestContext";

/**
 * Inline answer deadlines for VM read routes.
 *
 * A provider read can hang for minutes, and an answer after the client gave
 * up reaches no one. A read route bounds its provider reads by its smallest
 * caller's timeout minus {@link VM_ROUTE_ANSWER_MARGIN_MS}, measured from the
 * request's start; a read past it is aborted (its requests' AbortSignal
 * fires) and the route answers 504 vm_provider_timeout.
 *
 * Only provider reads are bounded, inside the gateway (providerGateway.ts
 * `boundedProviderRead`). Database writes, resumes, cleanup drains and other
 * provider mutations in the same request run to completion: nothing is cut
 * midway, nothing is forked, nothing continues after the response, and no
 * route's maxDuration changes. (The forked, after()-based design of #19405
 * was reverted in #19467; mutations stay unbounded until a later stage.)
 */

/** Time left for the response to reach the client after the route answers. */
export const VM_ROUTE_ANSWER_MARGIN_MS = 5_000;

/**
 * The smallest timeout among each read route's Mac, CLI and iOS callers. A
 * URLRequest without a timeoutInterval gives up after 60 s without a byte.
 */
export const VM_READ_ROUTE_DEADLINES = {
  /** CloudReadRequestCoordinator 30 s budget. */
  stats: { clientTimeoutMs: 30_000 },
  /** VMClient.listSnapshots, 60 s URLRequest default. */
  snapshotList: { clientTimeoutMs: 60_000 },
  /** VMClient.status, 60 s URLRequest default. */
  getVm: { clientTimeoutMs: 60_000 },
  /** No native caller; the 60 s URLRequest default. */
  filesRead: { clientTimeoutMs: 60_000 },
} as const satisfies Record<string, { readonly clientTimeoutMs: number }>;

export type VmReadRouteOperation = keyof typeof VM_READ_ROUTE_DEADLINES;

export type VmReadDeadline = {
  readonly operation: VmReadRouteOperation;
  /** Overrides the request-context elapsed time (tests, non-route callers). */
  readonly elapsedMs?: number;
};

/**
 * The instant (Effect clock, ms) by which this request's provider reads must
 * have answered, or null outside a bounded read route.
 */
export const VmProviderReadDeadline: FiberRef.FiberRef<number | null> = FiberRef.unsafeMake<number | null>(null);

/**
 * What remains of a read route's budget after `elapsedMs` went to auth and
 * lookup: never past the client's limit less the margin, from the request's
 * start.
 */
export function vmReadAnswerBudgetMs(operation: VmReadRouteOperation, elapsedMs: number): number {
  const total = VM_READ_ROUTE_DEADLINES[operation].clientTimeoutMs - VM_ROUTE_ANSWER_MARGIN_MS;
  return Math.max(0, total - Math.max(0, elapsedMs));
}

/** Runs `program` with its provider reads bounded by the route's budget. */
export function withVmReadDeadline<A, E, R>(
  program: Effect.Effect<A, E, R>,
  deadline: VmReadDeadline,
): Effect.Effect<A, E, R> {
  const startedAtMs = currentVmRequestContext()?.startedAtMs;
  const elapsedMs = deadline.elapsedMs ?? (startedAtMs === undefined ? 0 : performance.now() - startedAtMs);
  const answerWithinMs = vmReadAnswerBudgetMs(deadline.operation, elapsedMs);
  return Effect.flatMap(Clock.currentTimeMillis, (nowMs) => Effect.locally(program, VmProviderReadDeadline, nowMs + answerWithinMs));
}

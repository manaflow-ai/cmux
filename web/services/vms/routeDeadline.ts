import { after } from "next/server";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Option from "effect/Option";
import { isProviderHangCause } from "./drivers/types";
import { VmOperationDeadlineError, type VmWorkflowError } from "./errors";
import { currentVmRequestContext } from "./requestContext";

/**
 * Route answer deadlines for VM routes that wait on a provider.
 *
 * Every VM route answers inside the budget of the client that calls it. A
 * provider call can hang for minutes (a Freestyle background request polled
 * for 2-4 minutes, then 502; production 2026-10-11 on exec, scp-endpoint and
 * pause), and an answer after the client gave up reaches no one. The budget
 * is the caller's timeout minus {@link VM_ROUTE_ANSWER_MARGIN_MS}, measured
 * from the request's start.
 *
 * Past the deadline the work is not interrupted: interrupting a pause, a
 * resume or a destroy midway would strand its bookkeeping. It keeps running
 * and the function stays alive for it through `after()` (up to the route's
 * maxDuration). A mutation answers `vm_operation_in_progress` so the caller
 * checks status before retrying: pause and resume reconcile with the
 * provider's observed status, destroy tolerates a machine already gone,
 * snapshot, resize and create-likes refuse a concurrent duplicate or reuse
 * the Idempotency-Key.
 */

/** Time left for the response to reach the client after the route answers. */
export const VM_ROUTE_ANSWER_MARGIN_MS = 5_000;

/** A route never gets less than this, even when auth and lookup spent the budget. */
export const VM_ROUTE_MIN_WINDOW_MS = 10_000;

/**
 * The client budget each provider-bound VM route answers inside: the
 * smallest timeout among its Mac (URLRequest, socket worker), CLI and iOS
 * callers, capped by the route's Vercel maxDuration (a function killed at
 * maxDuration answers a bare 504). A URLRequest without a timeoutInterval
 * gives up after 60 s without a byte. `mutating` operations may finish at
 * the provider after the route answered. Exec and scp-endpoint keep their own
 * workflow deadlines (execVm, prepareScpEndpoint) built on the same helper.
 */
export const VM_ROUTE_DEADLINES = {
  /** iOS CloudAPIRequestBuilder 20 s (CLI 180 s, Mac URL 16 min). */
  pause: { clientTimeoutMs: 20_000, mutating: true },
  /** CLI vm.resume 180 s (iOS 16 min). Resume takes ~107 s at the median. */
  resume: { clientTimeoutMs: 180_000, mutating: true },
  /** iOS 20 s; Mac VMClient.destroy 60 s URLRequest default. */
  destroy: { clientTimeoutMs: 20_000, mutating: true },
  /** Mac/CLI 16 min, capped by the route's maxDuration 600 s. */
  snapshot: { clientTimeoutMs: 600_000, mutating: true },
  /** Socket vm.snapshot_delete 120 s. */
  snapshotDelete: { clientTimeoutMs: 120_000, mutating: true },
  /** VMClient.listSnapshots 60 s URLRequest default. */
  snapshotList: { clientTimeoutMs: 60_000, mutating: false },
  /** Mac/CLI 16-32 min, capped by maxDuration 600 s; retries reuse the Idempotency-Key. */
  fork: { clientTimeoutMs: 600_000, mutating: true },
  /** Mac/CLI 16 min, capped by maxDuration 600 s; retries reuse the Idempotency-Key. */
  restore: { clientTimeoutMs: 600_000, mutating: true },
  /** CloudReadRequestCoordinator 30 s budget. */
  stats: { clientTimeoutMs: 30_000, mutating: false },
  /** VMClient.networkPolicy 30 s. */
  networkRead: { clientTimeoutMs: 30_000, mutating: false },
  /** VMClient.updateNetworkPolicy 60 s. */
  networkUpdate: { clientTimeoutMs: 60_000, mutating: true },
  /** No native caller; the 60 s URLRequest default. */
  filesRead: { clientTimeoutMs: 60_000, mutating: false },
  filesWrite: { clientTimeoutMs: 60_000, mutating: true },
  /** Mac VMClient.resize and CLI 120 s. */
  resize: { clientTimeoutMs: 120_000, mutating: true },
  /** CLI 90 s (Mac 120 s). */
  openPort: { clientTimeoutMs: 90_000, mutating: false },
} as const satisfies Record<string, { readonly clientTimeoutMs: number; readonly mutating: boolean }>;

export type VmRouteDeadlineOperation = keyof typeof VM_ROUTE_DEADLINES;

/** What remains of a client's budget after `elapsedMs` of it went to auth and lookup. */
export function vmRouteAnswerBudgetMs(clientTimeoutMs: number, elapsedMs: number): number {
  return Math.max(VM_ROUTE_MIN_WINDOW_MS, clientTimeoutMs - VM_ROUTE_ANSWER_MARGIN_MS - Math.max(0, elapsedMs));
}

/** Keeps the serverless function alive for work that outlived its response. */
export function continueAfterResponse(work: Promise<unknown>): void {
  const settled = () => work.then(() => undefined, () => undefined);
  try {
    after(settled);
  } catch {
    // Outside a request scope (tests, scripts) there is nothing to keep alive.
    void settled();
  }
}

export type VmAnswerDeadlineOptions<A, E, R> = {
  /** Milliseconds from now within which the caller must have an answer. */
  readonly answerWithinMs: number;
  /** The answer at the deadline: a value (exec's 124) or a failure. */
  readonly onDeadline: () => Effect.Effect<A, E, R>;
  /** Where unfinished work goes after the deadline; defaults to {@link continueAfterResponse}. */
  readonly continueInBackground?: (work: Promise<unknown>) => void;
};

/**
 * Run `program`, answering `onDeadline` if it has not finished within
 * `answerWithinMs`. The program runs on its own fiber and is never
 * interrupted by the deadline; unfinished work is handed to
 * `continueInBackground`. Times come from the Effect clock, so tests drive
 * the deadline with TestClock.
 */
export function withVmAnswerDeadline<A, E, R, A2 = A, E2 = E, R2 = never>(
  program: Effect.Effect<A, E, R>,
  options: VmAnswerDeadlineOptions<A2, E2, R2>,
): Effect.Effect<A | A2, E | E2, R | R2> {
  return Effect.gen(function* () {
    const fiber = yield* Effect.forkDaemon(program);
    const exit = yield* Fiber.await(fiber).pipe(
      Effect.timeoutTo({
        duration: Math.max(0, options.answerWithinMs),
        onSuccess: Option.some,
        onTimeout: Option.none,
      }),
    );
    if (Option.isSome(exit)) return yield* exit.value;
    (options.continueInBackground ?? continueAfterResponse)(Effect.runPromise(Fiber.await(fiber)));
    return yield* options.onDeadline();
  });
}

/** Whether a VM workflow failure is a provider call that was never answered. */
export function isVmProviderHang(error: VmWorkflowError): boolean {
  return error._tag === "VmProviderOperationError" && isProviderHangCause(error.cause);
}

export type VmRouteDeadline = {
  readonly operation: VmRouteDeadlineOperation;
  /** Overrides the request-context elapsed time (tests, non-route callers). */
  readonly elapsedMs?: number;
  readonly continueInBackground?: (work: Promise<unknown>) => void;
};

/**
 * The route-level deadline every provider-bound VM route applies through
 * `runVmRoute`. A mutation that hangs at the provider, or is still running at
 * the deadline, answers {@link VmOperationDeadlineError} with `mutating`; a
 * read past the deadline answers it without. An early provider refusal keeps
 * its own error.
 */
export function withVmRouteDeadline<A, R>(
  program: Effect.Effect<A, VmWorkflowError, R>,
  deadline: VmRouteDeadline,
): Effect.Effect<A, VmWorkflowError, R> {
  const { clientTimeoutMs, mutating } = VM_ROUTE_DEADLINES[deadline.operation];
  const startedAtMs = currentVmRequestContext()?.startedAtMs;
  const elapsedMs = deadline.elapsedMs ?? (startedAtMs === undefined ? 0 : performance.now() - startedAtMs);
  const answerWithinMs = vmRouteAnswerBudgetMs(clientTimeoutMs, elapsedMs);
  const deadlineError = (cause?: unknown) => new VmOperationDeadlineError({
    operation: deadline.operation, mutating, waitedMs: answerWithinMs, ...(cause === undefined ? {} : { cause }),
  });
  const bounded = mutating
    // A mutation whose provider call hung may still complete there: the
    // answer is "in progress", not an outage the caller would retry blindly.
    ? program.pipe(Effect.catchIf(isVmProviderHang, (error) => Effect.fail(deadlineError(error.cause))))
    : program;
  return withVmAnswerDeadline(bounded, {
    answerWithinMs,
    onDeadline: () => Effect.fail(deadlineError()),
    ...(deadline.continueInBackground ? { continueInBackground: deadline.continueInBackground } : {}),
  });
}

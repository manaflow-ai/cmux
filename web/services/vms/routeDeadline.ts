import { after } from "next/server";
import * as Cause from "effect/Cause";
import * as Clock from "effect/Clock";
import * as Effect from "effect/Effect";
import * as FiberRef from "effect/FiberRef";
import * as Fiber from "effect/Fiber";
import * as Option from "effect/Option";
import * as Runtime from "effect/Runtime";
import { hasProviderGuestUnresponsiveCause, isProviderHangCause } from "./drivers/types";
import { VmOperationDeadlineError, type VmWorkflowError } from "./errors";
import { VM_PROVIDER_CREATE_TIMEOUT_MS } from "./operationTimeouts";
import { scrubErrorForLog } from "../observability/report";
import { forceFlushTraces, withPrioritySpan, type MaybeAttributes } from "../telemetry";
import { currentVmRequestContext } from "./requestContext";

/**
 * Route answer deadlines for VM routes that wait on a provider.
 *
 * Every VM route answers inside the budget of the client that calls it. A
 * provider call can hang for minutes (a Freestyle background request polled
 * for 2-4 minutes, then 502; production 2026-10-11 on exec, scp-endpoint and
 * pause), and an answer after the client gave up reaches no one. A client
 * states its budget in {@link VM_CLIENT_TIMEOUT_HEADER}; without it the route
 * assumes its smallest known legacy caller. The route answers at that budget
 * minus {@link VM_ROUTE_ANSWER_MARGIN_MS}, measured from the request's start.
 *
 * Past the deadline the work is not interrupted: interrupting a pause, a
 * resume or a destroy midway would strand its bookkeeping. It keeps running
 * through `after()` until the route's maxDuration, then it is interrupted.
 * A mutation answers `vm_operation_in_progress` so the caller checks status
 * before retrying: pause reconciles on the provider's raw pause state, resume
 * waits out a start already under way, destroy tolerates a machine already gone,
 * snapshot and resize refuse a concurrent duplicate, and create-likes reuse
 * the Idempotency-Key. Restart remains unsupported until the provider has a
 * hard-reboot contract with completion and duplicate-request semantics.
 */

/** Time left for the response to reach the client after the route answers. */
export const VM_ROUTE_ANSWER_MARGIN_MS = 5_000;

/** A route never gets less than this (unless its whole budget is smaller), even when auth and lookup spent the budget. */
export const VM_ROUTE_MIN_WINDOW_MS = 10_000;

/** Request header in which a client states, in milliseconds, how long it waits for this response. */
export const VM_CLIENT_TIMEOUT_HEADER = "x-cmux-client-timeout-ms";

type VmRouteDeadlineEntry = {
  /** The smallest legacy caller's timeout, used when the client sends no budget header. */
  readonly clientTimeoutMs: number;
  /** The route's Vercel maxDuration, mirrored from its `export const maxDuration` literal. */
  readonly maxDurationMs: number;
  /** Whether the operation changes provider state and may finish after the route answered. */
  readonly mutating: boolean;
  /**
   * Time the work is guaranteed after the answer, before maxDuration. A
   * create answered "in progress" must reach its own outcome (running, or
   * failed with its credit refunded) in the background, so its answer comes
   * early enough to leave the create its whole provider deadline.
   */
  readonly reserveAfterAnswerMs?: number;
};

/**
 * What a create needs after its answer: the provider create's own deadline
 * (createVm bounds the call by it) plus the failure bookkeeping (credit
 * refund, row marked failed, model-plane revoke).
 */
export const VM_CREATE_RESERVE_AFTER_ANSWER_MS = VM_PROVIDER_CREATE_TIMEOUT_MS + 30_000;

/**
 * Per-route budgets. `clientTimeoutMs` is the smallest timeout among the
 * route's current Mac (URLRequest, socket worker), CLI and iOS callers; a
 * URLRequest without a timeoutInterval gives up after 60 s without a byte.
 * `maxDurationMs` must equal the route file's `maxDuration` (Next reads that
 * export statically, so it cannot import this table). Exec and scp-endpoint
 * keep their own workflow deadlines (execVm, prepareScpEndpoint) built on
 * {@link withVmAnswerDeadline}.
 */
export const VM_ROUTE_DEADLINES = {
  /** iOS CloudAPIRequestBuilder 20 s (CLI 180 s, Mac URL 16 min). */
  pause: { clientTimeoutMs: 20_000, maxDurationMs: 300_000, mutating: true },
  /** CLI vm.resume 180 s (iOS 16 min). Resume takes ~107 s at the median. */
  resume: { clientTimeoutMs: 180_000, maxDurationMs: 960_000, mutating: true },
  /** iOS 20 s; Mac VMClient.destroy 60 s URLRequest default. */
  destroy: { clientTimeoutMs: 20_000, maxDurationMs: 300_000, mutating: true },
  /** Mac/CLI 16 min, capped by maxDuration. */
  snapshot: { clientTimeoutMs: 960_000, maxDurationMs: 600_000, mutating: true },
  /** Socket vm.snapshot_delete 120 s. */
  snapshotDelete: { clientTimeoutMs: 120_000, maxDurationMs: 300_000, mutating: true },
  /** Mac/CLI 16-32 min, capped by maxDuration; retries reuse the Idempotency-Key. */
  fork: { clientTimeoutMs: 960_000, maxDurationMs: 600_000, mutating: true },
  /** Mac/CLI 16 min, capped by maxDuration; retries reuse the Idempotency-Key. */
  restore: { clientTimeoutMs: 960_000, maxDurationMs: 600_000, mutating: true },
  /** VMClient.updateNetworkPolicy 60 s. */
  networkUpdate: { clientTimeoutMs: 60_000, maxDurationMs: 300_000, mutating: true },
  /** Provider-level recovery for a frozen machine; it never waits on guest exec. */
  restart: { clientTimeoutMs: 60_000, maxDurationMs: 300_000, mutating: true },
  /** No native caller; the 60 s URLRequest default. */
  filesWrite: { clientTimeoutMs: 60_000, maxDurationMs: 300_000, mutating: true },
  /** Mac VMClient.resize and CLI 120 s. */
  resize: { clientTimeoutMs: 120_000, maxDurationMs: 300_000, mutating: true },
  /** CLI 90 s (Mac 120 s). Opening the desktop port may heal its unit. */
  openPort: { clientTimeoutMs: 90_000, maxDurationMs: 300_000, mutating: true },
  /** VMClient.rename, 60 s URLRequest default. */
  rename: { clientTimeoutMs: 60_000, maxDurationMs: 300_000, mutating: true },
  /**
   * Mac enrollment 60 s (iOS 20 s). Enrollment took up to 190 s in production,
   * so the Mac's 60 s is kept for builds that send no budget: a 15 s answer
   * would cut enrollments those builds complete today. Retries are refused
   * as busy while one runs and reuse the device's tunnel once it exists.
   */
  tunnelEnroll: { clientTimeoutMs: 60_000, maxDurationMs: 300_000, mutating: true },
  /**
   * iOS 20 s. The Mac's sign-out revoke gives up at 8 s and ignores the
   * answer; the revoke continues through after() either way.
   */
  tunnelRevoke: { clientTimeoutMs: 20_000, maxDurationMs: 300_000, mutating: true },
  /**
   * SSH attach 16 min (cmux-remote 20 s, iOS 90 s; both state their budget).
   * Attach may resume the machine (~107 s at the median), so builds that send
   * no budget keep the long wait. Attach is re-entrant: a retry mints a new
   * endpoint for the same machine.
   */
  attach: { clientTimeoutMs: 960_000, maxDurationMs: 960_000, mutating: true },
  /** Session attach 16 min, like attach. */
  sessionOpen: { clientTimeoutMs: 960_000, maxDurationMs: 960_000, mutating: true },
  /**
   * Mac/CLI/iOS 16 min. A create answers by maxDuration - margin - reserve
   * (25 s) and keeps running in the background for the reserve, so "in
   * progress" is true: it ends running or failed with its credit refunded
   * before the function stops. Creates finish in ~8 s at p99 (18 s max seen).
   * Retries reuse the Idempotency-Key.
   */
  create: { clientTimeoutMs: 960_000, maxDurationMs: 960_000, mutating: true, reserveAfterAnswerMs: VM_CREATE_RESERVE_AFTER_ANSWER_MS },
} as const satisfies Record<string, VmRouteDeadlineEntry>;

export type VmRouteDeadlineOperation = keyof typeof VM_ROUTE_DEADLINES;

/** The client's stated budget from {@link VM_CLIENT_TIMEOUT_HEADER}, when it is a positive integer. */
export function vmClientTimeoutMsFromRequest(request: Request | undefined): number | undefined {
  const raw = request?.headers.get(VM_CLIENT_TIMEOUT_HEADER)?.trim();
  if (!raw || !/^\d{1,9}$/.test(raw)) return undefined;
  const value = Number(raw);
  return value > 0 ? value : undefined;
}

/**
 * The route's total answer budget. A stated client budget is clamped to
 * [{@link VM_ROUTE_MIN_WINDOW_MS}, maxDuration - margin]; without one, the
 * smallest legacy caller's timeout less the margin, capped by maxDuration.
 */
export function vmRouteTotalBudgetMs(entry: VmRouteDeadlineEntry, statedClientTimeoutMs?: number): number {
  const ceiling = entry.maxDurationMs - VM_ROUTE_ANSWER_MARGIN_MS - (entry.reserveAfterAnswerMs ?? 0);
  if (statedClientTimeoutMs !== undefined) {
    return Math.min(ceiling, Math.max(VM_ROUTE_MIN_WINDOW_MS, statedClientTimeoutMs - VM_ROUTE_ANSWER_MARGIN_MS));
  }
  return Math.min(ceiling, entry.clientTimeoutMs - VM_ROUTE_ANSWER_MARGIN_MS);
}

/**
 * When a route answers and how long its work may continue afterwards. A route
 * with a reserve never takes the floor: its answer may come at once so the
 * reserve stays whole.
 */
export function vmRouteDeadlinePlan(
  operation: VmRouteDeadlineOperation,
  input: { readonly elapsedMs: number; readonly clientTimeoutMs?: number },
): { readonly answerWithinMs: number; readonly continueForMs: number } {
  const entry: VmRouteDeadlineEntry = VM_ROUTE_DEADLINES[operation];
  const elapsedMs = Math.max(0, input.elapsedMs);
  const totalBudgetMs = vmRouteTotalBudgetMs(entry, input.clientTimeoutMs);
  const answerWithinMs = entry.reserveAfterAnswerMs === undefined
    ? vmRouteAnswerBudgetMs(totalBudgetMs, elapsedMs)
    : Math.max(0, totalBudgetMs - elapsedMs);
  return {
    answerWithinMs,
    continueForMs: Math.max(0, entry.maxDurationMs - VM_ROUTE_ANSWER_MARGIN_MS - elapsedMs - answerWithinMs),
  };
}

/** What remains of a total budget after `elapsedMs` went to auth and lookup; never below the floor. */
export function vmRouteAnswerBudgetMs(totalBudgetMs: number, elapsedMs: number): number {
  const floor = Math.min(VM_ROUTE_MIN_WINDOW_MS, totalBudgetMs);
  return Math.max(floor, totalBudgetMs - Math.max(0, elapsedMs));
}

/**
 * Keeps the serverless function alive for work that outlived its response.
 * Outside a request scope `after()` throws; the work then continues detached
 * and the failure is logged with `label` (the route) so a lost continuation
 * is visible.
 */
export function continueAfterResponse(work: Promise<unknown>, label: string): void {
  const settled = () => work.then(() => undefined, () => undefined);
  try {
    after(settled);
  } catch (err) {
    console.error(`[vm-route-deadline] ${label}: after() unavailable, continuing detached`, err);
    void settled();
  }
}

/**
 * Keeps a continuation span's export alive past the response through after().
 * The promise never rejects; outside a request scope (tests, scripts) there is
 * no function to keep alive, so it simply runs detached.
 */
function flushAfterResponse(flush: Promise<void>): void {
  try {
    after(() => flush);
  } catch {
    void flush;
  }
}

/** Most continuations one function instance runs at once (see withVmAnswerDeadline). */
export const VM_MAX_BACKGROUND_CONTINUATIONS = 64;

/** Counts running continuations; a counter, never a gate requests wait on. */
export type BackgroundContinuations = {
  tryAcquire(key?: string): boolean;
  release(key?: string): void;
  hasKey(key: string): boolean;
  readonly running: number;
};

/** A fresh continuation counter with its own cap (tests get their own). */
export function createBackgroundContinuations(cap: number = VM_MAX_BACKGROUND_CONTINUATIONS): BackgroundContinuations {
  let running = 0;
  const keys = new Set<string>();
  return {
    tryAcquire(key?: string): boolean {
      if (running >= cap) return false;
      running += 1;
      if (key !== undefined) keys.add(key);
      return true;
    },
    release(key?: string): void {
      running = Math.max(0, running - 1);
      if (key !== undefined) keys.delete(key);
    },
    hasKey(key: string): boolean {
      return keys.has(key);
    },
    get running(): number {
      return running;
    },
  };
}

/** The continuations running in this process. */
export const backgroundContinuations: BackgroundContinuations = createBackgroundContinuations();

/** One structured line per continuation outcome: route, outcome, and its cause or limit. */
export function logContinuationResult(label: string, outcome: string, detail: Record<string, unknown> = {}): Promise<void> {
  const line = JSON.stringify({ route: label, outcome, ...detail });
  if (outcome === "completed" || outcome === "superseded") console.info("[vm-route-deadline] continuation", line);
  else console.error("[vm-route-deadline] continuation", line);
  return recordContinuationSpan(label, outcome, detail);
}

/**
 * The continuation's result as its own (priority-sampled) span, so outcomes
 * and stops at maxDuration are queryable: the route's request span has
 * already ended when a continuation finishes, and console lines are not
 * shipped to the trace store. The background path awaits the returned flush
 * inside after(), so a serverless freeze cannot drop the span; it never rejects.
 */
function recordContinuationSpan(label: string, outcome: string, detail: Record<string, unknown>): Promise<void> {
  const attributes: MaybeAttributes = {
    "cmux.vm.continuation.route": label,
    "cmux.vm.continuation.outcome": outcome,
  };
  for (const [key, value] of Object.entries(detail)) {
    if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
      attributes[`cmux.vm.continuation.${key}`] = value;
    }
  }
  return withPrioritySpan("cmux-vm", "cmux.vm.continuation", attributes, () => undefined)
    .then(async () => { await forceFlushTraces(); })
    .catch(() => undefined);
}

/** The failure's name and message, credential-scrubbed (no stacks, no provider bodies). */
function summarizeCause(cause: Cause.Cause<unknown>): string {
  const failure = Cause.squash(cause);
  return scrubErrorForLog(failure).slice(0, 300);
}

export type VmAnswerDeadlineOptions<A, E, R> = {
  /** Milliseconds from now within which the caller must have an answer. */
  readonly answerWithinMs: number;
  /** The answer at the deadline: a value (exec's 124) or a failure. */
  readonly onDeadline: () => Effect.Effect<A, E, R>;
  /**
   * How long unfinished work may continue after the deadline before it is
   * interrupted: the time left before the route's maxDuration, or 0 when
   * nothing needs to finish (exec answers 124 and records nothing later).
   */
  readonly continueForMs: number;
  /** Route name for logs. */
  readonly label: string;
  /**
   * One continuation per key at a time. A retry of a re-entrant operation
   * (attach, session open) on the same machine answers in progress at its
   * deadline and leaves the work to the continuation already running.
   */
  readonly continuationKey?: string;
  /** The continuation counter; defaults to the process's {@link backgroundContinuations}. */
  readonly continuations?: BackgroundContinuations;
  /** Where unfinished work goes after the deadline; defaults to {@link continueAfterResponse}. */
  readonly continueInBackground?: (work: Promise<unknown>, label: string) => void;
};

/**
 * Run `program`, answering `onDeadline` if it has not finished within
 * `answerWithinMs`. The deadline never interrupts the program: unfinished
 * work is handed to `continueInBackground` for at most `continueForMs`, then
 * interrupted. Times come from the Effect clock, so tests drive the deadline
 * with TestClock.
 */
export function withVmAnswerDeadline<A, E, R, A2 = A, E2 = E, R2 = never>(
  program: Effect.Effect<A, E, R>,
  options: VmAnswerDeadlineOptions<A2, E2, R2>,
): Effect.Effect<A | A2, E | E2, R | R2> {
  return Effect.gen(function* () {
    // Mutations are never on a read route's provider deadline (stage A).
    const fiber = yield* Effect.forkDaemon(Effect.locally(program, VmProviderReadDeadline, null));
    const exit = yield* Fiber.await(fiber).pipe(
      Effect.timeoutTo({
        duration: Math.max(0, options.answerWithinMs),
        onSuccess: Option.some,
        onTimeout: Option.none,
      }),
    );
    if (Option.isSome(exit)) return yield* exit.value;
    const log = continuationLogContext(options);
    const continuations = options.continuations ?? backgroundContinuations;
    if (options.continueForMs <= 0) {
      yield* Fiber.interruptFork(fiber);
      return yield* options.onDeadline();
    }
    if (options.continuationKey !== undefined && continuations.hasKey(options.continuationKey)) {
      // The same re-entrant operation on the same machine is already running
      // in the background: this retry adds no second continuation.
      flushAfterResponse(logContinuationResult(options.label, "superseded", log));
      yield* Fiber.interruptFork(fiber);
      return yield* options.onDeadline();
    }
    if (!continuations.tryAcquire(options.continuationKey)) {
      // Past the cap the request does not answer "in progress" for work it
      // would then have to stop: it waits for the work inline, up to the
      // time the work would have had in the background.
      const inline = yield* Fiber.await(fiber).pipe(Effect.timeout(options.continueForMs), Effect.option);
      if (Option.isNone(inline)) {
        flushAfterResponse(logContinuationResult(options.label, "inline_stopped_at_max_duration", { ...log, cap: VM_MAX_BACKGROUND_CONTINUATIONS }));
        yield* Fiber.interruptFork(fiber);
        return yield* options.onDeadline();
      }
      flushAfterResponse(logContinuationResult(options.label, inline.value._tag === "Success" ? "inline_completed" : "inline_failed", {
        ...log, cap: VM_MAX_BACKGROUND_CONTINUATIONS,
        ...(inline.value._tag === "Failure" ? { cause: summarizeCause(inline.value.cause) } : {}),
      }));
      return yield* inline.value;
    }
    // Each continuation owns only its own fiber: it holds no lock or permit a
    // foreground request waits on, it is never on a request's read deadline,
    // and it ends by the route's maxDuration. Its result is always logged.
    // It runs on the caller's runtime (clock and services).
    const key = options.continuationKey;
    const bounded = Fiber.await(fiber).pipe(
      Effect.timeout(options.continueForMs),
      Effect.matchCauseEffect({
        onSuccess: (finished) => Effect.promise(() => logContinuationResult(options.label, finished._tag === "Success" ? "completed" : "failed", {
          ...log,
          ...(finished._tag === "Failure" ? { cause: summarizeCause(finished.cause) } : {}),
        })),
        // Stop the work first, so nothing it does lands after the recorded stop.
        onFailure: () => Fiber.interruptFork(fiber).pipe(
          Effect.andThen(Effect.promise(() => logContinuationResult(options.label, "stopped_at_max_duration", { ...log, continueForMs: options.continueForMs }))),
        ),
      }),
      Effect.ensuring(Effect.sync(() => continuations.release(key))),
    );
    const runtime = yield* Effect.runtime<never>();
    (options.continueInBackground ?? continueAfterResponse)(Runtime.runPromise(runtime)(bounded), options.label);
    return yield* options.onDeadline();
  });
}

/** The identifiers a continuation's result log carries (never request bodies or provider text). */
function continuationLogContext(options: { readonly continuationKey?: string }): Record<string, unknown> {
  const context = currentVmRequestContext();
  return {
    ...(options.continuationKey !== undefined ? { key: options.continuationKey } : {}),
    ...(context?.vmId ? { vmId: context.vmId } : {}),
    ...(context?.operationId ? { operationId: context.operationId } : {}),
  };
}

/** Whether a VM workflow failure is a provider call that was never answered. */
export function isVmProviderHang(error: VmWorkflowError): boolean {
  return error._tag === "VmProviderOperationError" && isProviderHangCause(error.cause);
}

/**
 * A hung mutation that may still complete at the provider. A stuck guest
 * (#19307's vm_guest_unresponsive) is excluded: that answer preserves the
 * machine and gives support guidance instead of claiming an unverified
 * recovery operation.
 */
function isUnfinishedMutation(error: VmWorkflowError): boolean {
  return isVmProviderHang(error) && !(error._tag === "VmProviderOperationError" && hasProviderGuestUnresponsiveCause(error.cause));
}

export type VmRouteDeadline = {
  readonly operation: VmRouteDeadlineOperation;
  /** The client's stated budget ({@link vmClientTimeoutMsFromRequest}). */
  readonly clientTimeoutMs?: number;
  /** Overrides the request-context elapsed time (tests, non-route callers). */
  readonly elapsedMs?: number;
  /** See {@link VmAnswerDeadlineOptions.continuationKey}. */
  readonly continuationKey?: string;
  readonly continueInBackground?: (work: Promise<unknown>, label: string) => void;
};

/**
 * The route-level deadline every provider-bound VM route applies through
 * `runVmRoute`. A mutation that hangs at the provider, or is still running at
 * the deadline, answers {@link VmOperationDeadlineError} with `mutating`; a
 * read past the deadline answers it without. An early provider refusal and a
 * stuck guest keep their own errors.
 */
export function withVmRouteDeadline<A, R>(
  program: Effect.Effect<A, VmWorkflowError, R>,
  deadline: VmRouteDeadline,
): Effect.Effect<A, VmWorkflowError, R> {
  const entry: VmRouteDeadlineEntry = VM_ROUTE_DEADLINES[deadline.operation];
  const context = currentVmRequestContext();
  const elapsedMs = deadline.elapsedMs ?? (context === undefined ? 0 : performance.now() - context.startedAtMs);
  const { answerWithinMs, continueForMs } = vmRouteDeadlinePlan(deadline.operation, {
    elapsedMs,
    clientTimeoutMs: deadline.clientTimeoutMs,
  });
  const deadlineError = (cause?: unknown) => new VmOperationDeadlineError({
    operation: deadline.operation, mutating: entry.mutating, waitedMs: answerWithinMs, ...(cause === undefined ? {} : { cause }),
  });
  const bounded = entry.mutating
    // A mutation whose provider call hung may still complete there: the
    // answer is "in progress", not an outage the caller would retry blindly.
    ? program.pipe(Effect.catchIf(isUnfinishedMutation, (error) => Effect.fail(deadlineError(error.cause))))
    : program;
  return withVmAnswerDeadline(bounded, {
    answerWithinMs,
    onDeadline: () => Effect.fail(deadlineError()),
    continueForMs,
    label: context?.route ?? deadline.operation,
    ...(deadline.continuationKey ? { continuationKey: deadline.continuationKey } : {}),
    ...(deadline.continueInBackground ? { continueInBackground: deadline.continueInBackground } : {}),
  });
}

// ---- Reads (stage A, #19511): inline provider-read deadlines. ----

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

/**
 * A create's answer deadline, only with an Idempotency-Key. Without one a
 * retry cannot reach the same create, so it never answers "in progress"
 * without a machine id: it waits for the create inline.
 */
export function createRouteAnswerDeadline(idempotencyKey: string | null | undefined): { deadline?: VmRouteDeadline } {
  return idempotencyKey ? { deadline: { operation: "create" } } : {};
}

import type { Span } from "@opentelemetry/api";
import * as Effect from "effect/Effect";

export type VmTimingStage =
  | "auth"
  | "request_parse"
  | "entitlements"
  | "begin_create"
  | "begin_base_open"
  | "begin_base_reset"
  | "limit_reconcile"
  | "billing"
  | "provider_create"
  | "mark_running"
  | "mark_base_running"
  | "usage_events"
  | "total";

export type VmTimingSink = {
  readonly record: (stage: VmTimingStage, durationMs: number) => void;
};

export class VmTimingRecorder implements VmTimingSink {
  private readonly durations = new Map<VmTimingStage, number>();
  private readonly counts = new Map<VmTimingStage, number>();
  private readonly startedAt: number;
  private readonly debugTimings: boolean;
  private finished = false;

  constructor(
    private readonly span: Span,
    private readonly operation: string,
    options: { readonly startedAt?: number; readonly debugTimings?: boolean } = {},
  ) {
    this.startedAt = options.startedAt ?? performance.now();
    this.debugTimings = options.debugTimings ?? process.env.CMUX_VM_DEBUG_TIMINGS === "1";
  }

  record(stage: VmTimingStage, durationMs: number): void {
    const duration = roundedMs(durationMs);
    const total = roundedMs((this.durations.get(stage) ?? 0) + duration);
    const count = (this.counts.get(stage) ?? 0) + 1;
    this.durations.set(stage, total);
    this.counts.set(stage, count);
    this.span.setAttribute(`cmux.vm.timing.${stage}_ms`, total);
    this.span.setAttribute(`cmux.vm.timing.${stage}_count`, count);
  }

  finish(context: Record<string, unknown> = {}): void {
    if (this.finished) return;
    this.finished = true;
    this.record("total", performance.now() - this.startedAt);
    if (!this.debugTimings) return;
    console.info("cmux vm timings", JSON.stringify({
      operation: this.operation,
      ...context,
      timings: this.snapshot(),
    }));
  }

  snapshot(): Record<string, number> {
    return Object.fromEntries(
      [...this.durations.entries()].map(([stage, duration]) => [stage, duration]),
    );
  }
}

export function recordSpanTiming(span: Span, stage: VmTimingStage, durationMs: number): void {
  span.setAttribute(`cmux.vm.timing.${stage}_ms`, roundedMs(durationMs));
}

export function measureVmEffect<A, E, R>(
  timing: VmTimingSink | undefined,
  stage: VmTimingStage,
  effect: Effect.Effect<A, E, R>,
): Effect.Effect<A, E, R> {
  if (!timing) return effect;
  return Effect.suspend(() => {
    const start = performance.now();
    return effect.pipe(
      Effect.ensuring(
        Effect.sync(() => {
          timing.record(stage, performance.now() - start);
        }),
      ),
    );
  });
}

export async function measureVmAsync<T>(
  timing: VmTimingSink | undefined,
  stage: VmTimingStage,
  fn: () => Promise<T>,
): Promise<T> {
  if (!timing) return await fn();
  const start = performance.now();
  try {
    return await fn();
  } finally {
    timing.record(stage, performance.now() - start);
  }
}

export function measureVmSync<T>(
  timing: VmTimingSink | undefined,
  stage: VmTimingStage,
  fn: () => T,
): T {
  if (!timing) return fn();
  const start = performance.now();
  try {
    return fn();
  } finally {
    timing.record(stage, performance.now() - start);
  }
}

function roundedMs(durationMs: number): number {
  return Math.round(durationMs * 100) / 100;
}

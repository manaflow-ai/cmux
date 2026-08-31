/** A billing period is half-open: [start, end). */
export type BillingPeriod = {
  readonly start: Date;
  readonly end: Date;
};

export type VmStateTransitionEvent = {
  readonly id?: string | null;
  readonly vmId: string;
  readonly billingTeamId?: string | null;
  readonly fromState: string;
  readonly toState: string;
  /** Database rows use createdAt; callers may provide timestamp explicitly. */
  readonly createdAt?: Date | string | number;
  readonly timestamp?: Date | string | number;
};

/** Clips an open billing period to usage that has accrued at the given time. */
export function billingPeriodThrough(
  period: BillingPeriod,
  now: Date,
): BillingPeriod | null {
  const startMs = period.start.getTime();
  const endMs = period.end.getTime();
  const nowMs = now.getTime();
  if (
    !Number.isFinite(startMs) ||
    !Number.isFinite(endMs) ||
    !Number.isFinite(nowMs) ||
    endMs <= startMs ||
    nowMs <= startMs
  ) {
    return null;
  }
  return {
    start: period.start,
    end: new Date(Math.min(nowMs, endMs)),
  };
}

// "running" is the persisted VM state today. The additional names keep the
// ledger calculator compatible with provider terminology and future states.
export const ACTIVE_COMPUTE_STATES = [
  "active",
  "created",
  "running",
  "started",
] as const;

const activeComputeStates = new Set<string>(ACTIVE_COMPUTE_STATES);

export function isActiveComputeState(state: string): boolean {
  return activeComputeStates.has(state.trim().toLowerCase());
}

/**
 * Calculates VM-hours from immutable state transitions.
 *
 * Events before the period establish the state at period start. A VM that is
 * active at period end is charged through the end of the half-open period.
 * Invalid timestamps and events for an empty VM id are ignored so one bad
 * telemetry row cannot corrupt the whole billing read.
 */
export function calculateActiveComputeHours(
  events: readonly VmStateTransitionEvent[],
  period: BillingPeriod,
): number {
  const startMs = period.start.getTime();
  const endMs = period.end.getTime();
  if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs <= startMs) {
    throw new RangeError("Billing period end must be after its start");
  }

  const byVm = new Map<string, Array<VmStateTransitionEvent & { readonly timestampMs: number }>>();
  for (const event of events) {
    const vmId = typeof event.vmId === "string" ? event.vmId.trim() : "";
    if (!vmId) continue;
    const timestampMs = toTimestampMs(event.createdAt ?? event.timestamp);
    if (timestampMs === null) continue;
    const fromState = normalizeState(event.fromState);
    const toState = normalizeState(event.toState);
    const vmEvents = byVm.get(vmId) ?? [];
    vmEvents.push({ ...event, fromState, toState, timestampMs });
    byVm.set(vmId, vmEvents);
  }

  let activeMilliseconds = 0;
  for (const vmEvents of byVm.values()) {
    const orderedEvents = orderVmEvents(vmEvents);

    const firstEvent = orderedEvents[0];
    let state = firstEvent?.fromState ?? "";
    // A synthetic `created -> started` row marks the creation instant. Do not
    // charge the part of the period before that first row. For a first
    // `running -> paused` row, the missing prior history means the VM may have
    // been running at period start, so the conservative boundary is start.
    let activeSince: number | null = isActiveComputeState(state)
      ? state.trim().toLowerCase() === "created"
        ? Math.max(startMs, firstEvent?.timestampMs ?? startMs)
        : startMs
      : null;

    for (const event of orderedEvents) {
      const timestampMs = event.timestampMs;
      if (timestampMs < startMs) {
        state = event.toState;
        activeSince = isActiveComputeState(state) ? startMs : null;
        continue;
      }
      // A transition at period end closes the prior interval at exactly end;
      // a transition after end cannot affect this period.
      if (timestampMs >= endMs) break;

      // Prefer the event's recorded source state if a legacy row left a gap in
      // the stream. This keeps an incomplete ledger conservative and bounded.
      if (state !== event.fromState) {
        if (isActiveComputeState(event.fromState)) {
          activeSince ??= startMs;
        } else if (activeSince !== null) {
          activeMilliseconds += Math.max(0, timestampMs - activeSince);
          activeSince = null;
        }
        state = event.fromState;
      }

      if (isActiveComputeState(event.toState)) {
        activeSince ??= timestampMs;
      } else if (activeSince !== null) {
        activeMilliseconds += Math.max(0, timestampMs - activeSince);
        activeSince = null;
      }
      state = event.toState;
    }

    if (activeSince !== null) {
      activeMilliseconds += Math.max(0, endMs - activeSince);
    }
  }

  const hours = activeMilliseconds / 3_600_000;
  // Keep API and Stripe quantities stable across JavaScript floating point
  // noise while retaining sub-minute precision.
  return Math.round(hours * 1_000_000) / 1_000_000;
}

/**
 * UUIDs are not causal ordering keys. When two writes share a timestamp,
 * follow the state chain inside that timestamp before falling back to the
 * stable id order. This keeps a same-tick create/start sequence from ending
 * in the wrong state.
 */
function orderVmEvents(
  events: ReadonlyArray<VmStateTransitionEvent & { readonly timestampMs: number }>,
): Array<VmStateTransitionEvent & { readonly timestampMs: number }> {
  const sorted = [...events].sort((left, right) =>
    left.timestampMs - right.timestampMs || (left.id ?? "").localeCompare(right.id ?? ""));
  const ordered: Array<VmStateTransitionEvent & { readonly timestampMs: number }> = [];
  let previousState: string | undefined;

  for (let offset = 0; offset < sorted.length;) {
    const timestampMs = sorted[offset]!.timestampMs;
    const group: Array<VmStateTransitionEvent & { readonly timestampMs: number }> = [];
    while (offset < sorted.length && sorted[offset]!.timestampMs === timestampMs) {
      group.push(sorted[offset]!);
      offset += 1;
    }

    while (group.length > 0) {
      const linkedIndex = previousState === undefined
        ? group.findIndex((event) => !group.some((candidate) => candidate.toState === event.fromState))
        : group.findIndex((event) => event.fromState === previousState);
      const selectedIndex = linkedIndex >= 0 ? linkedIndex : 0;
      const [selected] = group.splice(selectedIndex, 1);
      if (!selected) continue;
      ordered.push(selected);
      previousState = selected.toState;
    }
  }

  return ordered;
}

/** Compatibility alias for callers that use the aggregation terminology. */
export const aggregateActiveComputeHours = calculateActiveComputeHours;

function toTimestampMs(value: Date | string | number | undefined): number | null {
  if (value === undefined) return null;
  let timestamp: number;
  if (value instanceof Date) {
    timestamp = value.getTime();
  } else if (typeof value === "number") {
    timestamp = new Date(Math.abs(value) < 100_000_000_000 ? value * 1_000 : value).getTime();
  } else {
    const text = value.trim();
    if (!text) return null;
    const numeric = Number(text);
    timestamp = Number.isFinite(numeric)
      ? new Date(Math.abs(numeric) < 100_000_000_000 ? numeric * 1_000 : numeric).getTime()
      : new Date(text).getTime();
  }
  return Number.isFinite(timestamp) ? timestamp : null;
}

function normalizeState(state: string): string {
  return state.trim().toLowerCase();
}

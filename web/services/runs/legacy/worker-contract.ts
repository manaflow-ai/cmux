export type RunAttemptStatus = "queued" | "running" | "succeeded" | "failed" | "cancelled";
export type RunAttemptTerminalStatus = "succeeded" | "failed" | "cancelled";

/** A lease is valid only while its fencing token and expiry both match. */
export function isRunAttemptLeaseActive(input: {
  readonly leaseId: string | null | undefined;
  readonly expectedLeaseId: string;
  readonly leaseUntil: Date | null | undefined;
  readonly now?: Date;
}): boolean {
  return input.leaseId === input.expectedLeaseId && Boolean(input.leaseUntil && input.leaseUntil.getTime() > (input.now ?? new Date()).getTime());
}

/** Shared state-machine guard used by providers before committing side effects. */
export function canApplyRunAttemptMutation(input: {
  readonly status: RunAttemptStatus;
  readonly leaseId: string | null | undefined;
  readonly expectedLeaseId: string;
  readonly leaseUntil: Date | null | undefined;
  readonly now?: Date;
}): boolean {
  return input.status === "running" && isRunAttemptLeaseActive(input);
}

export type RunAttemptTransitionDecision = "apply" | "replay" | "fenced";

/** Classifies a worker callback before it reaches the database fence. */
export function runAttemptTransitionDecision(input: {
  readonly currentStatus: RunAttemptStatus;
  readonly requestedStatus: RunAttemptTerminalStatus;
  readonly leaseId: string | null | undefined;
  readonly expectedLeaseId: string;
  readonly leaseUntil: Date | null | undefined;
  readonly now?: Date;
}): RunAttemptTransitionDecision {
  if (input.currentStatus === input.requestedStatus) return "replay";
  return canApplyRunAttemptMutation({ ...input, status: input.currentStatus }) ? "apply" : "fenced";
}

/** The VM control plane accepted the mutation but is still finishing it. */
export class RunCloudOperationPending extends Error {
  readonly code: "vm_create_in_progress";

  constructor() {
    super("Cloud VM create is still in progress");
    this.name = "RunCloudOperationPending";
    this.code = "vm_create_in_progress";
  }
}

/** Keep the worker contract independent of provider response details. */
export function isRunCloudOperationPending(payload: unknown): payload is { readonly error: "vm_create_in_progress" } {
  return !!payload && typeof payload === "object" && (payload as { error?: unknown }).error === "vm_create_in_progress";
}

/**
 * How long a Run attempt keeps retrying an in-progress Cloud VM create,
 * measured from the attempt's first claim. `/api/vm` runs for at most 960s
 * (its maxDuration), so a create still reported in progress after this died
 * with its background continuation and will never return an identity.
 */
export const RUN_CLOUD_CREATE_PENDING_LIMIT_MS = 20 * 60_000;

/** True once an in-progress create has outlived any live `/api/vm` request. */
export function runCloudCreatePendingExpired(input: { readonly startedAt: Date | null; readonly now?: Date }): boolean {
  if (!input.startedAt) return true;
  return (input.now ?? new Date()).getTime() - input.startedAt.getTime() >= RUN_CLOUD_CREATE_PENDING_LIMIT_MS;
}

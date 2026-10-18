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

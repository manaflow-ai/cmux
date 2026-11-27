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

/**
 * Parse a Cloud VM response body. A successful reply that isn't a JSON object
 * (empty, truncated, or an HTML error page behind a 2xx) is a failure: read as
 * `{}` it would carry no VM identity and the attempt would wait on it forever.
 * A DELETE may answer with no body. A failed reply keeps whatever JSON it has.
 */
export function parseRunCloudResponse(input: { readonly method: string; readonly ok: boolean; readonly status: number; readonly text: string }): Record<string, unknown> {
  let payload: unknown;
  try {
    payload = input.text ? JSON.parse(input.text) : undefined;
  } catch {
    payload = undefined;
  }
  if (payload && typeof payload === "object" && !Array.isArray(payload)) return payload as Record<string, unknown>;
  if (!input.ok || input.method === "DELETE") return {};
  throw new Error(`Cloud ${input.method} operation returned no JSON object (${input.status})`);
}

const SAFE_CLOUD_ERROR_CODE = /^[a-z][a-z0-9_]{0,47}$/;

/** A refused Cloud operation. Carries only the status and a short error code
 * (`vm_limit_exceeded`), never the response's message. */
export class RunCloudHttpError extends Error {
  readonly status: number;
  readonly code: string | undefined;

  constructor(method: string, status: number, payload: Record<string, unknown>) {
    super(`Cloud ${method} operation failed (${status})`);
    this.name = "RunCloudHttpError";
    this.status = status;
    const code = payload.error;
    this.code = typeof code === "string" && SAFE_CLOUD_ERROR_CODE.test(code) ? code : undefined;
  }
}

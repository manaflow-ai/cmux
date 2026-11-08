import { trace } from "@opentelemetry/api";

/**
 * How a request's identity was established.
 *
 * `access_token` and `snapshot` cost no call to Stack Auth; `stack` and
 * `cookie` each cost one `GET /users/me`. Recording this on the request span
 * the tracer already emits is what makes auth-provider load measurable without
 * adding a single extra event: the app-wide 2% head sample is far more than
 * enough resolution for a rate that runs at hundreds per second.
 */
export type AuthResolutionSource =
  | "access_token"
  | "snapshot"
  | "stack"
  | "cookie"
  | "unauthenticated";

export type AuthResolution = {
  readonly source: AuthResolutionSource;
  /** Whether this request called the auth provider's API. */
  readonly providerCalled: boolean;
  /** Age of the identity snapshot that answered, when one did. */
  readonly snapshotAgeMs?: number;
  /** Why local token verification did not answer, when it was tried and failed. */
  readonly localVerifyMiss?: "no_token" | "rejected" | "not_configured";
};

/**
 * Stamp the identity resolution onto the active span.
 *
 * No-ops when nothing is recording, so route code can call it unconditionally.
 */
export function recordAuthResolution(resolution: AuthResolution): void {
  const span = trace.getActiveSpan();
  if (!span) return;
  span.setAttribute("cmux.auth.source", resolution.source);
  span.setAttribute("cmux.auth.provider_called", resolution.providerCalled);
  if (resolution.snapshotAgeMs !== undefined) {
    span.setAttribute("cmux.auth.snapshot_age_ms", Math.max(0, Math.round(resolution.snapshotAgeMs)));
  }
  if (resolution.localVerifyMiss !== undefined) {
    span.setAttribute("cmux.auth.local_verify_miss", resolution.localVerifyMiss);
  }
}

/**
 * Record that a device registration changed nothing and was answered without
 * a write. Rides the request span, so measuring how much of the registry's
 * traffic is redundant costs no extra events.
 */
export function recordRegistrationNoOp(): void {
  const span = trace.getActiveSpan();
  span?.setAttribute("cmux.devices.registration_no_op", true);
}

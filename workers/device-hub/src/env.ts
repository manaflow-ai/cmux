export interface Env {
  USER_DO: DurableObjectNamespace;
  SESSION_DO: DurableObjectNamespace;
  /** Stack Auth projects accepted by /v1/auth/stack (comma list). */
  STACK_PROJECT_IDS?: string;
  /** Fallback single project when STACK_PROJECT_IDS is empty. */
  STACK_PROJECT_ID?: string;
  /** Override for tests and self-hosted Stack; default https://api.stack-auth.com. */
  STACK_API_URL?: string;
  /**
   * cmux web backend per Stack project, asked for the caller's plan before the
   * cmux relay is issued: comma list of `<stackProjectId>=<https origin>`.
   * A project without one never gets the cmux relay. src/billing.ts.
   */
  BILLING_ORIGINS?: string;
  /** Deadline (ms) for the billing lookup; default 5000. */
  BILLING_TIMEOUT_MS?: string;
  /** Public origin for signalURL; empty derives it from the request. */
  PUBLIC_BASE_URL?: string;
  /** Private P-256 JWK (JSON) for account session JWTs. */
  SESSION_KEY?: string;
  /** Private P-256 JWK (JSON) for session tickets. */
  TICKET_KEY?: string;
  TURN_KEY_ID?: string;
  /** Provisional window (ms) for socket-close end reasons; default 3000. */
  CLOSE_GRACE_MS?: string;
  TURN_KEY_API_TOKEN?: string;
}

export function csv(value: string | undefined): string[] {
  return (value ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

/** Internal headers set by the Worker for the User DO; stripped from client requests. */
export const USER_HEADER = "x-hub-user-id";
export const ORIGIN_HEADER = "x-hub-origin";
/** The caller's Stack access token, opened from the hub session for the billing lookup. */
export const STACK_TOKEN_HEADER = "x-hub-stack-token";
/** HKDF info for sealing the Stack token inside the hub session (`stk`). */
export const STACK_TOKEN_SEAL_INFO = "device-hub stack token v1";

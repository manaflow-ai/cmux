export interface Env {
  USER_DO: DurableObjectNamespace;
  SESSION_DO: DurableObjectNamespace;
  /** Stack Auth projects accepted by /v1/auth/stack (comma list). */
  STACK_PROJECT_IDS?: string;
  /** Fallback single project when STACK_PROJECT_IDS is empty. */
  STACK_PROJECT_ID?: string;
  /** Override for tests and self-hosted Stack; default https://api.stack-auth.com. */
  STACK_API_URL?: string;
  /** Comma list of paid user ids (v1 plan gating). */
  PAID_USER_IDS?: string;
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

export function planFor(env: Env, userId: string): "free" | "paid" {
  return csv(env.PAID_USER_IDS).includes(userId) ? "paid" : "free";
}

/** Internal headers set by the Worker for the User DO; stripped from client requests. */
export const USER_HEADER = "x-hub-user-id";
export const ORIGIN_HEADER = "x-hub-origin";

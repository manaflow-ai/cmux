// `cmux_account_signed_up`: one server event per Stack account, emitted when
// Stack's `user.created` webhook is accepted. The webhook is the one place
// every account creation passes through (web sign-up, native sign-in that
// creates the account, anonymous checkout users, server-created probe
// accounts), and the natural insert id keeps a Svix redelivery from counting
// twice.
//
// Stack does not record which cmux client started the sign-up, so
// `signup_client` names only what the server can prove: a probe account
// (`server`), an anonymous account (`anonymous`), else `unknown`. Join the
// person's first client event (`ios_sign_in_completed`, the macOS sign-in
// events) for the app.
import {
  captureServerEvent,
  type ServerEventDependencies,
  type ServerEventInput,
} from "./serverEvents";
import { isSyntheticAccountEmail } from "./syntheticAccounts";

export const ACCOUNT_SIGNED_UP_EVENT = "cmux_account_signed_up";

export type SignupSource =
  | "anonymous"
  | `oauth_${string}`
  | "passkey"
  | "password"
  | "email_code"
  | "unknown";

/** Map a validated `user.created` payload to the sign-up event, or null without a user id. */
export function accountSignedUpEvent(data: unknown, now: Date = new Date()): ServerEventInput | null {
  const user = record(data);
  const userId = typeof user?.id === "string" ? user.id : null;
  if (!user || !userId) return null;
  const synthetic = isSyntheticAccountEmail(stringValue(user.primary_email));
  const anonymous = user.is_anonymous === true;
  const signedUpAtMs = typeof user.signed_up_at_millis === "number" && Number.isFinite(user.signed_up_at_millis)
    ? user.signed_up_at_millis
    : null;
  const signedUpAt = signedUpAtMs === null ? now : new Date(signedUpAtMs);
  return {
    event: ACCOUNT_SIGNED_UP_EVENT,
    distinctId: userId,
    properties: {
      signup_source: signupSource(user),
      signup_client: synthetic ? "server" : anonymous ? "anonymous" : "unknown",
      is_anonymous: anonymous,
      is_synthetic: synthetic ? true : undefined,
      schema_version: 1,
    },
    setOnce: { cmux_signed_up_at: signedUpAt.toISOString() },
    insertId: `${ACCOUNT_SIGNED_UP_EVENT}:${userId}`,
    timestamp: signedUpAt,
  };
}

/** Best effort; never throws into the webhook. */
export function captureAccountSignedUp(
  data: unknown,
  dependencies: Partial<ServerEventDependencies> = {},
): void {
  try {
    const event = accountSignedUpEvent(data, dependencies.now?.() ?? new Date());
    if (event) void captureServerEvent(event, dependencies);
  } catch (error) {
    console.warn("[analytics] account sign-up capture failed", {
      error: error instanceof Error ? error.message.slice(0, 200) : String(error).slice(0, 200),
    });
  }
}

/** How the account first authenticated, from the Stack user's enabled methods. */
function signupSource(user: Record<string, unknown>): SignupSource {
  if (user.is_anonymous === true) return "anonymous";
  const provider = Array.isArray(user.oauth_providers)
    ? stringValue(record(user.oauth_providers[0])?.id)
    : null;
  if (provider && /^[a-z0-9_-]{1,32}$/i.test(provider)) return `oauth_${provider.toLowerCase()}`;
  if (user.passkey_auth_enabled === true) return "passkey";
  if (user.has_password === true) return "password";
  if (user.otp_auth_enabled === true) return "email_code";
  return "unknown";
}

function record(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function stringValue(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

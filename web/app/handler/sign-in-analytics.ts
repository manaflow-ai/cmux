import { POSTHOG_PUBLIC_API_HOST, POSTHOG_PUBLIC_PROJECT_KEY } from "../lib/posthog-public-config";
import type { SignInEntry } from "./sign-in-entry";

/**
 * Hosted sign-in page steps for one native app sign-in attempt.
 *
 * Off unless the app opted in for this attempt: the Mac app adds
 * `cmux_analytics=1` and its random `cmux_attempt` id to the sign-in URL only
 * while its product analytics is on for that launch (Settings opt-in and the
 * managed `DisableTelemetry` policy). The page never decides consent itself.
 *
 * Events are manual and allowlisted: no posthog-js, no autocapture, no
 * cookies, no person profile, no GeoIP, and no URL, referrer, query, code,
 * token, email or error text. Each carries only the attempt id and bounded
 * values.
 */

export const HOSTED_ANALYTICS_PARAM = "cmux_analytics";
export const HOSTED_ATTEMPT_PARAM = "cmux_attempt";

const ATTEMPT_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

type Params = { get(name: string): string | null };

/** The app's attempt id when the app opted this sign-in in, else null. */
export function hostedSignInAttempt(params: Params): string | null {
  if (params.get(HOSTED_ANALYTICS_PARAM) !== "1") return null;
  const attempt = params.get(HOSTED_ATTEMPT_PARAM);
  return attempt !== null && ATTEMPT_ID.test(attempt) ? attempt : null;
}

/** Copies a valid opt-in and attempt id to `target`; nothing else, and nothing when absent or malformed. */
export function forwardHostedSignInAnalytics(from: Params, target: URL) {
  const attempt = hostedSignInAttempt(from);
  if (!attempt) return;
  target.searchParams.set(HOSTED_ANALYTICS_PARAM, "1");
  target.searchParams.set(HOSTED_ATTEMPT_PARAM, attempt);
}

const OAUTH_METHODS = ["google", "github", "apple", "microsoft", "gitlab", "discord"] as const;

export type HostedSignInMethod =
  | (typeof OAUTH_METHODS)[number]
  | "other_oauth"
  | "passkey"
  | "email_code"
  | "password"
  | "password_sign_up";

/** A bounded method name for an OAuth provider id; unknown ids are `other_oauth`. */
export function oauthMethod(provider: string): HostedSignInMethod {
  return (OAUTH_METHODS as readonly string[]).includes(provider) ? (provider as HostedSignInMethod) : "other_oauth";
}

export type HostedSignInStep =
  | {
      event: "cmux_sign_in_page_shown";
      page: "sign-in" | "sign-up";
      entry: SignInEntry;
      returningFromProvider: boolean;
    }
  /** The first pointer or key press on the page load; no target, no value. */
  | { event: "cmux_sign_in_page_interacted" }
  /** An account chooser action: continue as the signed-in account, a remembered account, another account, or forgetting one. */
  | { event: "cmux_sign_in_account_chosen"; choice: "current" | "remembered" | "another" | "forget" }
  | { event: "cmux_sign_in_method_selected"; method: HostedSignInMethod }
  /** `start`: the method could not begin (provider redirect, code email). `verify`: its credential was refused. */
  | { event: "cmux_sign_in_method_failed"; method: HostedSignInMethod; stage: "start" | "verify" };

function stepProperties(step: HostedSignInStep): Record<string, string | boolean> {
  switch (step.event) {
    case "cmux_sign_in_page_shown":
      return {
        page: step.page.replace("-", "_"),
        entry: step.entry.replace("-", "_"),
        returning_from_provider: step.returningFromProvider,
      };
    case "cmux_sign_in_page_interacted":
      return {};
    case "cmux_sign_in_account_chosen":
      return { choice: step.choice };
    case "cmux_sign_in_method_selected":
      return { method: step.method };
    case "cmux_sign_in_method_failed":
      return { method: step.method, stage: step.stage };
  }
}

/** The capture body for one step. Exported for tests. */
export function hostedSignInCapture(attempt: string, step: HostedSignInStep, now: Date) {
  return {
    api_key: POSTHOG_PUBLIC_PROJECT_KEY,
    event: step.event,
    timestamp: now.toISOString(),
    properties: {
      distinct_id: attempt,
      attempt_id: attempt,
      source: "hosted_sign_in",
      ...stepProperties(step),
      $process_person_profile: false,
      $geoip_disable: true,
      $lib: "cmux-hosted-sign-in",
    },
  };
}

/** Sends one step when the attempt opted in. Best effort; never throws. */
export function reportHostedSignInStep(attempt: string | null, step: HostedSignInStep) {
  if (!attempt) return;
  void fetch(`${POSTHOG_PUBLIC_API_HOST}/e/`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(hostedSignInCapture(attempt, step, new Date())),
    keepalive: true,
    credentials: "omit",
    referrerPolicy: "no-referrer",
  }).catch(() => {});
}

export type HostedSignInPageShown = Extract<HostedSignInStep, { event: "cmux_sign_in_page_shown" }>;

/** Attempts whose page load was already reported (Strict Mode runs effects twice). */
const startedPages = new Set<string>();

/**
 * Reports `cmux_sign_in_page_shown` once per page load for `attempt`, then
 * `cmux_sign_in_page_interacted` on the first pointer or key press on
 * `target` (the document), once. It tells "the person did something" apart
 * from "nothing measured happened", without saying what or where.
 */
export function startHostedSignInPage(attempt: string | null, step: HostedSignInPageShown, target: EventTarget) {
  if (!attempt || startedPages.has(attempt)) return;
  startedPages.add(attempt);
  reportHostedSignInStep(attempt, step);
  const controller = new AbortController();
  const interacted = () => {
    controller.abort();
    reportHostedSignInStep(attempt, { event: "cmux_sign_in_page_interacted" });
  };
  for (const type of ["pointerdown", "keydown"]) {
    target.addEventListener(type, interacted, { capture: true, passive: true, signal: controller.signal });
  }
}

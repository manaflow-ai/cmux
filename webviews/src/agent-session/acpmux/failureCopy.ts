import type { Translate } from "./i18n";

/// Why a turn failed, as the user can act on it (ROUTES R0, cx-w10a). Errors from harnesses are user-facing
/// text, but a 401 from a proxy, a bad API key, a rate limit that mentions authentication and the CLI's own
/// expired login are different problems with different ways out; only `subscription-login` asks to sign in.
export type FailureKind =
  | "trust-pending"
  | "trust-untrusted"
  | "rate-limited"
  | "unreachable"
  | "invalid-key"
  | "subscription-login"
  | "proxy-auth"
  | "auth"
  | "other";

/// Who served the turn, for the copy: the harness profile's display name and id (`claude`, `claude-sr`, ...).
export type FailureRoute = { name?: string; harness?: string };

const RATE =
  /\b(?:429|529)\b|rate.?limit|too many requests|overloaded|at capacity|no non-exhausted|usage limit|quota|\b503\b|service unavailable/i;
const UNREACHABLE =
  /ECONNREFUSED|ENOTFOUND|ETIMEDOUT|EAI_AGAIN|ECONNRESET|EHOSTUNREACH|fetch failed|socket hang up|connection (?:refused|reset|closed|error)|could not (?:connect|resolve)|network (?:error|is unreachable)|\bunreachable\b|timed out/i;
const INVALID_KEY =
  /invalid[ _-]?(?:x-)?api[ _-]?key|incorrect api key|api key (?:is )?(?:missing|not set|not found|invalid)|no api key|(?:ANTHROPIC|OPENAI)_API_KEY/i;
const SUBSCRIPTION =
  /not logged in|login required|please (?:run )?\/login|(?:claude|codex) (?:auth )?login|oauth token (?:has )?expired|session (?:has )?expired|refresh token|invalid_grant|sign(?:ed)? ?in again/i;
const AUTH = /\b40[13]\b|unauthori[sz]ed|forbidden|authenticat|\boauth\b/i;
const URL_HOST = /https?:\/\/([^\s/'")\]]+)/i;
const STATUS = /\b([45]\d\d)\b/;
/// Harness profiles that reach their provider through a proxy acpmux knows by name.
const PROXY_PROFILES: Record<string, string> = { "claude-sr": "subrouter", "claude-cr": "CodeRouter" };
const PROVIDER_HOSTS = /(?:^|\.)(?:anthropic\.com|openai\.com|chatgpt\.com|claude\.ai)(?::\d+)?$/i;

/// True for any failure the old copy treated as "sign-in expired" (kept for callers that only need the flag).
export function isAuthenticationFailure(message: string | undefined): boolean {
  const kind = failureKind(message);
  return kind === "subscription-login" || kind === "auth";
}

/// The proxy or endpoint a failure names: a host in the message that is not the provider's, else the
/// profile's known proxy. Undefined for a direct route.
export function failureVia(message: string | undefined, route?: FailureRoute): string | undefined {
  const host = message ? URL_HOST.exec(message)?.[1] : undefined;
  if (host && !PROVIDER_HOSTS.test(host)) return host;
  return route?.harness ? PROXY_PROFILES[route.harness] : undefined;
}

export function failureKind(message: string | undefined, route?: FailureRoute): FailureKind {
  if (!message) return "other";
  if (/\btrust\.pending\b/i.test(message)) return "trust-pending";
  if (/\btrust\.untrusted\b/i.test(message)) return "trust-untrusted";
  // Capacity and network first: their messages often mention authentication or keys in passing.
  if (RATE.test(message)) return "rate-limited";
  if (UNREACHABLE.test(message)) return "unreachable";
  if (INVALID_KEY.test(message)) return "invalid-key";
  const via = failureVia(message, route);
  if (AUTH.test(message) && via) return "proxy-auth";
  if (SUBSCRIPTION.test(message)) return "subscription-login";
  if (AUTH.test(message)) return "auth";
  return "other";
}

/// The footer's sentence for a failed turn: the cause in plain words with the route and status when known.
/// The agent's raw message stays available as the detail; `other` shows it as the sentence.
export function failureCopy(t: Translate, message: string | undefined, route?: FailureRoute): string {
  if (!message) return t("turn.failed");
  const kind = failureKind(message, route);
  const harness = route?.name || route?.harness || t("turn.failure.theAgent");
  const via = failureVia(message, route);
  const status = STATUS.exec(message)?.[1];
  switch (kind) {
    case "trust-pending":
      return t("trust.answerFirst");
    case "trust-untrusted":
      return t("trust.untrustedNoPrompts");
    case "rate-limited":
      return t("turn.failure.rateLimited", { harness });
    case "unreachable":
      return via ? t("turn.failure.unreachableVia", { harness, via }) : t("turn.failure.unreachable", { harness });
    case "invalid-key":
      return t("turn.failure.invalidKey", { harness });
    case "proxy-auth":
      return t("turn.failure.proxyAuth", { harness, via: via ?? "", status: status ?? "401" });
    case "subscription-login":
      return t("turn.failure.signedOut", { harness });
    case "auth":
      return t("turn.failure.auth", { harness, status: status ?? "401" });
    default:
      return message;
  }
}

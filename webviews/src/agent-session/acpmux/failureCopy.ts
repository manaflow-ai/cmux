import type { Translate } from "./i18n";

/// Why a turn failed, as the user can act on it (ROUTES R0, cx-w10a). Errors from harnesses are user-facing
/// text, but a 401 from a proxy, a bad API key, a rate limit that mentions authentication and the CLI's own
/// expired login are different problems with different ways out; only `subscription-login` asks to sign in.
export type FailureKind =
  | "trust-pending"
  | "trust-untrusted"
  | "no-team-account"
  | "rate-limited"
  | "unreachable"
  | "invalid-key"
  | "subscription-login"
  | "proxy-auth"
  | "auth"
  | "disk-full"
  | "tailscale"
  | "agent-exited"
  | "spawn-failed"
  | "other";

/// Who served the turn, for the copy: the harness profile's display name and id (`claude`, `claude-sr`, ...).
export type FailureRoute = { name?: string; harness?: string };

/// CodeRouter's refusal on a team Cloud machine whose team has no account for the agent: a 403
/// `no_account_configured` (web/services/coderouter/noAccountMessage.ts). Codex shows only the body's
/// `error.message`, so its fixed opening is the signal; the second form is the server's text before
/// it said so. A team machine refuses own sign-ins, so neither waiting nor signing in helps: the
/// way out is an account added for the team, with the `cr add <agent>` the refusal names.
const NO_TEAM_ACCOUNT = /needs a team account on this machine|account is shared with this Cloud machine's team/i;
const ADD_COMMAND = /\bcr add (?:codex|claude|opencode)\b/;
const RATE =
  /\b(?:429|529)\b|rate.?limit|too many requests|overloaded|at capacity|no non-exhausted|usage limit|quota|\b503\b|service unavailable/i;
const UNREACHABLE =
  /ECONNREFUSED|ENOTFOUND|ETIMEDOUT|EAI_AGAIN|ECONNRESET|EHOSTUNREACH|fetch failed|socket hang up|connection (?:refused|reset|closed|error)|could not (?:connect|resolve)|network (?:error|is unreachable)|\bunreachable\b|timed out/i;
const INVALID_KEY =
  /invalid[ _-]?(?:x-)?api[ _-]?key|incorrect api key|api key (?:is )?(?:missing|not set|not found|invalid)|no api key|(?:ANTHROPIC|OPENAI)_API_KEY/i;
const SUBSCRIPTION =
  /not logged in|login required|please (?:run )?\/login|(?:claude|codex) (?:auth )?login|oauth token (?:has )?expired|session (?:has )?expired|refresh token|invalid_grant|sign(?:ed)? ?in again/i;
const AUTH = /\b40[13]\b|unauthori[sz]ed|forbidden|authenticat|\boauth\b/i;
/// A full disk, here or on the chat's machine: before every other kind, since what it broke (a
/// write, a socket, the agent) reads as that kind too.
const DISK_FULL = /ENOSPC|no space left on device|disk (?:is )?full|out of disk space|disk quota exceeded|EDQUOT/i;
/// A chat on another machine that its tailnet no longer reaches: the tailnet named, and a sign that
/// it did not connect. A tailnet host that answered (a 401, a 529) is that answer, not Tailscale,
/// even when its body says "logged out" (`ANSWERED`).
const TAILSCALE = /tailscale|tailnet|\.ts\.net\b/i;
/// URLs and tailnet host names, with their paths and ports: their words are not a host's answer. They
/// end at a quote, bracket or comma, so a serialized error's next field (`"status":401`) stays.
const ADDRESSES = /https?:\/\/[^\s"'<>()[\]{},]+|[^\s"'<>()[\]{},:/]+\.ts\.net[^\s"'<>()[\]{},]*/gi;
/// An HTTP refusal: a status or its reason phrase. Not "oauth" or "authentication", which name what
/// was being attempted ("OAuth token refresh failed: … i/o timeout") rather than a reply.
const ANSWERED = /\b40[13]\b|unauthori[sz]ed|forbidden/i;
/// The connection itself failed, so no host answered whatever the rest of the message says.
const DIAL_FAILED = /dial tcp|i\/o timeout|no route to host|connection refused|ECONNREFUSED|EHOSTUNREACH|ETIMEDOUT/i;
const TAILNET_DOWN = /not connected|logged out|needs login|is (?:down|stopped|offline)|no route/i;
/// The agent's process ended mid-turn (acpmux's "agent process closed", a signal, a broken pipe).
const AGENT_EXITED =
  /agent process (?:closed|exited|died|ended)|(?:agent|process) exited (?:unexpectedly|with)|exited with (?:code|status|signal)|terminated by signal|\bSIG(?:KILL|TERM|SEGV|ABRT|BUS)\b|broken pipe|\bEPIPE\b/i;
/// The agent never started (its command missing, a spawn refused). The same words can be a tool's
/// in the agent's stderr ("pnpm: command not found"), so they count only when nothing says the
/// agent ran and quit; acpmux's typed `spawn.failed` names a start that failed either way.
const SPAWN_FAILED =
  /failed to (?:spawn|start|launch)|could not (?:spawn|start|launch)|\bspawn\b.*\bENOENT\b|command not found/i;
/// acpmux's typed reasons (`errorCode`), by the words in them: the kind its text would give, when
/// the text says less.
const TYPED: readonly [RegExp, FailureKind][] = [
  [/disk|no[_.-]?space|enospc/i, "disk-full"],
  [/tailscale|tailnet/i, "tailscale"],
  [/peer|unreachable|connect|network/i, "unreachable"],
  [/spawn|start/i, "spawn-failed"],
  [/exit|closed|crash|died/i, "agent-exited"],
  [/rate|quota|capacity/i, "rate-limited"],
];
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

/// `code`: acpmux's typed reason for the failure (the turn's `errorCode`), when it gives one.
export function failureKind(message: string | undefined, route?: FailureRoute, code?: string): FailureKind {
  const typed = code ? TYPED.find(([words]) => words.test(code))?.[1] : undefined;
  if (typed) return typed;
  if (!message) return "other";
  if (/\btrust\.pending\b/i.test(message)) return "trust-pending";
  if (/\btrust\.untrusted\b/i.test(message)) return "trust-untrusted";
  // Before capacity and sign-in: neither waiting, another model nor a sign-in fixes it.
  if (NO_TEAM_ACCOUNT.test(message) && ADD_COMMAND.test(message)) return "no-team-account";
  if (DISK_FULL.test(message)) return "disk-full";
  // Capacity and network first: their messages often mention authentication or keys in passing.
  if (RATE.test(message)) return "rate-limited";
  // Connection words count only outside addresses: a URL's path or query (`…/oauth/token`,
  // `?error=ETIMEDOUT`) names what was asked, not what happened.
  const words = message.replace(ADDRESSES, " ");
  // An HTTP refusal came from a host that answered: the tailnet reached it. A failed dial outranks it.
  const dialFailed = DIAL_FAILED.test(words);
  const answered = !dialFailed && ANSWERED.test(words);
  if (TAILSCALE.test(message) && !answered && (dialFailed || UNREACHABLE.test(words) || TAILNET_DOWN.test(words)))
    return "tailscale";
  if (UNREACHABLE.test(words)) return "unreachable";
  const via = failureVia(message, route);
  // A signed-out Claude CLI says "Invalid API key · Please run /login": its way out is the login.
  if (INVALID_KEY.test(message) && !(SUBSCRIPTION.test(message) && !via)) return "invalid-key";
  if (AUTH.test(message) && via) return "proxy-auth";
  if (SUBSCRIPTION.test(message)) return "subscription-login";
  if (AUTH.test(message)) return "auth";
  // Last: the cause an agent's stderr names (above) says more than that it quit, and that it quit
  // says more than a start failure's words, which may be a tool's.
  if (AGENT_EXITED.test(message)) return "agent-exited";
  if (SPAWN_FAILED.test(message)) return "spawn-failed";
  return "other";
}

/// The way out a failure's card offers first: send the prompt again, or move to another model (with
/// Retry after it). Signing in is the footer's (TurnRows.tsx); a trust answer is its card's.
/// Whether a failed turn offers cmux's own route, CodeRouter, beside Switch model (Lawrence
/// 2026-10-23: "good opportunity for upsell here"): a key, sign-in or capacity failure that another
/// route fixes. Never on a chat CodeRouter already serves (sending it there again does nothing), and
/// never on a team machine's missing account, which CodeRouter itself refused.
export function offersOwnRoute(kind: FailureKind, route?: FailureRoute): boolean {
  if (route?.harness === "claude-cr") return false;
  return kind === "invalid-key" || kind === "subscription-login" || kind === "auth" || kind === "rate-limited";
}

export function failureRecovery(kind: FailureKind): "retry" | "switch-model" | undefined {
  switch (kind) {
    case "rate-limited":
    case "invalid-key":
    case "proxy-auth":
      return "switch-model";
    case "trust-pending":
    case "trust-untrusted":
    case "no-team-account":
    case "subscription-login":
    case "auth":
      return undefined;
    default:
      return "retry";
  }
}

/// The footer's sentence for a failed turn: the cause in plain words with the route and status when known.
/// The agent's raw message stays available as the detail, never as the sentence ("we need to have
/// prettier errors", Leo 2026-10-22): an unknown failure still reads human.
export function failureCopy(t: Translate, message: string | undefined, route?: FailureRoute, code?: string): string {
  const kind = failureKind(message, route, code);
  if (!message && kind === "other") return t("turn.failed");
  const harness = route?.name || route?.harness || t("turn.failure.theAgent");
  const via = failureVia(message, route);
  const status = message ? STATUS.exec(message)?.[1] : undefined;
  switch (kind) {
    case "trust-pending":
      return t("trust.answerFirst");
    case "trust-untrusted":
      return t("trust.notTrustedNoPrompts");
    case "no-team-account":
      return t("turn.failure.noTeamAccount", { harness, command: (message && ADD_COMMAND.exec(message)?.[0]) ?? "" });
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
    case "disk-full":
      return t("turn.failure.diskFull", { harness });
    case "tailscale":
      return t("turn.failure.tailscale", { harness });
    case "agent-exited":
      return t("turn.failure.agentExited", { harness });
    case "spawn-failed":
      return t("turn.failure.spawnFailed", { harness });
    default:
      return t("turn.failure.generic", { harness });
  }
}

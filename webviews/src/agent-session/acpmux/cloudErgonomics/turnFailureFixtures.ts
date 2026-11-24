// The failed-turn fixtures and coverage notes for the Cloud ergonomics measurement (states.tsx), kept out of
// the .tsx so a save there Fast Refreshes instead of reloading the page.
import type { FailureKind, FailureRoute } from "../failureCopy";

const CLOUD_ROUTE: FailureRoute = { harness: "claude", name: "Claude Code", hostKind: "cloud" };

export type TurnFailureFixture = { id: string; kind: FailureKind; error: string; code?: string; teamMachine?: true };

/// One per kind (failureCopy.ts `FailureKind`; KINDS below makes a new kind fail typecheck until it has one).
export const TURN_FAILURES: readonly TurnFailureFixture[] = [
  {
    id: "trust-pending",
    kind: "trust-pending",
    error: "trust.pending: answer the trust question for the folder first",
  },
  { id: "trust-untrusted", kind: "trust-untrusted", error: "trust.untrusted: the folder is not trusted" },
  {
    id: "no-team-account",
    kind: "no-team-account",
    error: "Codex needs a team account on this machine: run cr add codex to add one",
  },
  {
    id: "needs-credits",
    kind: "needs-credits",
    error: "AI models need cmux credits, your own API key, or a paid plan",
  },
  {
    id: "team-cap",
    kind: "team-cap",
    error:
      'API Error: 402 {"error":{"code":"team.cap_reached","message":"Your team reached its spending cap for this billing period. A team admin can raise it.","type":"insufficient_quota"}}',
  },
  {
    id: "no-credit",
    kind: "no-credit",
    error:
      "Your credit balance is too low to access the API. Please go to Plans & Billing to upgrade or purchase credits.",
  },
  {
    id: "cloud-auth-expired",
    kind: "cloud-auth-expired",
    error: "Error loading SSO Token: The SSO session associated with this profile has expired or is otherwise invalid.",
  },
  { id: "rate-limited", kind: "rate-limited", error: "API Error: 529 overloaded_error" },
  { id: "unreachable", kind: "unreachable", error: "API Error: Connection error." },
  { id: "invalid-key", kind: "invalid-key", error: "invalid x-api-key" },
  { id: "subscription-login", kind: "subscription-login", error: "Not logged in · Please run /login" },
  { id: "auth", kind: "auth", error: "401 Unauthorized: stream disconnected" },
  {
    id: "auth-team-machine",
    kind: "subscription-login",
    error: "Not logged in · Please run /login",
    teamMachine: true,
  },
  {
    id: "disk-full",
    kind: "disk-full",
    error:
      "agent process closed\nstderr: Error: ENOSPC: no space left on device, write '/root/.claude/projects/x.jsonl'",
  },
  {
    id: "context-full",
    kind: "context-full",
    error:
      'API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 212043 tokens > 200000 maximum"}}',
  },
  {
    id: "codex-config",
    kind: "codex-config",
    error: "failed to load workspace requirements: invalid input parameter",
  },
  {
    id: "tailscale",
    kind: "tailscale",
    error: "peer build-box unreachable: dial tcp build-box.tail0e5a.ts.net:4717: i/o timeout",
  },
  { id: "agent-exited", kind: "agent-exited", error: "agent process closed" },
  { id: "spawn-failed", kind: "spawn-failed", error: "failed to spawn agent: spawn claude-code-acp ENOENT" },
  {
    id: "other",
    kind: "other",
    error: "RpcError(-32603): internal error: unexpected end of frame (state=Streaming, seq=4417)",
  },
  // turnErrorCard.gallery's Cloud login rows (an owner machine with no, an expired, a refused Claude login).
  { id: "cloud-login-missing", kind: "auth", error: "Claude failed to authenticate: credential is missing" },
  { id: "cloud-login-expired", kind: "subscription-login", error: "OAuth token expired (HTTP 401)" },
  { id: "cloud-login-rejected", kind: "auth", error: "HTTP 403 Forbidden" },
  // The card's three ways in: the machine's team has cmux's gateway (acpmux names it).
  {
    id: "cloud-login-gateway",
    kind: "subscription-login",
    error:
      "Claude is not signed in here. Click Set up Claude Code credentials on this message to sign it in from your Mac; the message is sent again. Or click Use cmux's gateway: this machine's team has an account there. (Claude said: Not logged in · Please run /login)",
  },
];

/// Every failure kind, so a kind added to failureCopy.ts is a typecheck error here until it has a fixture.
export const KINDS: { [kind in FailureKind]: true } = {
  "trust-pending": true,
  "trust-untrusted": true,
  "no-team-account": true,
  "needs-credits": true,
  "team-cap": true,
  "no-credit": true,
  "cloud-auth-expired": true,
  "rate-limited": true,
  unreachable: true,
  "invalid-key": true,
  "subscription-login": true,
  "proxy-auth": true,
  auth: true,
  "disk-full": true,
  "context-full": true,
  "codex-config": true,
  tailscale: true,
  "agent-exited": true,
  "spawn-failed": true,
  other: true,
};
/// Kinds a Cloud chat cannot fail with: a proxy (`claude-sr`, `claude-cr`) is never a Cloud machine's route.
export const NOT_ON_CLOUD: ReadonlySet<FailureKind> = new Set(["proxy-auth"]);

export function turnFailureRoute(fixture: Pick<TurnFailureFixture, "teamMachine">): FailureRoute {
  return fixture.teamMachine ? { ...CLOUD_ROUTE, teamMachine: true } : CLOUD_ROUTE;
}

export const TURN_FAILURE_FIXTURES = TURN_FAILURES;

/// What this measurement does not reach yet, said in the report so a zero is never read as "none".
export const UNCOVERED: readonly { surface: string; why: string }[] = [
  {
    surface: "CloudSignIn step failures (bad code, expired, busy, CLI missing, shared machine)",
    why: "drawn only after clicks through the sign-in card; not driven yet",
  },
  {
    surface: "RepoRecoveryCard after a click (Connecting GitHub, Couldn't recover)",
    why: "drawn only after a click; not driven yet",
  },
  { surface: "CloudStartAsk (first login, login copy, Codex device code)", why: "asks, not errors; not counted" },
  { surface: "HarnessHealthNotice, failed prompt delivery on a Cloud chat", why: "not in the catalog yet" },
  { surface: "Cloud move, resume and desktop progress", why: "not in the catalog yet" },
  {
    surface: "start-to-working-chat steps",
    why: "the pane's in-page mock serves no Cloud start, so steps are not measured on Linux",
  },
];

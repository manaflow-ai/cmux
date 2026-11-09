import { expect, test } from "bun:test";
import {
  failureCopy,
  failureKind,
  failureRecovery,
  isAuthenticationFailure,
  isCloudRejectedCredential,
  isTeamMachineSignIn,
  offersOwnRoute,
} from "./failureCopy";
import { type Translate, translatorFor } from "./i18n";

test("only the Cloud provider rejection is eligible for cached-login recovery", () => {
  const route = { hostKind: "cloud" as const, harness: "claude" };
  expect(
    isCloudRejectedCredential(
      "The provider rejected Claude Code's credentials on this Cloud machine (HTTP 403).",
      route,
    ),
  ).toBe(true);
  expect(
    isCloudRejectedCredential("The provider rejected Claude Code's credentials on this Cloud machine (HTTP 403).", {
      hostKind: "local",
    }),
  ).toBe(false);
  expect(isCloudRejectedCredential("Claude Code login required", route)).toBe(false);
  expect(
    isCloudRejectedCredential("The provider rejected Codex's credentials on this Cloud machine (HTTP 403).", route),
  ).toBe(false);
});

// The connection drops acpmux retries by itself (hub/turn_errors.rs `says_connection_dropped`) read
// as "could not reach its server", not the generic "ran into a problem" (cmuxterm-hq#4879, finding 10).
test("a dropped connection reads as unreachable, with Retry", () => {
  for (const message of [
    "stream disconnected before completion: error sending request for url (https://api.openai.com/v1/responses)",
    "stream disconnected before completion",
    "error sending request for url (https://chatgpt.com/backend-api/codex/responses)",
    "API Error: Connection lost mid-response.",
    "connection aborted",
    "upstream connect error or disconnect/reset before headers",
    "premature close",
    "other side closed",
    "504 Gateway Timeout",
  ]) {
    expect(failureKind(message), message).toBe("unreachable");
  }
  expect(failureRecovery("unreachable")).toBe("retry");
});

test("sign-in words in the request's address are not a sign-in", () => {
  expect(failureKind("error sending request for url (https://auth.openai.com/oauth/token)")).toBe("unreachable");
});

test("a sign-in or key named beside a drop keeps its way out, as acpmux does not retry it", () => {
  expect(failureKind("Not logged in · Please run /login (stream disconnected)")).toBe("subscription-login");
  expect(failureKind("401 Unauthorized: stream disconnected")).toBe("auth");
  expect(failureKind("Invalid API key: stream disconnected")).toBe("invalid-key");
});

test("capacity, a quit agent and a typed exit keep their own kind", () => {
  expect(failureKind("503 Service Unavailable: stream disconnected")).toBe("rate-limited");
  expect(failureKind("agent process closed: broken pipe")).toBe("agent-exited");
  expect(failureKind("stream disconnected", undefined, "agent_exited")).toBe("agent-exited");
});

// A team Cloud machine takes no personal login (CloudHarnessLoginDecision `guest-not-owner`, guest
// `team`), so its Claude sign-in failure names that instead of "the provider rejected" and a set-up
// that would end in the transfer's refusal.
test("a Claude sign-in failure on a team Cloud machine says it takes no personal login", () => {
  const t = ((key: string) => key) as Translate;
  const team = { hostKind: "cloud" as const, harness: "claude", teamMachine: true };
  const rejected = "The provider rejected Claude Code's credentials on this Cloud machine (HTTP 401).";
  const signIns = [rejected, "Not logged in · Please run /login", "Claude Code provider credentials are missing"];
  for (const message of signIns) {
    const kind = failureKind(message, team);
    expect(isTeamMachineSignIn(kind, team), message).toBe(true);
    expect(failureCopy(t, message, team)).toBe("turn.failure.cloudTeamMachineNoLogin");
  }
  expect(isTeamMachineSignIn("auth", { ...team, harness: "claude-sr" })).toBe(true);
  expect(isTeamMachineSignIn("auth", { hostKind: "cloud", teamMachine: true })).toBe(true);
  // Every other card is as it was: an owner machine, Codex, a local chat, and other failures.
  expect(failureCopy(t, rejected, { hostKind: "cloud", harness: "claude" })).toBe("turn.failure.cloudAuthRejected");
  expect(isTeamMachineSignIn("auth", { ...team, harness: "codex" })).toBe(false);
  expect(isTeamMachineSignIn("auth", { ...team, hostKind: "local" })).toBe(false);
  expect(isTeamMachineSignIn("rate-limited", team)).toBe(false);
  expect(failureCopy(t, "429 Too Many Requests", team)).toBe("turn.failure.rateLimited");
});

// Lucas's fresh Codex chat failed with only "failed to load workspace requirements: invalid input
// parameter" under "ran into a problem and stopped". The card says which settings to check, and the
// file Codex names when it names one; a cloud bundle that timed out or refused a sign-in keeps its kind.
test("Codex's own settings that fail to load name what to fix", () => {
  const t = ((key: string, values?: Record<string, string | number>) =>
    values?.path ? `${key} ${values.path}` : key) as Translate;
  const codex = { name: "Codex", harness: "codex" };
  const bare = "failed to load workspace requirements: invalid input parameter";
  expect(failureKind(bare, codex)).toBe("codex-config");
  expect(failureKind("failed to reload workspace requirements: invalid input parameter")).toBe("codex-config");
  expect(failureCopy(t, bare, codex)).toBe("turn.failure.codexConfig");
  const at = "failed to load workspace requirements: invalid configuration at /Users/l/.codex/config.toml:3:1";
  expect(failureCopy(t, at, codex)).toBe("turn.failure.codexConfigAt /Users/l/.codex/config.toml");
  const spaced =
    "failed to load workspace requirements: invalid configuration at /Users/l/My Project/.codex/config.toml:3:1";
  expect(failureCopy(t, spaced, codex)).toBe("turn.failure.codexConfigAt /Users/l/My Project/.codex/config.toml");
  expect(failureRecovery("codex-config")).toBe("retry");
  expect(failureKind("failed to load workspace requirements: cloud config: request timed out")).toBe("unreachable");
  expect(failureKind("failed to load workspace requirements: cloud config: authentication failed (HTTP 401)")).toBe(
    "auth",
  );
});

// An own API key whose account ran out of credit read as "rate limited ... try again in a moment"
// (OpenAI sends it as a 429 naming a quota) or as an unknown failure (Anthropic's 400). Waiting does
// not help: the card says to add credit to the account the key belongs to, with Switch model first.
test("an own key's account out of credit reads as no-credit, not a rate limit", () => {
  const t = translatorFor("en");
  const claude = { name: "Claude Code", harness: "claude" };
  for (const message of [
    'API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."}}',
    "Credit balance too low",
    'unexpected status 429 Too Many Requests: {"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota","code":"insufficient_quota"}}',
    '{"error":{"message":"Billing hard limit has been reached","type":"invalid_request_error","code":"billing_hard_limit_reached"}}',
    "AI_APICallError: Insufficient credits. Add more using https://example.com/credits",
    "402 Payment Required",
  ]) {
    expect(failureKind(message, claude), message).toBe("no-credit");
    expect(failureCopy(t, message, claude), message).toBe(t("turn.failure.noCredit", { harness: "Claude Code" }));
    expect(isAuthenticationFailure(message)).toBe(false);
  }
  expect(failureKind(undefined, claude, "insufficient_quota")).toBe("no-credit");
  expect(failureRecovery("no-credit")).toBe("switch-model");
  expect(offersOwnRoute("no-credit", claude)).toBe(true);
  expect(t("turn.failure.noCredit", { harness: "Claude Code" })).toContain("Add credit to that account");
  // The cmux model router's free-tier and daily limits are 429s typed `insufficient_quota`
  // (backend inference/free.ts, Router.ts): they are rate limits, waiting helps.
  for (const message of [
    'unexpected status 429 Too Many Requests: {"error":{"code":"free.rate","message":"too many requests; wait a moment","type":"insufficient_quota"}}',
    '{"error":{"code":"free.rate","message":"too many requests; wait a moment","type":"insufficient_quota"}}',
    '{"error":{"code":"free.rate","message":"too many requests from this network","type":"insufficient_quota"}}',
    '{"error":{"code":"inference.daily_limit","message":"this team reached its daily request limit here","type":"insufficient_quota"}}',
  ])
    expect(failureKind(message, claude), message).toBe("rate-limited");
  // The router's daily budget (backend inference/route.ts `budget.exhausted`) and its plan's included
  // amount (included-stop.ts `usage.included_reached`, a 402) are the router's own refusals, typed
  // `insufficient_quota` too: never "fund the account behind your API key".
  for (const message of [
    'unexpected status 429 Too Many Requests: {"error":{"code":"budget.exhausted","message":"the daily model budget is used up; try again later","type":"insufficient_quota","retryable":true}}',
    'API Error: 402 Payment Required {"error":{"code":"usage.included_reached","message":"You used the AI amount included in your plan for this month. It resets at the start of next month.","type":"insufficient_quota","details":{"included_usd":20,"spent_usd":20.4,"resets_at":"2026-12-01T00:00:00.000Z"}}}',
  ]) {
    expect(failureKind(message, claude), message).not.toBe("no-credit");
    expect(failureKind(message, claude), message).toBe("rate-limited");
  }
  // The same refusals with `insufficient_quota` as acpmux's typed code: the router code in the text
  // still makes them limits. A typed `insufficient_quota` with no router code stays out of credit.
  for (const message of [
    '{"error":{"code":"budget.exhausted","message":"the daily model budget is used up; try again later","type":"insufficient_quota"}}',
    '{"error":{"code":"free.rate","message":"too many requests; wait a moment","type":"insufficient_quota"}}',
  ])
    expect(failureKind(message, claude, "insufficient_quota"), message).toBe("rate-limited");
  expect(failureKind("You exceeded your current quota", claude, "insufficient_quota")).toBe("no-credit");
  expect(failureKind(undefined, claude, "insufficient_quota")).toBe("no-credit");
  // A provider's bare `insufficient_quota`, with no rate words, is still out of credit.
  expect(failureKind('{"error":{"type":"insufficient_quota","code":"insufficient_quota"}}', claude)).toBe("no-credit");
  // A plain rate limit still reads as one, and the cmux model router's refusal as needs-credits.
  for (const message of [
    "429 Too Many Requests",
    "API Error: 429 rate_limit_error: This request would exceed your account's rate limit.",
    "unexpected status 429 Too Many Requests: Rate limit reached for gpt-5.5",
    "usage limit reached, resets in 3h",
    "API Error: 529 overloaded_error",
  ])
    expect(failureKind(message, claude), message).toBe("rate-limited");
  expect(failureKind(undefined, claude, "rate_limited")).toBe("rate-limited");
  expect(failureKind("Not enough cmux credits for this call. Add credits or use your own API key.")).toBe(
    "needs-credits",
  );
});

// A Bedrock or Vertex chat whose cloud sign-in expired read as "sign in again" (the agent's own login,
// which is fine) or as a bare 403. The card names the command that refreshes the cloud sign-in.
test("an expired cloud provider sign-in names the command that refreshes it", () => {
  const t = translatorFor("en");
  const claude = { name: "Claude Code", harness: "claude" };
  // An expired SSO sign-in names the profile to refresh: the chat's AWS_PROFILE when cmux knows it,
  // else the one the error names. A bare `aws sso login` would refresh the default profile.
  const ssoExpired =
    "Error loading SSO Token: The SSO session associated with this profile has expired or is otherwise invalid.";
  const signIn = (command: string) => t("turn.failure.cloudSignInExpired", { harness: "Claude Code", command });
  const ssoCopy = t("turn.failure.cloudSsoExpired", { harness: "Claude Code" });
  const named = "Error when retrieving token from sso: Token has expired and refresh failed (profile: dev-admin)";
  expect(failureCopy(t, ssoExpired, { ...claude, awsProfile: "work" })).toBe(signIn("aws sso login --profile work"));
  expect(failureCopy(t, named, claude)).toBe(signIn("aws sso login --profile dev-admin"));
  // A profile name that is not one is never pasted into a command, nor is a part of it: the whole
  // value the error names is checked, so `work/admin` never becomes `--profile work`.
  for (const profile of ['profile: "work/admin"', "profile: work/admin", "--profile work$(id)"]) {
    const message = `Token has expired and refresh failed (${profile})`;
    expect(failureCopy(t, message, claude), message).toBe(ssoCopy);
  }
  expect(failureCopy(t, ssoExpired, { ...claude, awsProfile: "work; rm -rf ~" })).toBe(ssoCopy);
  for (const message of [ssoExpired, "Token has expired and refresh failed"]) {
    expect(failureKind(message, claude), message).toBe("cloud-auth-expired");
    expect(failureCopy(t, message, claude), message).toBe(ssoCopy);
  }
  expect(t("turn.failure.cloudSsoExpired", { harness: "Claude Code" })).toContain("aws sso login --profile");
  // Application default credentials or Vertex named: `gcloud auth application-default login`.
  const google = [
    "Reauthentication is needed. Please run `gcloud auth application-default login` to reauthenticate.",
    "Error: Could not load the default credentials. Browse to https://cloud.google.com/docs/authentication for more information.",
    "invalid_grant: Bad Request from https://us-east5-aiplatform.googleapis.com/v1/projects/p/locations/us-east5/publishers/anthropic/models/claude:streamRawPredict",
    "google.auth.exceptions.RefreshError: invalid_grant: reauth related error (invalid_rapt); application default credentials",
  ];
  for (const [messages, command] of [[google, "gcloud auth application-default login"]] as const)
    for (const message of messages) {
      expect(failureKind(message, claude), message).toBe("cloud-auth-expired");
      expect(failureCopy(t, message, claude), message).toBe(
        t("turn.failure.cloudSignInExpired", { harness: "Claude Code", command }),
      );
      expect(isAuthenticationFailure(message)).toBe(false);
    }
  // Static keys, or no SSO named: the card says to refresh the cloud credentials, with no command.
  for (const message of [
    "API Error: 403 ExpiredTokenException: The security token included in the request is expired",
    "ExpiredToken: The provided token has expired.",
    "UnrecognizedClientException: The security token included in the request is invalid.",
    "CredentialsProviderError: Could not load credentials from any providers",
  ]) {
    expect(failureKind(message, claude), message).toBe("cloud-auth-expired");
    expect(failureCopy(t, message, claude), message).toBe(
      t("turn.failure.cloudCredentialsExpired", { harness: "Claude Code" }),
    );
  }
  expect(failureRecovery("cloud-auth-expired")).toBe("retry");
  // Gemini's own OAuth through google-auth-library is the agent's sign-in, not application default
  // credentials: it keeps Sign in again.
  for (const message of [
    "('invalid_grant: Bad Request', {'error': 'invalid_grant', 'error_description': 'Bad Request'}) from https://oauth2.googleapis.com/token",
    "GaxiosError: invalid_grant\n    at Gaxios._request (node_modules/google-auth-library/build/src/auth/oauth2client.js:120:23)",
    "google.auth.exceptions.RefreshError: invalid_grant: reauth related error (invalid_rapt)",
  ])
    expect(failureKind(message, claude), message).toBe("subscription-login");
  // The agent's own expired login keeps its Sign in again.
  expect(failureKind("OAuth token refresh failed: invalid_grant")).toBe("subscription-login");
  expect(failureKind("Not logged in · Please run /login")).toBe("subscription-login");
  expect(failureKind("401 Unauthorized: token expired")).toBe("auth");
});

// A bare `invalid_rapt` (Google's reauth refresh error) with no application default credentials named
// is the agent's own sign-in, like `invalid_grant`: it offers Sign in again, not an unknown failure.
test("a bare invalid_rapt is the agent's own sign-in", () => {
  for (const message of ["invalid_rapt", "RefreshError: reauth related error (invalid_rapt)"]) {
    expect(failureKind(message), message).toBe("subscription-login");
    expect(failureRecovery(failureKind(message)), message).toBe("sign-in");
  }
});

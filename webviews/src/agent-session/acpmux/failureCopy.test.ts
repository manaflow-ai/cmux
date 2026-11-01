import { expect, test } from "bun:test";
import {
  failureCopy,
  failureKind,
  failureRecovery,
  isCloudRejectedCredential,
  isTeamMachineSignIn,
} from "./failureCopy";
import type { Translate } from "./i18n";

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
  for (const message of [rejected, "Not logged in · Please run /login", "Claude Code provider credentials are missing"]) {
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

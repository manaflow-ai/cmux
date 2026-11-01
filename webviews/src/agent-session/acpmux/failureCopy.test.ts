import { expect, test } from "bun:test";
import { failureKind, failureRecovery, isCloudRejectedCredential } from "./failureCopy";

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

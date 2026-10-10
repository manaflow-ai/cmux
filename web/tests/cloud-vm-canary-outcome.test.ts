import { describe, expect, test } from "bun:test";

import { classifyCodexCanaryOutcome } from "../scripts/cloud-vm/canaryOutcome.mjs";

describe("classifyCodexCanaryOutcome", () => {
  test("accepts the legacy no-account response", () => {
    expect(classifyCodexCanaryOutcome('{"error":"no_usable_account"}', { zeroToken: true })).toBe("no_account");
  });

  test("accepts the OpenAI-shaped no-account response", () => {
    expect(classifyCodexCanaryOutcome(
      '{"error":{"message":"No Codex account is configured","type":"invalid_request_error","code":"no_account_configured"}}',
      { zeroToken: true },
    )).toBe("no_account");
  });

  test("requires an exact pong line for a token-backed turn", () => {
    expect(classifyCodexCanaryOutcome("prompt\npong\ncodex-exit 0", { zeroToken: false })).toBe("answered");
    expect(classifyCodexCanaryOutcome("the answer is pong", { zeroToken: false })).toBe("failed");
  });

  test("does not treat a missing Codex binary as a passing no-account check", () => {
    expect(classifyCodexCanaryOutcome("codex-missing\n{\"error\":\"no_usable_account\"}", { zeroToken: true })).toBe("failed");
  });
});

import { describe, expect, test } from "bun:test";

import { classifyCodexCanaryOutcome, edgeCanaryProblems, retryGuestEdgeRequest } from "../scripts/cloud-vm/canaryOutcome.mjs";

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

  test("accepts the terminal no-usable-account response", () => {
    expect(classifyCodexCanaryOutcome(
      '{"error":{"message":"No healthy Codex subscription is currently available.","type":"usage_limit_reached","code":"no_usable_account"},"retryable":false}',
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

describe("retryGuestEdgeRequest", () => {
  const host = "coderouter.cmux.internal";
  const dnsMiss = { stdout: "000", stderr: `curl: (6) Could not resolve host: ${host}\n`, exitCode: 6 };

  test("recovers a transient resolver miss", async () => {
    const success = { stdout: "200", stderr: "", exitCode: 0 };
    let calls = 0;
    const result = await retryGuestEdgeRequest(async () => ++calls === 1 ? dnsMiss : success, host, { delayMs: 0 });
    expect(result).toBe(success);
    expect(calls).toBe(2);
  });

  test("returns the final DNS failure when the attempt budget is exhausted", async () => {
    let calls = 0;
    const result = await retryGuestEdgeRequest(async () => { calls += 1; return dnsMiss; }, host, { attempts: 3, delayMs: 0 });
    expect(result).toBe(dnsMiss);
    expect(calls).toBe(3);
  });

  test.each([
    { stdout: "403", stderr: "", exitCode: 0 },
    { stdout: "503", stderr: "", exitCode: 0 },
    { stdout: "", stderr: `curl: (6) Could not resolve host: ${host}.other\n`, exitCode: 6 },
    { stdout: "", stderr: `curl: (7) Failed to connect to ${host}`, exitCode: 7 },
  ])("does not retry a different failure: %j", async (response) => {
    let calls = 0;
    expect(await retryGuestEdgeRequest(async () => { calls += 1; return response; }, host, { delayMs: 0 })).toBe(response);
    expect(calls).toBe(1);
  });

  test("preserves an API or authentication exception", async () => {
    const failure = new Error("POST exec expected 200, got 403");
    let calls = 0;
    await expect(retryGuestEdgeRequest(async () => { calls += 1; throw failure; }, host, { delayMs: 0 })).rejects.toBe(failure);
    expect(calls).toBe(1);
  });

  test("cancellation interrupts the retry delay", async () => {
    const controller = new AbortController();
    let calls = 0;
    const pending = retryGuestEdgeRequest(async () => { calls += 1; return dnsMiss; }, host, { delayMs: 60_000, signal: controller.signal });
    queueMicrotask(() => controller.abort());
    await expect(pending).rejects.toBeTruthy();
    expect(calls).toBe(1);
  });

  test("an already cancelled request never runs", async () => {
    const controller = new AbortController();
    controller.abort();
    let calls = 0;
    await expect(retryGuestEdgeRequest(async () => { calls += 1; return dnsMiss; }, host, { signal: controller.signal })).rejects.toBeTruthy();
    expect(calls).toBe(0);
  });
});

describe("edgeCanaryProblems", () => {
  test("uses the authenticated edge response instead of a provider hosts marker", () => {
    expect(edgeCanaryProblems({
      tokenOnDisk: null,
      modelsStatus: "200",
      codexOutcome: "no_account",
      claudeCheck: false,
      claudeOutcome: undefined,
    })).toEqual([]);
  });

  test("still fails when the edge contract or guest secret hygiene fails", () => {
    expect(edgeCanaryProblems({
      tokenOnDisk: "/etc/cmux/model-plane.env",
      modelsStatus: "503",
      codexOutcome: "failed",
      codexTail: "coderouter_unavailable",
      claudeCheck: false,
    })).toEqual([
      "route token found in guest files: /etc/cmux/model-plane.env",
      "GET /api/coderouter/vm-usage/self from the guest returned 503",
      "codex turn through the edge did not answer: coderouter_unavailable",
    ]);
  });
});

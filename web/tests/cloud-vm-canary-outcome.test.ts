import { describe, expect, test } from "bun:test";

import {
  classifyCodexCanaryOutcome,
  edgeCanaryProblems,
  retryGuestEdgeRequest,
} from "../scripts/cloud-vm/canaryOutcome.mjs";

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

describe("retryGuestEdgeRequest", () => {
  test("retries a transient resolver miss after the edge was ready", async () => {
    const responses = [
      { stdout: "codex-exit 0\ncurl: (6) Could not resolve host: coderouter.cmux.internal", stderr: "", exitCode: 0 },
      { stdout: '{"error":"no_usable_account"}', stderr: "", exitCode: 0 },
    ];
    let calls = 0;
    const result = await retryGuestEdgeRequest(
      async () => {
        calls += 1;
        return responses.shift();
      },
      "coderouter.cmux.internal",
      { delayMs: 0 },
    );

    expect(calls).toBe(2);
    expect((result as { stdout?: string } | undefined)?.stdout).toContain("no_usable_account");
  });

  test("does not retry an HTTP or authentication failure", async () => {
    let calls = 0;
    const result = await retryGuestEdgeRequest(
      async () => {
        calls += 1;
        return { stdout: '{"error":"no_usable_account"}', stderr: "", exitCode: 0 };
      },
      "coderouter.cmux.internal",
      { delayMs: 0 },
    );

    expect(calls).toBe(1);
    expect((result as { stdout?: string } | undefined)?.stdout).toContain("no_usable_account");
  });

  test("cancels a pending retry delay", async () => {
    const controller = new AbortController();
    const pending = retryGuestEdgeRequest(
      async () => ({ stdout: "Could not resolve host: coderouter.cmux.internal", stderr: "", exitCode: 0 }),
      "coderouter.cmux.internal",
      { delayMs: 50, signal: controller.signal },
    );
    queueMicrotask(() => controller.abort());

    await expect(pending).rejects.toBeTruthy();
  });
});

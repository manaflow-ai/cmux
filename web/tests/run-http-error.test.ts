import { describe, expect, test } from "bun:test";
import { runError } from "../services/runs/http";
import { RuntimeAttemptConflictError } from "../services/vms/runtimeRepository";

describe("runError", () => {
  test("maps a runtime attempt conflict to a non-retryable 409", async () => {
    const response = runError(new RuntimeAttemptConflictError("run attempt's VM is being cleaned up"));
    expect(response.status).toBe(409);
    const body = await response.json() as { error?: string; retryable?: boolean };
    expect(body.error).toBe("run_attempt_conflict");
    expect(body.retryable).not.toBe(true);
  });
});

test("request errors preserve their status, code and provider reason in the shared envelope", async () => {
  const { RunRequestError } = await import("../services/runs/http");
  const response = runError(new RunRequestError("run_provider_unavailable", "Provider unavailable.", "Choose freestyle.", 409, { reasonCode: "adapter_not_configured" }));
  expect(response.status).toBe(409);
  expect(await response.json()).toMatchObject({ error: "run_provider_unavailable", message: "Provider unavailable.", action: "Choose freestyle.", reasonCode: "adapter_not_configured", retryable: false, ui: { message: "Provider unavailable.", retryable: false } });
});

test("worker routes return actionable 401 envelopes without accepting user authentication", async () => {
  const routes = await Promise.all([
    import("../app/api/runs/[id]/attempts/[attemptId]/artifacts/route"),
    import("../app/api/runs/[id]/attempts/[attemptId]/events/route"),
    import("../app/api/runs/[id]/attempts/[attemptId]/lease/route"),
  ]);
  for (const route of routes) {
    const response = await route.POST(new Request("https://cmux.test/api/runs/run/attempts/attempt", { method: "POST", headers: { authorization: "Bearer user-token" } }), { params: Promise.resolve({ id: "run", attemptId: "attempt" }) });
    expect(response.status).toBe(401);
    const body = await response.json();
    expect(body.error).toBe("unauthorized");
    expect(body.message).toContain("worker credential");
    expect(body.action).toContain("worker token");
    expect(body.action).toContain("cmux cloud sign-in");
    expect(body.ui.message).toBe(body.message);
    expect(body.ui.retryable).toBe(false);
  }
});

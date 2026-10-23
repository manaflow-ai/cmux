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

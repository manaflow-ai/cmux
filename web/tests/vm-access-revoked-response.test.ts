import { describe, expect, test } from "bun:test";

import { VmAccessGrantRevokedError } from "../services/vms/errors";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";

// A revoked Mac login can never enroll again; only a fresh sign-in can. The
// Mac app stops retrying on `retryable: false`, so the refusal must say so at
// the top level (not only in the `ui` block, which defaults every error to
// false) or a client that honors the flag keeps retrying a permanent answer.
describe("vm_access_revoked response", () => {
  test("is an explicit, non-retryable sign-in refusal", async () => {
    const response = await vmWorkflowErrorResponse(new VmAccessGrantRevokedError({
      stackSessionId: "session-a",
    }));
    expect(response).not.toBeNull();
    expect(response!.status).toBe(403);
    expect(response!.headers.get("retry-after")).toBeNull();
    const payload = await response!.json() as Record<string, unknown>;
    expect(payload).toMatchObject({
      error: "vm_access_revoked",
      phase: "network",
      retryable: false,
      ui: { retryable: false },
    });
    expect(payload.retryAfterSeconds).toBeUndefined();
    expect(JSON.stringify(payload)).not.toContain("session-a");
  });
});

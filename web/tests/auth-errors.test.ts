import { describe, expect, test } from "bun:test";
import { authProviderErrorResponse } from "../services/vms/authErrors";
import { runWithVmRequestContext, type VmRequestContext } from "../services/vms/requestContext";

const requestContext: VmRequestContext = {
  route: "/api/vm",
  method: "POST",
  operation: "create",
  startedAtMs: 0,
  client: { requestId: "req-auth-error" },
};

describe("native auth provider error boundary", () => {
  test("maps bounded Stack Auth throttles to a retryable 429", async () => {
    const response = authProviderErrorResponse(
      new AggregateError([
        new Error("Rate limited, no retry-after header received"),
      ], "Stack Auth request failed"),
      "devices.get.auth",
    );

    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(await response.json()).toEqual({ error: "rate_limited" });
  });

  test("maps provider outages without exposing error metadata", async () => {
    const response = authProviderErrorResponse(
      new Error("provider credentials and bearer token should stay private"),
      "devices.get.auth",
    );

    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBeNull();
    expect(await response.json()).toEqual({
      error: "authentication_unavailable",
    });
  });

  test("handles cyclic error metadata without walking forever", async () => {
    const error: { cause?: unknown; message: string } = {
      message: "too many requests",
    };
    error.cause = error;

    const response = authProviderErrorResponse(error, "devices.get.auth");

    expect(response.status).toBe(429);
  });

  test("includes the client request id inside a VM request context", async () => {
    const response = runWithVmRequestContext(requestContext, () =>
      authProviderErrorResponse(new Error("provider unavailable"), "/api/vm.auth"));

    expect(await response.json()).toMatchObject({
      error: "authentication_unavailable",
      requestId: "req-auth-error",
    });
  });
});

import { describe, expect, test } from "bun:test";

import { NotImplementedError } from "../services/vms/drivers/types";
import { VmProviderOperationError } from "../services/vms/errors";
import { isOperatorFaultVmError } from "../services/vms/observability";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";

// Blaxel snapshot/restore throw NotImplementedError. Before this mapping they
// surfaced as 502 vm_cloud_service_unavailable retryable:true, telling users
// to retry an operation the provider will never perform.
describe("unsupported provider operations", () => {
  test("driver NotImplementedError maps to an honest non-retryable 501", async () => {
    const response = vmWorkflowErrorResponse(new VmProviderOperationError({
      provider: "blaxel",
      operation: "snapshot",
      cause: new NotImplementedError("blaxel", "snapshot"),
    }));
    expect(response).not.toBeNull();
    expect(response!.status).toBe(501);
    expect(response!.headers.get("retry-after")).toBeNull();
    const payload = await response!.json() as Record<string, unknown>;
    expect(payload).toMatchObject({
      error: "vm_operation_unsupported",
      retryable: false,
      phase: "snapshot",
      details: {
        operation: "snapshot",
        retryable: false,
        providerCode: "provider_operation_unsupported",
      },
      ui: {
        title: "Cloud VM operation unavailable",
        retryable: false,
        severity: "error",
      },
    });
    const raw = JSON.stringify(payload);
    // No provider or implementation leaks, and the copy must not invite a retry.
    expect(raw).not.toMatch(/blaxel|not implemented|NotImplemented/i);
    expect(String(payload.action)).toMatch(/^Do not retry/);
  });

  test("restore gets restore-phase copy", async () => {
    const response = vmWorkflowErrorResponse(new VmProviderOperationError({
      provider: "blaxel",
      operation: "restore",
      cause: new NotImplementedError("blaxel", "restore"),
    }));
    expect(response!.status).toBe(501);
    const payload = await response!.json() as { error: string; phase: string; message: string };
    expect(payload.error).toBe("vm_operation_unsupported");
    expect(payload.phase).toBe("restore");
    expect(payload.message).toContain("restoring");
  });

  test("the gateway's capability refusal maps the same way", async () => {
    const response = vmWorkflowErrorResponse(new VmProviderOperationError({
      provider: "e2b",
      operation: "snapshot",
      cause: new Error("Cloud VM snapshots are not supported by this provider gateway"),
    }));
    expect(response!.status).toBe(501);
    const payload = await response!.json() as { error: string; retryable: boolean };
    expect(payload.error).toBe("vm_operation_unsupported");
    expect(payload.retryable).toBe(false);
  });

  test("transient provider failures keep the retryable 502 path", async () => {
    const response = vmWorkflowErrorResponse(new VmProviderOperationError({
      provider: "blaxel",
      operation: "snapshot",
      cause: new Error("INTERNAL_ERROR: Internal server error"),
    }));
    expect(response!.status).toBe(502);
    const payload = await response!.json() as { error: string; retryable: boolean };
    expect(payload.error).toBe("vm_cloud_service_unavailable");
    expect(payload.retryable).toBe(true);
  });

  test("vm_operation_unsupported is a product limitation, not an operator fault", () => {
    expect(isOperatorFaultVmError({ error: "vm_operation_unsupported", status: 501 })).toBe(false);
    // Every other 5xx stays an incident.
    expect(isOperatorFaultVmError({ error: "vm_internal_error", status: 500 })).toBe(true);
    expect(isOperatorFaultVmError({ error: "vm_cloud_service_unavailable", status: 502 })).toBe(true);
  });
});

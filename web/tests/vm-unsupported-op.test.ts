import { describe, expect, test } from "bun:test";

import { BlaxelRetryExhaustedError } from "../services/vms/drivers/blaxel";
import { BlaxelProvider } from "../services/vms/drivers/blaxel";
import { VmOperationUnsupportedError, VmProviderOperationError } from "../services/vms/errors";
import { isOperatorFaultVmError } from "../services/vms/observability";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";
import { vmRequestLocale } from "../services/vms/vmErrorMessages";
import { locales } from "../i18n/routing";

// Blaxel snapshot/restore throw VmOperationUnsupportedError. Before this mapping they
// surfaced as 502 vm_cloud_service_unavailable retryable:true, telling users
// to retry an operation the provider will never perform.
describe("unsupported provider operations", () => {
  test("the structured driver error maps to an honest non-retryable 501", async () => {
    const response = await vmWorkflowErrorResponse(new VmProviderOperationError({
      provider: "blaxel",
      operation: "snapshot",
      cause: new VmOperationUnsupportedError({ provider: "blaxel", operation: "snapshot" }),
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
    const response = await vmWorkflowErrorResponse(new VmProviderOperationError({
      provider: "blaxel",
      operation: "restore",
      cause: new VmOperationUnsupportedError({ provider: "blaxel", operation: "restore" }),
    }));
    expect(response!.status).toBe(501);
    const payload = await response!.json() as { error: string; phase: string; message: string };
    expect(payload.error).toBe("vm_operation_unsupported");
    expect(payload.phase).toBe("restore");
    expect(payload.message).toContain("restoring");
  });

  test("a provider message containing the capability phrase stays retryable", async () => {
    const response = await vmWorkflowErrorResponse(new VmProviderOperationError({
      provider: "e2b",
      operation: "snapshot",
      cause: new Error("Cloud VM snapshots are not supported by this provider gateway"),
    }));
    expect(response!.status).toBe(502);
    const payload = await response!.json() as { error: string; retryable: boolean };
    expect(payload.error).toBe("vm_cloud_service_unavailable");
    expect(payload.retryable).toBe(true);
  });

  test("Blaxel throws the structured error for unsupported operations", async () => {
    const provider = new BlaxelProvider();
    await expect(provider.snapshot("vm-1")).rejects.toMatchObject({
      _tag: "VmOperationUnsupportedError",
      provider: "blaxel",
      operation: "snapshot",
    });
    await expect(provider.restore("snapshot-1")).rejects.toMatchObject({
      _tag: "VmOperationUnsupportedError",
      provider: "blaxel",
      operation: "restore",
    });
  });

  test("transient provider failures keep the retryable 502 path", async () => {
    const response = await vmWorkflowErrorResponse(new VmProviderOperationError({
      provider: "blaxel",
      operation: "snapshot",
      cause: new Error("INTERNAL_ERROR: Internal server error"),
    }));
    expect(response!.status).toBe(502);
    const payload = await response!.json() as { error: string; retryable: boolean };
    expect(payload.error).toBe("vm_cloud_service_unavailable");
    expect(payload.retryable).toBe(true);
  });

  test("hides provider retry details from the public response", async () => {
    const response = await vmWorkflowErrorResponse(new VmProviderOperationError({
      provider: "blaxel",
      operation: "create",
      cause: new BlaxelRetryExhaustedError(
        "GET",
        "https://api.blaxel.test/workspaces/private",
        4,
        "503: private upstream details",
      ),
    }));
    const payload = await response!.json() as Record<string, unknown>;
    const raw = JSON.stringify(payload);
    expect(response!.status).toBe(502);
    expect(payload.reason).toBe("The Cloud VM service is temporarily unavailable.");
    expect(payload.details).toMatchObject({
      operation: "create",
      retryable: true,
      providerCode: "provider_retry_exhausted",
    });
    expect(payload.details).not.toHaveProperty("providerMessage");
    expect(raw).not.toContain("blaxel");
    expect(raw).not.toContain("api.blaxel.test");
    expect(raw).not.toContain("private upstream details");
  });

  test("resolves unsupported-operation copy from the requested locale", async () => {
    const response = await vmWorkflowErrorResponse(
      new VmProviderOperationError({
        provider: "blaxel",
        operation: "restore",
        cause: new VmOperationUnsupportedError({ provider: "blaxel", operation: "restore" }),
      }),
      { locale: "ja" },
    );
    const payload = await response!.json() as Record<string, unknown>;
    expect(payload.message).toContain("保存済み状態");
    expect(payload.action).toContain("再試行しても解決しません");
    expect(payload.ui).toMatchObject({ title: "Cloud VM 操作を利用できません" });
  });

  test("ships the unsupported-operation message shape in every locale catalog", async () => {
    for (const locale of locales) {
      const messages = (await import(`../messages/${locale}.json`)).default as {
        vmErrors?: {
          unsupported?: {
            title?: string;
            reason?: string;
            message?: Record<string, string>;
            action?: Record<string, string>;
          };
        };
      };
      const unsupported = messages.vmErrors?.unsupported;
      expect(unsupported?.title).toBeString();
      expect(unsupported?.reason).toBeString();
      expect(Object.keys(unsupported?.message ?? {}).sort()).toEqual([
        "default",
        "fork",
        "restore",
        "snapshot",
      ]);
      expect(Object.keys(unsupported?.action ?? {}).sort()).toEqual([
        "default",
        "fork",
        "restore",
        "snapshot",
      ]);
    }
  });

  test("negotiates the VM response locale from request headers", () => {
    expect(vmRequestLocale(new Request("https://cmux.com/api/vm", {
      headers: { "accept-language": "ja-JP,ja;q=0.9,en;q=0.8" },
    }))).toBe("ja");
    expect(vmRequestLocale(new Request("https://cmux.com/api/vm", {
      headers: { "x-next-intl-locale": "de", "accept-language": "ja" },
    }))).toBe("de");
  });

  test("vm_operation_unsupported is a product limitation, not an operator fault", () => {
    expect(isOperatorFaultVmError({ error: "vm_operation_unsupported", status: 501 })).toBe(false);
    // Every other 5xx stays an incident.
    expect(isOperatorFaultVmError({ error: "vm_internal_error", status: 500 })).toBe(true);
    expect(isOperatorFaultVmError({ error: "vm_cloud_service_unavailable", status: 502 })).toBe(true);
  });
});

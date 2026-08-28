import { describe, expect, test } from "bun:test";

import {
  captureVmProvisionOutcome,
  isOperatorFaultVmError,
  VM_ERROR_CODE_HEADER,
} from "../services/vms/observability";
import { vmErrorResponse } from "../services/vms/routeHelpers";

describe("vm error choke point", () => {
  test("every vm error response exposes the machine-readable code header", async () => {
    const response = vmErrorResponse({
      error: "vm_image_config_error",
      status: 503,
      message: "The Cloud VM image is not available in this environment.",
      action: "Retry in a moment.",
      details: { imageRequested: true },
      diagnostics: { provider: "freestyle", image: "blaxel/xfce-vnc:latest", envVar: "FREESTYLE_SANDBOX_SNAPSHOT" },
      phase: "create",
      retryable: true,
    });
    expect(response.status).toBe(503);
    expect(response.headers.get(VM_ERROR_CODE_HEADER)).toBe("vm_image_config_error");
    const payload = await response.json() as { details: Record<string, unknown> };
    expect(payload.details.imageRequested).toBe(true);
  });

  test("diagnostics never leak into the response payload", async () => {
    const response = vmErrorResponse({
      error: "vm_image_config_error",
      status: 503,
      message: "The Cloud VM image is not available in this environment.",
      action: "Retry in a moment.",
      details: { imageRequested: false },
      diagnostics: {
        provider: "freestyle",
        envVar: "FREESTYLE_SANDBOX_SNAPSHOT",
        image: "sh-17agfasevrc18c8f15nn",
        configReason: "sh-17agfasevrc18c8f15nn is not listed in the Cloud VM image manifest",
      },
      phase: "create",
    });
    const raw = JSON.stringify(await response.json());
    // Mirrors expectNoCloudVmImplementationLeaks in vm-route-auth.test.ts: the
    // operator context flows to Sentry, never to the caller.
    expect(raw).not.toMatch(/freestyle|FREESTYLE_|manifest|sh-[a-z0-9]{8,24}|diagnostics/i);
  });

  test("operator-fault classification: config and 5xx report, user-fault does not", () => {
    expect(isOperatorFaultVmError({ error: "vm_image_config_error", status: 503 })).toBe(true);
    expect(isOperatorFaultVmError({ error: "vm_create_disabled", status: 503 })).toBe(true);
    expect(isOperatorFaultVmError({ error: "vm_base_create_failed", status: 500 })).toBe(true);
    expect(isOperatorFaultVmError({ error: "anything", status: 500 })).toBe(true);
    expect(isOperatorFaultVmError({ error: "vm_active_limit_exceeded", status: 402 })).toBe(false);
    expect(isOperatorFaultVmError({ error: "vm_invalid_request", status: 400 })).toBe(false);
  });
});

describe("cloud_vm_provision capture", () => {
  function captured(response: Response): Record<string, unknown> | null {
    let body: Record<string, unknown> | null = null;
    const fakeFetch = ((input: string | URL | Request, init?: RequestInit) => {
      void input;
      body = JSON.parse(String(init?.body)) as Record<string, unknown>;
      return Promise.resolve(new Response("ok"));
    }) as typeof fetch;
    captureVmProvisionOutcome(
      { userId: "user-1", operation: "base_open", response },
      { fetch: fakeFetch, env: { CMUX_VM_ANALYTICS_FORCE: "1" } },
    );
    return body;
  }

  test("failure events carry the error code from the response header", () => {
    const response = vmErrorResponse({
      error: "vm_image_config_error",
      status: 503,
      message: "unavailable",
      action: "retry",
      phase: "create",
    });
    const body = captured(response);
    expect(body?.event).toBe("cloud_vm_provision");
    expect(body?.distinct_id).toBe("user-1");
    const properties = body?.properties as Record<string, unknown>;
    expect(properties.success).toBe(false);
    expect(properties.status).toBe(503);
    expect(properties.error_code).toBe("vm_image_config_error");
    expect(properties.operation).toBe("base_open");
  });

  test("success events carry no error code", () => {
    const body = captured(new Response("{}", { status: 200 }));
    const properties = body?.properties as Record<string, unknown>;
    expect(properties.success).toBe(true);
    expect(properties.status).toBe(200);
    expect(properties.error_code).toBeUndefined();
  });

  test("capture is disabled outside production unless forced", () => {
    let called = false;
    const fakeFetch = (() => {
      called = true;
      return Promise.resolve(new Response("ok"));
    }) as typeof fetch;
    captureVmProvisionOutcome(
      { userId: "user-1", operation: "create", response: new Response("{}") },
      { fetch: fakeFetch, env: {} },
    );
    expect(called).toBe(false);
  });
});

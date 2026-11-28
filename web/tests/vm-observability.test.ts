import { describe, expect, test } from "bun:test";
import type { Span } from "@opentelemetry/api";

import {
  annotateVmErrorSpan,
  captureVmProvisionOutcome,
  isOperatorFaultVmError,
  VM_ERROR_CODE_HEADER,
} from "../services/vms/observability";
import { vmErrorResponse } from "../services/vms/routeHelpers";

function fakeSpan(): { span: Span; attributes: Record<string, unknown> } {
  const attributes: Record<string, unknown> = {};
  const span = {
    setAttributes(values: Record<string, unknown>) {
      Object.assign(attributes, values);
      return span;
    },
    setAttribute(key: string, value: unknown) {
      attributes[key] = value;
      return span;
    },
  } as unknown as Span;
  return { span, attributes };
}

describe("vm error choke point", () => {
  test("every vm error response exposes the machine-readable code header", async () => {
    const response = vmErrorResponse({
      error: "vm_image_config_error",
      status: 503,
      message: "The Cloud VM image is not available in this environment.",
      action: "Retry in a moment.",
      details: { imageRequested: true },
      diagnostics: { provider: "freestyle", image: "sh-fb3dcf7b47894114889b10186626af5b", envVar: "FREESTYLE_SANDBOX_SNAPSHOT" },
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
    // operator context flows to the trace span, never to the caller.
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

  test("the span carries the full operator context, user-fault included", () => {
    const { span, attributes } = fakeSpan();
    annotateVmErrorSpan(span, {
      error: "vm_image_config_error",
      status: 503,
      message: "The Cloud VM image is not available in this environment.",
      action: "Retry in a moment.",
      reason: "sh-17agfasevrc18c8f15nn is not listed in the Cloud VM image manifest",
      diagnostics: { provider: "freestyle", image: "sh-17agfasevrc18c8f15nn", envVar: "FREESTYLE_SANDBOX_SNAPSHOT" },
      phase: "create",
    });
    expect(attributes["cmux.vm.error_code"]).toBe("vm_image_config_error");
    expect(attributes["cmux.vm.error_status"]).toBe(503);
    expect(attributes["cmux.vm.error_phase"]).toBe("create");
    expect(attributes["cmux.vm.error_operator_fault"]).toBe(true);
    expect(attributes["cmux.vm.error_provider"]).toBe("freestyle");
    expect(attributes["cmux.vm.error_image"]).toBe("sh-17agfasevrc18c8f15nn");
    expect(attributes["cmux.vm.error_env_var"]).toBe("FREESTYLE_SANDBOX_SNAPSHOT");
    expect(attributes["cmux.vm.error_reason"]).toMatch(/not listed/);

    const userFault = fakeSpan();
    annotateVmErrorSpan(userFault.span, {
      error: "vm_billing_team_required",
      status: 409,
      message: "Select a team.",
      action: "Select a team in cmux, then retry.",
      phase: "billing",
    });
    expect(userFault.attributes["cmux.vm.error_code"]).toBe("vm_billing_team_required");
    expect(userFault.attributes["cmux.vm.error_operator_fault"]).toBe(false);
  });
});

describe("cloud_vm_provision capture", () => {
  function captured(response: Response, span?: Span): {
    body: Record<string, unknown> | null;
    posthogCalled: boolean;
  } {
    let body: Record<string, unknown> | null = null;
    let posthogCalled = false;
    const fakeFetch = ((input: string | URL | Request, init?: RequestInit) => {
      void input;
      posthogCalled = true;
      body = JSON.parse(String(init?.body)) as Record<string, unknown>;
      return Promise.resolve(new Response("ok"));
    }) as typeof fetch;
    captureVmProvisionOutcome(
      { userId: "user-1", operation: "base_open", response, span },
      { fetch: fakeFetch, env: { CMUX_VM_ANALYTICS_FORCE: "1" } },
    );
    return { body, posthogCalled };
  }

  test("failure events carry the error code from the response header", () => {
    const response = vmErrorResponse({
      error: "vm_image_config_error",
      status: 503,
      message: "unavailable",
      action: "retry",
      phase: "create",
    });
    const { body } = captured(response);
    expect(body?.event).toBe("cloud_vm_provision");
    expect(body?.distinct_id).toBe("user-1");
    const properties = body?.properties as Record<string, unknown>;
    expect(properties.success).toBe(false);
    expect(properties.status).toBe(503);
    expect(properties.error_code).toBe("vm_image_config_error");
    expect(properties.operator_fault).toBe(true);
    expect(properties.operation).toBe("base_open");
  });

  test("user-fault failures reach PostHog flagged as not operator fault", () => {
    const response = vmErrorResponse({
      error: "vm_billing_team_required",
      status: 409,
      message: "Select a team.",
      action: "Select a team in cmux, then retry.",
      phase: "billing",
    });
    const { body } = captured(response);
    const properties = body?.properties as Record<string, unknown>;
    expect(properties.error_code).toBe("vm_billing_team_required");
    expect(properties.operator_fault).toBe(false);
  });

  test("successes never reach PostHog but still annotate the span", () => {
    const { span, attributes } = fakeSpan();
    const { posthogCalled } = captured(new Response("{}", { status: 200 }), span);
    expect(posthogCalled).toBe(false);
    expect(attributes["cmux.vm.provision_operation"]).toBe("base_open");
    expect(attributes["cmux.vm.provision_success"]).toBe(true);
    expect(attributes["cmux.vm.provision_error_code"]).toBeUndefined();
  });

  test("failures annotate the span with the error code", () => {
    const { span, attributes } = fakeSpan();
    const response = vmErrorResponse({
      error: "vm_create_disabled",
      status: 503,
      message: "disabled",
      action: "enable",
      phase: "create",
    });
    captured(response, span);
    expect(attributes["cmux.vm.provision_success"]).toBe(false);
    expect(attributes["cmux.vm.provision_error_code"]).toBe("vm_create_disabled");
  });

  test("a 5xx without the error header still counts as operator fault", () => {
    const { body } = captured(new Response("boom", { status: 500 }));
    const properties = body?.properties as Record<string, unknown>;
    expect(properties.status).toBe(500);
    expect(properties.error_code).toBeUndefined();
    expect(properties.operator_fault).toBe(true);
  });

  test("fork and restore failures carry their operation", () => {
    for (const operation of ["fork", "restore"] as const) {
      const seen: { body: Record<string, unknown> | null } = { body: null };
      const fakeFetch = ((input: string | URL | Request, init?: RequestInit) => {
        void input;
        seen.body = JSON.parse(String(init?.body)) as Record<string, unknown>;
        return Promise.resolve(new Response("ok"));
      }) as typeof fetch;
      captureVmProvisionOutcome(
        {
          userId: "user-1",
          operation,
          response: vmErrorResponse({
            error: "vm_create_failed",
            status: 500,
            message: "boom",
            action: "retry",
            phase: "create",
          }),
        },
        { fetch: fakeFetch, env: { CMUX_VM_ANALYTICS_FORCE: "1" } },
      );
      const properties = seen.body?.properties as Record<string, unknown>;
      expect(properties.operation).toBe(operation);
      expect(properties.operator_fault).toBe(true);
    }
  });

  test("capture is disabled outside production unless forced", () => {
    let called = false;
    const fakeFetch = (() => {
      called = true;
      return Promise.resolve(new Response("ok"));
    }) as typeof fetch;
    captureVmProvisionOutcome(
      { userId: "user-1", operation: "create", response: vmErrorResponse({
        error: "vm_internal_error",
        status: 500,
        message: "boom",
        action: "retry",
      }) },
      { fetch: fakeFetch, env: {} },
    );
    expect(called).toBe(false);
  });
});

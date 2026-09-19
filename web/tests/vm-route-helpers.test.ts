import { describe, expect, test } from "bun:test";

process.env.RESEND_API_KEY ??= "test-resend-key";
process.env.CMUX_FEEDBACK_FROM_EMAIL ??= "test@example.com";
process.env.CMUX_FEEDBACK_RATE_LIMIT_ID ??= "test-rate-limit";
process.env.STACK_SECRET_SERVER_KEY ??= "ssk_test";
process.env.NEXT_PUBLIC_STACK_PROJECT_ID ??= "00000000-0000-4000-8000-000000000000";
process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY ??= "pck_test";

const { VmCreateDisabledError, VmImageConfigError } = await import("../services/vms/errors");
const { vmWorkflowErrorResponse } = await import("../services/vms/routeHelpers");

describe("VM route helpers", () => {
  test("maps disabled VM creation to an actionable user error", async () => {
    const response = await vmWorkflowErrorResponse(new VmCreateDisabledError({
      provider: "freestyle",
      reason: "CMUX_VM_FREESTYLE_ENABLED=false",
    }));

    expect(response?.status).toBe(503);
    const payload = await response?.json();
    expect(payload).toMatchObject({
      error: "vm_create_disabled",
      message: "Cloud VM creation is disabled for this environment.",
    });
    expect(JSON.stringify(payload)).not.toContain("freestyle");
    expect(payload.reason).toBe("CMUX_VM_FREESTYLE_ENABLED=false");
  });

  test("leaves image config failures for the route-specific mapper", async () => {
    const response = await vmWorkflowErrorResponse(new VmImageConfigError({
      provider: "freestyle",
      image: "internal-snapshot",
      envVar: "CMUX_VM_FREESTYLE_IMAGE",
      source: "default",
      allowedImages: [],
      reason: "missing image manifest",
    }));

    expect(response).toBeNull();
  });
});

import { expect, test } from "bun:test";
import { VmCreateFailedError, VmProviderOperationError } from "../services/vms/errors";
import { ProviderCreateCleanupError } from "../services/vms/drivers/providerCreateCleanup";
import { GuestCliInstallError } from "../services/vms/drivers/freestyleGuestCli";
import { ProviderError } from "../services/vms/drivers/types";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";
import { locales } from "../i18n/routing";

test.each(locales)("cleanup-pending response is localized and never suggests retry (%s)", async (locale) => {
  const original = new VmProviderOperationError({ provider: "freestyle", operation: "create", cause:
    new ProviderCreateCleanupError("private-provider-id", new Error("private guest output"), new Error("private delete output")),
  });
  const retry = new VmCreateFailedError({ idempotencyKey: "synthetic", code: "provider_create_cleanup_pending", message: "private diagnostic" });
  const first = await vmWorkflowErrorResponse(original, { locale });
  const repeated = await vmWorkflowErrorResponse(retry, { locale });
  expect(first?.status).toBe(503);
  expect(first?.headers.has("retry-after")).toBe(false);
  const body = await first!.json();
  expect(body.error).toBe("vm_cloud_create_cleanup_pending");
  expect(body.retryable).toBe(false);
  expect(body.ui.retryable).toBe(false);
  expect(JSON.stringify(body)).not.toContain("private");
  expect(await repeated!.json()).toEqual(body);
  if (locale !== "en") expect(body.message).not.toBe("Cloud VM setup failed and cleanup is still pending.");
});

test.each(locales)("confirmed guest install failures use localized safe guidance for %s", async (locale) => {
  const install = new GuestCliInstallError({ stage: "install", outcome: "guest_exit", exitCode: 7 });
  for (const operation of ["create", "openCmuxRemote"]) {
    const provider = new VmProviderOperationError({
      provider: "freestyle", operation,
      cause: new ProviderError("freestyle", `${operation}(private-machine) failed`, install),
    });
    const response = await vmWorkflowErrorResponse(provider, { locale });
    expect(response?.status).toBe(502);
    const body = await response!.json();
    expect(body.error).toBe("vm_guest_install_failed");
    expect(body.retryable).toBe(true);
    expect(body.phase).toBe(operation === "create" ? "create" : "attach");
    expect(JSON.stringify(body)).not.toContain("private-machine");
    expect(JSON.stringify(body)).not.toContain("guest cmux shim");
    expect(JSON.stringify(body)).not.toContain("guest_exit");
  }
});

test("pending cleanup keeps its non-retryable response when guest install also failed", async () => {
  const install = new GuestCliInstallError({ stage: "publish", outcome: "guest_exit", exitCode: 1 });
  const response = await vmWorkflowErrorResponse(new VmProviderOperationError({
    provider: "freestyle", operation: "create",
    cause: new ProviderCreateCleanupError("private-provider-id", install, new Error("private delete output")),
  }), { locale: "en" });
  expect(response?.status).toBe(503);
  const body = await response!.json();
  expect(body.error).toBe("vm_cloud_create_cleanup_pending");
  expect(body.retryable).toBe(false);
  expect(JSON.stringify(body)).not.toContain("guest_exit");
});

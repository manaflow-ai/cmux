import { expect, test } from "bun:test";
import { VmCreateFailedError, VmProviderOperationError } from "../services/vms/errors";
import { ProviderCreateCleanupError } from "../services/vms/drivers/providerCreateCleanup";
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

import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import { getProvider } from "../services/vms/drivers";
import { VmOperationUnsupportedError, VmProviderOperationError } from "../services/vms/errors";
import { VmProviderGateway, VmProviderGatewayLive } from "../services/vms/providerGateway";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";

describe("provider status safety", () => {
  test("a missing status probe fails instead of reporting running", async () => {
    const driver = getProvider("freestyle");
    const descriptor = Object.getOwnPropertyDescriptor(driver, "getStatus");
    try {
      driver.getStatus = undefined;
      const result = await Effect.runPromise(Effect.gen(function* () {
        const gateway = yield* VmProviderGateway;
        return yield* Effect.either(gateway.getStatus!("freestyle", "vm-status-test"));
      }).pipe(Effect.provide(VmProviderGatewayLive)));
      expect(result._tag).toBe("Left");
      if (result._tag !== "Left") throw new Error("missing probe reported success");
      expect(result.left).toBeInstanceOf(VmProviderOperationError);
      expect(result.left.cause).toBeInstanceOf(VmOperationUnsupportedError);
      const response = await vmWorkflowErrorResponse(result.left);
      expect(response!.status).toBe(501);
    } finally {
      if (descriptor) Object.defineProperty(driver, "getStatus", descriptor);
      else delete driver.getStatus;
    }
  });

  test("status probe failures keep provider messages and codes out of the response", async () => {
    const response = await vmWorkflowErrorResponse(new VmProviderOperationError({
      provider: "freestyle",
      operation: "getStatus",
      cause: { message: "private provider status detail", code: "private_status_code" },
    }));
    expect(response!.status).toBe(502);
    const payload = await response!.json();
    expect(payload).toMatchObject({
      error: "vm_cloud_service_unavailable",
      reason: "Cloud VM service is temporarily unavailable.",
      details: { operation: "getStatus", phase: "status", retryable: true, retryAfterSeconds: 3 },
    });
    expect(payload.details.providerMessage).toBeUndefined();
    expect(payload.details.providerCode).toBeUndefined();
    expect(JSON.stringify(payload)).not.toContain("private");
  });
});

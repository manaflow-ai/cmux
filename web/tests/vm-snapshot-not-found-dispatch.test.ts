import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import {
  isVmSnapshotNotFoundError,
  vmWorkflowErrorCause,
} from "../services/vms/errors";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type VmRepositoryShape } from "../services/vms/repository";
import { vmCreateLikeErrorResponse } from "../services/vms/routeHelpers";
import { restoreVm } from "../services/vms/workflows";

// restoreVm fails on the snapshot ownership check before touching anything else,
// so the repo stub only needs hasOwnedSnapshot.
const repo = {
  hasOwnedSnapshot: () => Effect.succeed(false),
} as unknown as VmRepositoryShape;
const providers = {} as unknown as VmProviderGatewayShape;
const layer = Layer.mergeAll(
  Layer.succeed(VmRepository, repo),
  Layer.succeed(VmProviderGateway, providers),
  Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
);

async function restoreUnknownSnapshot(): Promise<unknown> {
  try {
    await Effect.runPromise(
      restoreVm({
        userId: "user-snapshot-dispatch",
        billingCustomerType: "user",
        billingTeamId: "user-snapshot-dispatch",
        billingPlanId: "pro",
        maxActiveVms: 5,
        provider: "blaxel",
        snapshotId: "snap-missing",
      }).pipe(Effect.provide(layer)),
    );
  } catch (err) {
    return err;
  }
  throw new Error("restoreVm must fail for an unknown snapshot");
}

describe("snapshot-not-found error dispatch", () => {
  // Regression: VmSnapshotNotFoundError is part of the VmWorkflowError union but was
  // missing from the tag list vmWorkflowErrorCause dispatches on, so runVmWorkflow
  // rethrew the raw FiberFailure and restore-of-unknown-snapshot surfaced as a
  // generic 500 vm_internal_error instead of 404 vm_snapshot_not_found.
  test("vmWorkflowErrorCause unwraps VmSnapshotNotFoundError from an Effect failure", async () => {
    const thrown = await restoreUnknownSnapshot();
    const unwrapped = vmWorkflowErrorCause(thrown);
    expect(unwrapped?._tag).toBe("VmSnapshotNotFoundError");
    expect(isVmSnapshotNotFoundError(unwrapped)).toBe(true);
    if (unwrapped && isVmSnapshotNotFoundError(unwrapped)) {
      expect(unwrapped.snapshotId).toBe("snap-missing");
    }
  });

  test("restore of an unknown snapshot maps to 404 vm_snapshot_not_found at the route boundary", async () => {
    const thrown = await restoreUnknownSnapshot();
    // Exactly what runVmWorkflow rethrows to the restore route's catch block.
    const routeError = vmWorkflowErrorCause(thrown) ?? thrown;
    const response = vmCreateLikeErrorResponse(routeError, {
      operation: "restore",
      planId: "pro",
      retryAction: "unused in this test",
    });
    expect(response).not.toBeNull();
    expect(response!.status).toBe(404);
    const payload = await response!.json() as {
      error: string;
      details?: { snapshotId?: string };
    };
    expect(payload.error).toBe("vm_snapshot_not_found");
    expect(payload.details?.snapshotId).toBe("snap-missing");
  });
});

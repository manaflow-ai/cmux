import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { vmCapabilitiesFor, type ProviderId } from "../services/vms/drivers";
import { isVmNotFoundError, vmWorkflowErrorCause } from "../services/vms/errors";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { getVm, listUserVms, reconcileVmProviderStatuses } from "../services/vms/workflows";

// Regression for the Blaxel removal: the driver left with the deploy, but the
// rows it wrote stay in cloud_vms until an operator runs the enum migration.
// The machine list looked every row's driver up in the registry, which throws
// for an id it no longer knows, so one surviving Blaxel row turned GET /api/vm
// into a 500 and the app showed "Cloud is unreachable" for every machine.
const RETIRED_PROVIDER = "blaxel" as ProviderId;
const USER_ID = "user-retired-provider";

function row(overrides: Partial<CloudVmRow>): CloudVmRow {
  const now = new Date("2026-09-01T00:00:00Z");
  return {
    id: "00000000-0000-0000-0000-000000000001",
    userId: USER_ID,
    billingTeamId: USER_ID,
    billingPlanId: "free",
    provider: "freestyle",
    providerVmId: "live-machine",
    displayName: null,
    imageId: "cmux-devbox",
    imageVersion: null,
    status: "running",
    idempotencyKey: null,
    createdAt: now,
    updatedAt: now,
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: {},
    ...overrides,
  };
}

const liveRow = row({});
const retiredRow = row({
  id: "00000000-0000-0000-0000-000000000002",
  provider: RETIRED_PROVIDER,
  providerVmId: "rapid-lynx",
  providerMetadata: { homeVolume: "home-rapid-lynx" },
});

let providerCalls = 0;
const providers = {
  getStatus: () => {
    providerCalls += 1;
    return Effect.die(new Error("provider must not be consulted for a retired row"));
  },
} as unknown as VmProviderGatewayShape;

const repo = {
  listUserVms: () => Effect.succeed([liveRow, retiredRow]),
  findUserVm: (input: { providerVmId: string }) =>
    Effect.succeed(input.providerVmId === retiredRow.providerVmId ? retiredRow : null),
  reconciliationCandidates: () => Effect.succeed([retiredRow]),
  markProviderObservedStatus: () => Effect.die(new Error("retired rows must not be rewritten")),
} as unknown as VmRepositoryShape;

const layer = Layer.mergeAll(
  Layer.succeed(VmRepository, repo),
  Layer.succeed(VmProviderGateway, providers),
  Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
);

describe("rows written by a retired VM provider", () => {
  test("the registry still throws for the retired id, which is what the list must never reach", () => {
    expect(() => vmCapabilitiesFor(RETIRED_PROVIDER)).toThrow(/unknown VM provider: blaxel/);
  });

  test("listUserVms returns the live machines and drops the retired row", async () => {
    const entries = await Effect.runPromise(listUserVms(USER_ID, USER_ID).pipe(Effect.provide(layer)));
    expect(entries.map((entry) => entry.providerVmId)).toEqual([liveRow.providerVmId]);
    expect(providerCalls).toBe(0);
  });

  test("getVm reports a retired row as not found without consulting a provider", async () => {
    let thrown: unknown = null;
    try {
      await Effect.runPromise(
        getVm({ userId: USER_ID, billingTeamId: USER_ID, providerVmId: retiredRow.providerVmId! })
          .pipe(Effect.provide(layer)),
      );
    } catch (err) {
      thrown = err;
    }
    const cause = vmWorkflowErrorCause(thrown);
    expect(isVmNotFoundError(cause)).toBe(true);
    expect(providerCalls).toBe(0);
  });

  test("the status reconcile cron skips retired rows instead of probing a missing driver", async () => {
    const result = await Effect.runPromise(reconcileVmProviderStatuses().pipe(Effect.provide(layer)));
    expect(result).toMatchObject({ checked: 1, skipped: 1, updated: 0, destroyed: 0 });
    expect(providerCalls).toBe(0);
  });
});

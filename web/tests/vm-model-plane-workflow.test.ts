import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import {
  VmBillingGateway,
  noOpVmBillingGateway,
  type VmBillingGatewayShape,
} from "../services/vms/billingGateway";
import type { CreateOptions } from "../services/vms/drivers";
import {
  VM_MODEL_PLANE_FAILURE_CODES,
  VmDatabaseError,
  VmModelPlaneError,
  VmProviderOperationError,
  isVmModelPlaneError,
  vmWorkflowErrorCause,
} from "../services/vms/errors";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { vmCreateLikeErrorResponse, vmWorkflowErrorResponse } from "../services/vms/routeHelpers";
import {
  createVm,
  destroyVm,
  reconcileVmProviderStatuses,
  restoreVm,
  type VmModelPlaneMaterials,
  type VmModelPlaneProvisioner,
} from "../services/vms/workflows";

// The model plane inside the create workflow: provisioning runs after the
// row exists (its id is the token binding) and before the provider call; a
// failure refunds, marks the row, and never reaches the provider; every
// rollback and every machine-ending path revokes the tokens.

const ROW_ID = "00000000-0000-4000-8000-00000000c0de";
const MATERIALS: VmModelPlaneMaterials = {
  envs: { OPENAI_BASE_URL: "https://coderouter.dev/v1", OPENAI_API_KEY: "cmux-vm-edge-placeholder", CMUX_VM_ID: ROW_ID },
  edgeRules: [{ domain: "coderouter.dev", headers: { "x-coderouter-route-token": "crt_t", "x-cmux-vm-id": ROW_ID } }],
};

type UsageEvent = Parameters<VmRepositoryShape["recordUsageEvent"]>[0];
type CreateFailed = Parameters<VmRepositoryShape["markCreateFailed"]>[0];

function row(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  const now = new Date();
  return {
    id: ROW_ID,
    userId: "user-mp",
    billingTeamId: "team-mp",
    billingPlanId: "pro",
    provider: "freestyle",
    providerVmId: null,
    displayName: null,
    imageId: "snapshot-test",
    imageVersion: null,
    status: "provisioning",
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

function fakeRepo(input: {
  readonly vm?: CloudVmRow;
  readonly usageEvents: UsageEvent[];
  readonly failed: CreateFailed[];
  readonly destroyedIds?: string[];
  readonly markCreateRunning?: VmRepositoryShape["markCreateRunning"];
  readonly reconciliationCandidates?: CloudVmRow[];
}): VmRepositoryShape {
  const vm = input.vm ?? row();
  const repo: Partial<VmRepositoryShape> = {
    beginCreate: () => Effect.succeed({ inserted: true, vm }),
    claimBillingGrant: () => Effect.succeed({ kind: "already_claimed" }),
    markBillingGrantApplied: () => Effect.void,
    deleteBillingGrant: () => Effect.void,
    recordUsageEvent: (event) =>
      Effect.sync(() => {
        input.usageEvents.push(event);
      }),
    recordUsageEvents: (events) =>
      Effect.sync(() => {
        input.usageEvents.push(...events);
      }),
    markCreateFailed: (failure) =>
      Effect.sync(() => {
        input.failed.push(failure);
      }),
    markCreateRunning:
      input.markCreateRunning ??
      ((update) => Effect.succeed({ ...vm, status: "running", providerVmId: update.providerVmId, imageId: update.image })),
    findUserVm: ({ userId, providerVmId }) =>
      Effect.succeed(vm.userId === userId && vm.providerVmId === providerVmId ? vm : null),
    hasOwnedSnapshot: () => Effect.succeed(true),
    activeIdentityLeases: () => Effect.succeed([]),
    markLeasesRevoked: () => Effect.void,
    markDestroyed: (id) =>
      Effect.sync(() => {
        input.destroyedIds?.push(id);
      }),
    activeLimitCandidates: () => Effect.succeed([]),
    reconciliationCandidates: () => Effect.succeed(input.reconciliationCandidates ?? []),
    markProviderObservedStatus: () => Effect.succeed(true),
  };
  return repo as VmRepositoryShape;
}

function fakeProviders(input: {
  readonly creates: CreateOptions[];
  readonly createFails?: boolean;
  readonly destroyed?: string[];
  readonly status?: "running" | "gone";
}): VmProviderGatewayShape {
  return {
    create: (_provider, options) => {
      input.creates.push(options);
      return input.createFails
        ? Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation: "create", cause: new Error("boom") }))
        : Effect.succeed({
          provider: "freestyle" as const,
          providerVmId: "provider-vm-mp",
          status: "running" as const,
          image: "snapshot-test",
          createdAt: Date.now(),
        });
    },
    destroy: (_provider, vmId) =>
      Effect.sync(() => {
        input.destroyed?.push(vmId);
      }),
    getStatus: () =>
      input.status === "gone"
        ? Effect.fail(new VmProviderOperationError({
          provider: "freestyle",
          operation: "getStatus",
          cause: Object.assign(new Error("not found"), { status: 404, code: "NOT_FOUND" }),
        }))
        : Effect.succeed("running" as const),
    exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
    openAttach: () => Effect.fail(new Error("unused") as never),
    openSSH: () => Effect.fail(new Error("unused") as never),
    revokeSSHIdentity: () => Effect.void,
  };
}

function fakeModelPlane(input: {
  readonly provisioned: string[];
  readonly revoked: string[];
  readonly fail?: VmModelPlaneError | Error;
}): VmModelPlaneProvisioner {
  return {
    provision: async (cloudVmId) => {
      input.provisioned.push(cloudVmId);
      if (input.fail) throw input.fail;
      return MATERIALS;
    },
    revoke: async (cloudVmId) => {
      input.revoked.push(cloudVmId);
    },
  };
}

function billingWithRefunds(refunds: unknown[]): VmBillingGatewayShape {
  return {
    ...noOpVmBillingGateway(),
    reserveCreate: () => Effect.succeed({ kind: "reserved", itemId: "item", customerType: "team", customerId: "team-mp", amount: 1 } as never),
    refundCreate: (reservation) =>
      Effect.sync(() => {
        refunds.push(reservation);
      }),
  };
}

function layer(repo: VmRepositoryShape, providers: VmProviderGatewayShape, billing = noOpVmBillingGateway()) {
  return Layer.mergeAll(
    Layer.succeed(VmRepository, repo),
    Layer.succeed(VmProviderGateway, providers),
    Layer.succeed(VmBillingGateway, billing),
  );
}

const createInput = {
  userId: "user-mp",
  billingCustomerType: "team" as const,
  billingTeamId: "team-mp",
  billingPlanId: "pro",
  maxActiveVms: null,
  provider: "freestyle" as const,
  image: "snapshot-test",
};

describe("createVm model plane", () => {
  test("provisions with the row id after the row exists and hands env plus edge rules to the provider", async () => {
    const usageEvents: UsageEvent[] = [];
    const creates: CreateOptions[] = [];
    const order: string[] = [];
    const provisioned: string[] = [];
    const revoked: string[] = [];
    const modelPlane: VmModelPlaneProvisioner = {
      provision: async (cloudVmId) => {
        order.push("provision");
        provisioned.push(cloudVmId);
        return MATERIALS;
      },
      revoke: async (cloudVmId) => {
        revoked.push(cloudVmId);
      },
    };
    const providers: VmProviderGatewayShape = {
      ...fakeProviders({ creates }),
      create: (provider, options) => {
        order.push("provider_create");
        return fakeProviders({ creates }).create(provider, options);
      },
    };
    const created = await Effect.runPromise(
      createVm({ ...createInput, modelPlane }).pipe(
        Effect.provide(layer(fakeRepo({ usageEvents, failed: [] }), providers)),
      ),
    );
    expect(created.providerVmId).toBe("provider-vm-mp");
    expect(provisioned).toEqual([ROW_ID]);
    expect(order).toEqual(["provision", "provider_create"]);
    expect(creates).toHaveLength(1);
    expect(creates[0]?.envs).toEqual(MATERIALS.envs);
    expect(creates[0]?.edgeRules).toEqual(MATERIALS.edgeRules);
    expect(revoked).toEqual([]);
  });

  test("without a provisioner (kill switch) the provider gets neither env nor rules", async () => {
    const creates: CreateOptions[] = [];
    await Effect.runPromise(
      createVm(createInput).pipe(Effect.provide(layer(fakeRepo({ usageEvents: [], failed: [] }), fakeProviders({ creates })))),
    );
    expect(creates[0]?.envs).toBeUndefined();
    expect(creates[0]?.edgeRules).toBeUndefined();
  });

  test("an unavailable failure refunds, marks the row, records the event, and never calls the provider", async () => {
    const kind = "unavailable" as const;
    const code = VM_MODEL_PLANE_FAILURE_CODES[kind];
    const usageEvents: UsageEvent[] = [];
    const failed: CreateFailed[] = [];
    const creates: CreateOptions[] = [];
    const refunds: unknown[] = [];
    const revoked: string[] = [];
    const modelPlane = fakeModelPlane({
      provisioned: [],
      revoked,
      fail: new VmModelPlaneError({ kind, cause: new Error(`coderouter ${kind}`) }),
    });
    const failure = await Effect.runPromise(
      createVm({ ...createInput, modelPlane }).pipe(
        Effect.flip,
        Effect.provide(layer(fakeRepo({ usageEvents, failed }), fakeProviders({ creates }), billingWithRefunds(refunds))),
      ),
    );
    expect(isVmModelPlaneError(failure)).toBe(true);
    expect((failure as VmModelPlaneError).kind).toBe(kind);
    expect(creates).toEqual([]);
    expect(refunds).toHaveLength(1);
    expect(failed).toEqual([{ id: ROW_ID, code, message: `coderouter ${kind}` }]);
    const failedEvent = usageEvents.find((event) => event.eventType === "vm.create.failed");
    expect(failedEvent?.metadata).toEqual({ operation: "model_plane_provision", kind, message: `coderouter ${kind}` });
    expect(revoked).toEqual([]);
  });

  test("an untyped provisioner rejection is treated as coderouter unavailable", async () => {
    const failed: CreateFailed[] = [];
    const modelPlane = fakeModelPlane({ provisioned: [], revoked: [], fail: new Error("socket hang up") });
    const failure = await Effect.runPromise(
      createVm({ ...createInput, modelPlane }).pipe(
        Effect.flip,
        Effect.provide(layer(fakeRepo({ usageEvents: [], failed }), fakeProviders({ creates: [] }))),
      ),
    );
    expect(isVmModelPlaneError(failure) && failure.kind).toBe("unavailable");
    expect(failed[0]?.code).toBe(VM_MODEL_PLANE_FAILURE_CODES.unavailable);
  });

  test("revokes the token when the provider create fails", async () => {
    const revoked: string[] = [];
    const refunds: unknown[] = [];
    const modelPlane = fakeModelPlane({ provisioned: [], revoked });
    const failure = await Effect.runPromise(
      createVm({ ...createInput, modelPlane }).pipe(
        Effect.flip,
        Effect.provide(layer(
          fakeRepo({ usageEvents: [], failed: [] }),
          fakeProviders({ creates: [], createFails: true }),
          billingWithRefunds(refunds),
        )),
      ),
    );
    expect(failure).toBeInstanceOf(VmProviderOperationError);
    expect(revoked).toEqual([ROW_ID]);
    expect(refunds).toHaveLength(1);
  });

  test("revokes the token and destroys the machine when the running write fails", async () => {
    const revoked: string[] = [];
    const destroyed: string[] = [];
    const modelPlane = fakeModelPlane({ provisioned: [], revoked });
    const failure = await Effect.runPromise(
      createVm({ ...createInput, modelPlane }).pipe(
        Effect.flip,
        Effect.provide(layer(
          fakeRepo({
            usageEvents: [],
            failed: [],
            markCreateRunning: () => Effect.fail(new VmDatabaseError({ operation: "markCreateRunning", cause: new Error("db") })),
          }),
          fakeProviders({ creates: [], destroyed }),
        )),
      ),
    );
    expect(failure).toBeInstanceOf(VmDatabaseError);
    expect(destroyed).toEqual(["provider-vm-mp"]);
    expect(revoked).toEqual([ROW_ID]);
  });

  test("a failing revoke never fails the rollback path", async () => {
    const modelPlane: VmModelPlaneProvisioner = {
      provision: async () => MATERIALS,
      revoke: async () => {
        throw new Error("coderouter down");
      },
    };
    const failure = await Effect.runPromise(
      createVm({ ...createInput, modelPlane }).pipe(
        Effect.flip,
        Effect.provide(layer(fakeRepo({ usageEvents: [], failed: [] }), fakeProviders({ creates: [], createFails: true }))),
      ),
    );
    expect(failure).toBeInstanceOf(VmProviderOperationError);
  });
});

describe("restoreVm model plane", () => {
  test("threads the provisioner through to the create", async () => {
    const creates: CreateOptions[] = [];
    const provisioned: string[] = [];
    const modelPlane = fakeModelPlane({ provisioned, revoked: [] });
    await Effect.runPromise(
      restoreVm({ ...createInput, snapshotId: "snap-1", modelPlane }).pipe(
        Effect.provide(layer(fakeRepo({ usageEvents: [], failed: [] }), fakeProviders({ creates }))),
      ),
    );
    expect(provisioned).toEqual([ROW_ID]);
    expect(creates[0]?.image).toBe("snap-1");
    expect(creates[0]?.edgeRules).toEqual(MATERIALS.edgeRules);
  });
});

describe("token revocation on machine end", () => {
  test("destroyVm revokes after the provider destroy and before finalizing the row", async () => {
    const order: string[] = [];
    const destroyedIds: string[] = [];
    const vm = row({ status: "running", providerVmId: "provider-vm-mp" });
    const providers: VmProviderGatewayShape = {
      ...fakeProviders({ creates: [] }),
      destroy: () =>
        Effect.sync(() => {
          order.push("provider_destroy");
        }),
    };
    const repo = fakeRepo({
      vm,
      usageEvents: [],
      failed: [],
      destroyedIds,
    });
    const modelPlane = {
      revoke: async (cloudVmId: string) => {
        order.push(`revoke:${cloudVmId}`);
      },
    };
    await Effect.runPromise(
      destroyVm({ userId: "user-mp", teamIds: ["team-mp"], providerVmId: "provider-vm-mp", modelPlane }).pipe(
        Effect.provide(layer({
          ...repo,
          markDestroyed: (id) =>
            Effect.sync(() => {
              order.push("mark_destroyed");
              destroyedIds.push(id);
            }),
        }, providers)),
      ),
    );
    expect(order).toEqual(["provider_destroy", `revoke:${ROW_ID}`, "mark_destroyed"]);
    expect(destroyedIds).toEqual([ROW_ID]);
  });

  test("destroyVm still finalizes when the revoke fails", async () => {
    const destroyedIds: string[] = [];
    const vm = row({ status: "running", providerVmId: "provider-vm-mp" });
    await Effect.runPromise(
      destroyVm({
        userId: "user-mp",
        teamIds: ["team-mp"],
        providerVmId: "provider-vm-mp",
        modelPlane: {
          revoke: async () => {
            throw new Error("coderouter down");
          },
        },
      }).pipe(Effect.provide(layer(fakeRepo({ vm, usageEvents: [], failed: [], destroyedIds }), fakeProviders({ creates: [] })))),
    );
    expect(destroyedIds).toEqual([ROW_ID]);
  });

  test("the status reconcile revokes tokens for machines the provider reports gone", async () => {
    const revoked: string[] = [];
    const gone = row({ status: "running", providerVmId: "provider-vm-mp" });
    const result = await Effect.runPromise(
      reconcileVmProviderStatuses({ modelPlane: { revoke: async (id) => { revoked.push(id); } } }).pipe(
        Effect.provide(layer(
          fakeRepo({ vm: gone, usageEvents: [], failed: [], reconciliationCandidates: [gone] }),
          fakeProviders({ creates: [], status: "gone" }),
        )),
      ),
    );
    expect(result.destroyed).toBe(1);
    expect(revoked).toEqual([ROW_ID]);
  });
});

describe("model-plane error responses", () => {
  test("unavailable maps to a retryable 503 for create and restore", async () => {
    const err = new VmModelPlaneError({ kind: "unavailable", cause: new Error("db down") });
    const create = await vmWorkflowErrorResponse(err);
    expect(create?.status).toBe(503);
    expect(create?.headers.get("retry-after")).toBe("30");
    const createPayload = await create!.json();
    expect(createPayload).toMatchObject({
      error: "vm_model_plane_unavailable",
      phase: "create",
      retryable: true,
      action: "coderouter is unavailable; retry in a minute. If it keeps failing, contact support.",
    });
    expect(JSON.stringify(createPayload)).not.toContain("db down");

    const restore = vmCreateLikeErrorResponse(err, { operation: "restore", planId: "pro", retryAction: "unused" });
    expect(restore?.status).toBe(503);
    expect(await restore!.json()).toMatchObject({ error: "vm_model_plane_unavailable", phase: "restore" });
  });

  test("the workflow error unwraps from an Effect failure like every other tag", () => {
    const err = new VmModelPlaneError({ kind: "unavailable", cause: new Error("x") });
    expect(vmWorkflowErrorCause(err)?._tag).toBe("VmModelPlaneError");
  });
});

import { beforeEach, describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Layer from "effect/Layer";
import { createVm } from "../services/vms/workflows";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { ProviderNetworkFullError } from "../services/vms/drivers/types";
import { VmCreateWaitingError, VmProviderOperationError } from "../services/vms/errors";
import { vmWorkflowErrorResponse } from "../services/vms/routeHelpers";
import { resetFleetAdmissionForTest } from "../services/vms/fleetAdmission";
import {
  VM_CREATE_WAIT_EXPIRED_FAILURE_CODE,
  VM_CREATE_WAIT_MAX_MS,
  createWaitFromMetadata,
  createWaitStateForCause,
  isCreateWaitExpired,
  nextCreateWait,
  type VmCreateWait,
} from "../services/vms/createWait";

const network = {
  id: "00000000-0000-4000-8000-000000000002",
  userId: "user-1",
  provider: "freestyle" as const,
  providerNetworkId: "vpc-personal",
  slug: "cmux-net-personal",
  cidr: "10.30.0.0/24",
  cidrV6: "fd30::/64",
  createdAt: new Date(),
  updatedAt: new Date(),
};

function row(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  return {
    id: "00000000-0000-4000-8000-000000000010",
    userId: "user-1",
    ownerTeamId: "team-1",
    coderouterPoolId: null,
    billingTeamId: "team-1",
    billingPlanId: "free",
    provider: "freestyle",
    providerVmId: null,
    displayName: null,
    slug: "test-vm",
    imageId: "image",
    imageVersion: null,
    status: "provisioning",
    idempotencyKey: "key-1",
    createdAt: new Date(),
    updatedAt: new Date(),
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: {},
    networkPolicy: null,
    networkPolicyStatus: null,
    agentUpdates: null,
    ...overrides,
  } as CloudVmRow;
}

type Harness = {
  readonly recorded: Array<{ id: string; wait: VmCreateWait }>;
  readonly creates: number[];
  readonly repo: VmRepositoryShape;
  readonly gateway: VmProviderGatewayShape;
};

function harness(options: { holders?: number; previous?: CloudVmRow | null; createFails?: unknown } = {}): Harness {
  const recorded: Array<{ id: string; wait: VmCreateWait }> = [];
  const creates: number[] = [];
  const vm = row();
  const repo = {
    findCreateByIdempotencyKey: () => Effect.succeed(options.previous ?? null),
    beginCreate: () => Effect.succeed({ inserted: true, vm }),
    markCreateRunning: (input: { providerVmId: string }) => Effect.succeed({ ...vm, status: "running", providerVmId: input.providerVmId }),
    markCreateFailed: () => Effect.succeed(true),
    recordCreateWait: (input: { id: string; wait: VmCreateWait }) => Effect.sync(() => { recorded.push(input); return true; }),
    countNetworkAddressHolders: () => Effect.succeed(options.holders ?? 0),
    recordUsageEvents: () => Effect.void,
    recordUsageEvent: () => Effect.void,
    findNetwork: () => Effect.succeed(network),
    upsertNetwork: () => Effect.succeed(network),
  } as unknown as VmRepositoryShape;
  const gateway = {
    create: (_provider: string, opts: { image: string }) => Effect.suspend(() => {
      creates.push(Date.now());
      if (options.createFails) return Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation: "create", cause: options.createFails }));
      return Effect.succeed({ provider: "freestyle", providerVmId: "provider-vm-1", status: "running", image: opts.image, createdAt: Date.now() });
    }),
    destroy: () => Effect.void,
    supportsPrivateNetworking: () => true,
    getNetwork: () => Effect.succeed(null),
    ensureNetwork: () => Effect.succeed({ id: network.providerNetworkId, slug: network.slug, cidr: network.cidr, cidrV6: network.cidrV6 }),
    listNetworkTunnelIds: () => Effect.succeed([]),
  } as unknown as VmProviderGatewayShape;
  return { recorded, creates, repo, gateway };
}

const baseInput = {
  userId: "user-1",
  billingCustomerType: "user" as const,
  billingTeamId: "team-1",
  billingPlanId: "free",
  maxActiveVms: 2,
  provider: "freestyle" as const,
  image: "image",
  idempotencyKey: "key-1",
};

function run(h: Harness, extra: Record<string, unknown> = {}) {
  return Effect.runPromiseExit(createVm({ ...baseInput, ...extra } as never).pipe(Effect.provide(Layer.mergeAll(
    Layer.succeed(VmRepository, h.repo),
    Layer.succeed(VmProviderGateway, h.gateway),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  ))));
}

function failure(exit: Exit.Exit<unknown, unknown>): unknown {
  if (Exit.isSuccess(exit)) throw new Error("expected a failure");
  const reason = exit.cause;
  return (reason as { error?: unknown }).error ?? reason;
}

const placementRejected = Object.assign(new Error("no manager has enough capacity for vm"), { status: 409, code: "PLACEMENT_REJECTED" });

// Fleet admission keeps a per-process provider cooldown; one test's refusal must not refuse the next.
beforeEach(() => resetFleetAdmissionForTest());

describe("createWait helpers", () => {
  test("a full network waits for an address, a placement refusal for capacity, anything else fails", () => {
    expect(createWaitStateForCause(new ProviderNetworkFullError("freestyle", "full"))).toBe("waiting_for_address");
    expect(createWaitStateForCause({ cause: new ProviderNetworkFullError("freestyle", "full") })).toBe("waiting_for_address");
    expect(createWaitStateForCause(placementRejected)).toBe("waiting_for_capacity");
    expect(createWaitStateForCause(Object.assign(new Error("is still starting"), { status: 409 }))).toBeNull();
    expect(createWaitStateForCause(new Error("boom"))).toBeNull();
  });

  test("a retry keeps the first deadline; the bound is ten minutes", () => {
    const first = nextCreateWait("waiting_for_address", null, 1_000);
    expect(first).toEqual({ state: "waiting_for_address", since: 1_000, deadline: 1_000 + VM_CREATE_WAIT_MAX_MS });
    const later = nextCreateWait("waiting_for_capacity", first, 400_000);
    expect(later).toEqual({ state: "waiting_for_capacity", since: 1_000, deadline: first.deadline });
    expect(isCreateWaitExpired(first, first.deadline - 1)).toBe(false);
    expect(isCreateWaitExpired(first, first.deadline)).toBe(true);
    expect(createWaitFromMetadata({ createWait: first })).toEqual(first);
    expect(createWaitFromMetadata({ createWait: { state: "nope", since: 1, deadline: 2 } })).toBeNull();
  });
});

describe("createVm wait state", () => {
  test("an opted-in create on a full network records waiting_for_address and answers 202", async () => {
    const h = harness({ holders: 10_000 });
    const err = failure(await run(h, { waitForCapacity: true }));
    expect(err).toBeInstanceOf(VmCreateWaitingError);
    expect((err as VmCreateWaitingError).state).toBe("waiting_for_address");
    expect(h.recorded).toHaveLength(1);
    expect(h.recorded[0]?.wait.deadline - h.recorded[0]!.wait.since).toBe(VM_CREATE_WAIT_MAX_MS);
    expect(h.creates).toHaveLength(0);
    const response = (await vmWorkflowErrorResponse(err as VmCreateWaitingError))!;
    expect(response.status).toBe(202);
    expect(response.headers.get("retry-after")).toBe("15");
    const body = await response.json() as Record<string, unknown>;
    expect(body).toMatchObject({ error: "vm_create_waiting", waitState: "waiting_for_address", retryable: true });
  });

  test("without the opt-in the full network still fails as vm_network_full", async () => {
    const h = harness({ holders: 10_000 });
    const err = failure(await run(h));
    expect(err).toBeInstanceOf(VmProviderOperationError);
    expect(h.recorded).toHaveLength(0);
    const response = (await vmWorkflowErrorResponse(err as VmProviderOperationError))!;
    expect(response.status).toBe(409);
    expect(((await response.json()) as { error: string }).error).toBe("vm_network_full");
  });

  test("a provider start-capacity refusal waits for capacity", async () => {
    const h = harness({ createFails: placementRejected });
    const err = failure(await run(h, { waitForCapacity: true }));
    expect(err).toBeInstanceOf(VmCreateWaitingError);
    expect((err as VmCreateWaitingError).state).toBe("waiting_for_capacity");
    expect(h.creates).toHaveLength(1);
  });

  test("the same-key retry starts the machine once an address frees, under the first deadline", async () => {
    const since = Date.now() - 60_000;
    const previous = row({ status: "failed", failureCode: "provider_create_unavailable", providerMetadata: { createWait: { state: "waiting_for_address", since, deadline: since + VM_CREATE_WAIT_MAX_MS } } });
    const full = harness({ holders: 10_000, previous });
    const again = failure(await run(full, { waitForCapacity: true })) as VmCreateWaitingError;
    expect(again.since).toBe(since);
    expect(again.deadline).toBe(since + VM_CREATE_WAIT_MAX_MS);
    const free = harness({ previous });
    const exit = await run(free, { waitForCapacity: true });
    expect(Exit.isSuccess(exit)).toBe(true);
    expect(free.creates).toHaveLength(1);
  });

  test("a retry past the deadline fails terminally with vm_create_wait_expired", async () => {
    const since = Date.now() - VM_CREATE_WAIT_MAX_MS - 1_000;
    const previous = row({ status: "failed", failureCode: "provider_create_unavailable", providerMetadata: { createWait: { state: "waiting_for_capacity", since, deadline: since + VM_CREATE_WAIT_MAX_MS } } });
    const h = harness({ previous });
    const err = failure(await run(h, { waitForCapacity: true })) as { _tag: string; code: string };
    expect(err._tag).toBe("VmCreateFailedError");
    expect(err.code).toBe(VM_CREATE_WAIT_EXPIRED_FAILURE_CODE);
    expect(h.creates).toHaveLength(0);
  });
});

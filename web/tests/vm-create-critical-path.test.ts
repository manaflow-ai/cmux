import { describe, expect, test } from "bun:test";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { VmProviderOperationError } from "../services/vms/errors";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { createVm } from "../services/vms/workflows";

// New Machine's create latency: ledger writes that do not gate the machine
// must not sit in front of the provider call or the response, and moving
// them must not reorder or drop ledger rows.

const ROW_ID = "00000000-0000-4000-8000-00000000fa57";
type UsageEvent = Parameters<VmRepositoryShape["recordUsageEvent"]>[0];

function row(): CloudVmRow {
  const now = new Date();
  return {
    id: ROW_ID,
    userId: "user-fast",
    billingTeamId: "team-fast",
    billingPlanId: "pro",
    provider: "freestyle",
    providerVmId: null,
    displayName: null,
    slug: null,
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
    networkPolicy: null,
    networkPolicyStatus: null,
    ownerTeamId: "team-fast",
    coderouterPoolId: null,
  };
}

function fakeRepo(input: {
  readonly events: UsageEvent[];
  readonly writeGate?: (events: readonly UsageEvent[]) => Effect.Effect<void>;
}): VmRepositoryShape {
  const vm = row();
  const now = new Date();
  const record = (events: readonly UsageEvent[]) =>
    (input.writeGate?.(events) ?? Effect.void).pipe(Effect.andThen(Effect.sync(() => {
      input.events.push(...events);
    })));
  return {
    beginCreate: () => Effect.succeed({ inserted: true, vm }),
    claimBillingGrant: () => Effect.succeed({ kind: "already_claimed" }),
    recordUsageEvent: (event: UsageEvent) => record([event]),
    recordUsageEvents: (events: readonly UsageEvent[]) => record(events),
    markCreateFailed: () => Effect.void,
    markCreateRunning: (update: { providerVmId: string; image: string }) =>
      Effect.succeed({ ...vm, status: "running", providerVmId: update.providerVmId, imageId: update.image }),
    activeLimitCandidates: () => Effect.succeed([]),
    findNetwork: () => Effect.succeed({
      id: "00000000-0000-4000-8000-00000000c10d",
      userId: vm.userId,
      provider: "freestyle",
      providerNetworkId: "network-fast",
      slug: "fast",
      cidr: null,
      cidrV6: null,
      createdAt: now,
      updatedAt: now,
    }),
    upsertNetwork: () => Effect.die("the owner network already exists"),
  } as unknown as VmRepositoryShape;
}

function fakeProviders(input: {
  readonly onCreate?: () => Effect.Effect<void>;
  readonly fail?: boolean;
  readonly execs?: string[];
}): VmProviderGatewayShape {
  return {
    exec: (_provider: string, _vmId: string, command: string) => Effect.sync(() => {
      input.execs?.push(command);
      return { exitCode: 0, stdout: "", stderr: "" };
    }),
    create: () =>
      (input.onCreate?.() ?? Effect.void).pipe(Effect.andThen(input.fail
        ? Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation: "create", cause: new Error("boom") }))
        : Effect.succeed({
          provider: "freestyle" as const,
          providerVmId: "provider-vm-fast",
          status: "running" as const,
          image: "snapshot-test",
          createdAt: Date.now(),
        }))),
    destroy: () => Effect.void,
    supportsPrivateNetworking: () => true,
    ensureNetwork: () => Effect.die("the owner network already exists"),
  } as unknown as VmProviderGatewayShape;
}

function layer(repo: VmRepositoryShape, providers: VmProviderGatewayShape) {
  return Layer.mergeAll(
    Layer.succeed(VmRepository, repo),
    Layer.succeed(VmProviderGateway, providers),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
}

const createInput = {
  userId: "user-fast",
  billingCustomerType: "team" as const,
  billingTeamId: "team-fast",
  billingPlanId: "pro",
  maxActiveVms: null,
  provider: "freestyle" as const,
  image: "snapshot-test",
};

const types = (events: readonly UsageEvent[]) => events.map((event) => event.eventType);

describe("createVm critical path", () => {
  test("the provider call starts while the requested-events write is still in flight, and create waits for it", async () => {
    const events: UsageEvent[] = [];
    const program = Effect.gen(function* () {
      const releaseRequested = yield* Deferred.make<void>();
      const providerStarted = yield* Deferred.make<void>();
      const repo = fakeRepo({
        events,
        writeGate: (batch) => batch.some((event) => event.eventType === "vm.create.requested")
          ? Deferred.await(releaseRequested)
          : Effect.void,
      });
      const providers = fakeProviders({ onCreate: () => Deferred.succeed(providerStarted, undefined) });
      const fiber = yield* Effect.fork(createVm(createInput).pipe(Effect.provide(layer(repo, providers))));
      // Deadlocks (and times out) if the provider call still waits on the write.
      yield* Deferred.await(providerStarted);
      expect(types(events)).toEqual([]);
      yield* Deferred.succeed(releaseRequested, undefined);
      return yield* fiber.await;
    });
    const exit = await Effect.runPromise(program);
    expect(exit._tag).toBe("Success");
    expect(types(events)).toEqual(["vm.create.requested", "vm.created"]);
  });

  test("with an after-response hook, vm.created is written after create returns", async () => {
    const events: UsageEvent[] = [];
    const deferred: Effect.Effect<void>[] = [];
    const created = await Effect.runPromise(
      createVm({ ...createInput, deferAfterResponse: (work) => deferred.push(work) }).pipe(
        Effect.provide(layer(fakeRepo({ events }), fakeProviders({}))),
      ),
    );
    expect(created.providerVmId).toBe("provider-vm-fast");
    expect(types(events)).toEqual(["vm.create.requested"]);
    // vm.created and the prompt name push both run after the response.
    expect(deferred).toHaveLength(2);
    for (const work of deferred) await Effect.runPromise(work);
    expect(types(events)).toEqual(["vm.create.requested", "vm.created"]);
  });

  test("the prompt name is pushed into the guest only after the response", async () => {
    const execs: string[] = [];
    const deferred: Effect.Effect<void>[] = [];
    await Effect.runPromise(
      createVm({ ...createInput, deferAfterResponse: (work) => deferred.push(work) }).pipe(
        Effect.provide(layer(fakeRepo({ events: [] }), fakeProviders({ execs }))),
      ),
    );
    // Nothing runs in the guest before create returns.
    expect(execs).toEqual([]);
    for (const work of deferred) await Effect.runPromise(work);
    expect(execs).toHaveLength(1);
    expect(execs[0]).toContain("vm-name");
  });

  test("a provider failure records its failure row after the requested row", async () => {
    const events: UsageEvent[] = [];
    const deferred: Effect.Effect<void>[] = [];
    const program = Effect.gen(function* () {
      const releaseRequested = yield* Deferred.make<void>();
      const repo = fakeRepo({
        events,
        writeGate: (batch) => batch.some((event) => event.eventType === "vm.create.requested")
          ? Deferred.await(releaseRequested)
          : Effect.void,
      });
      // The provider fails while the requested write is still held open.
      const providers = fakeProviders({ fail: true, onCreate: () => Effect.fork(Effect.sleep("20 millis").pipe(Effect.andThen(Deferred.succeed(releaseRequested, undefined)))).pipe(Effect.asVoid) });
      return yield* createVm({ ...createInput, deferAfterResponse: (work) => deferred.push(work) }).pipe(
        Effect.provide(layer(repo, providers)),
        Effect.flip,
      );
    });
    const error = await Effect.runPromise(program);
    expect(error).toBeInstanceOf(VmProviderOperationError);
    expect(types(events)).toEqual(["vm.create.requested", "vm.create.failed"]);
    expect(deferred).toHaveLength(0);
  });
});

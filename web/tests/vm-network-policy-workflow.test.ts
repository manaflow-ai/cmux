import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Layer from "effect/Layer";

import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { VmOperationUnsupportedError, VmProviderOperationError } from "../services/vms/errors";
import { parseNetworkPolicy, type NetworkRulePlan } from "../services/vms/networkPolicy";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { createVm, getVmNetworkPolicy, updateVmNetworkPolicy } from "../services/vms/workflows";

const NOW = new Date("2026-01-01T00:00:00.000Z");

function row(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  return {
    id: "00000000-0000-4000-8000-000000000301",
    userId: "user-net",
    billingTeamId: "team-net",
    billingPlanId: "pro",
    provider: "freestyle",
    providerVmId: "vm-net",
    displayName: null,
    slug: null,
    imageId: "snapshot-test",
    imageVersion: null,
    status: "running",
    idempotencyKey: null,
    createdAt: NOW,
    updatedAt: NOW,
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: {},
    networkPolicy: null,
    networkPolicyStatus: null,
    ownerTeamId: "team-net",
    coderouterPoolId: null,
    ...overrides,
  };
}

type Write = { id: string; policy?: Record<string, unknown>; status?: Record<string, unknown> };

function harness(options: { vm?: CloudVmRow; apply?: (plan: NetworkRulePlan) => Effect.Effect<void, VmProviderOperationError>; supportsApply?: boolean } = {}) {
  const writes: Write[] = [];
  const created: Array<{ networkRules?: NetworkRulePlan }> = [];
  const applied: NetworkRulePlan[] = [];
  const vm = options.vm ?? row();
  const repo = {
    findUserVm: () => Effect.succeed(vm),
    setNetworkPolicy: (input: Write) => Effect.sync(() => { writes.push(input); }),
    beginCreate: () => Effect.succeed({ inserted: true, vm: row({ status: "provisioning", providerVmId: null }) }),
    legacyResourceReservationCandidates: () => Effect.succeed([]),
    claimBillingGrant: () => Effect.succeed({ kind: "already_claimed" as const }),
    markBillingGrantApplied: () => Effect.void,
    deleteBillingGrant: () => Effect.void,
    markCreateRunning: () => Effect.succeed(row()),
    markCreateFailed: () => Effect.void,
    recordUsageEvent: () => Effect.void,
    recordUsageEvents: () => Effect.void,
    findNetwork: () => Effect.succeed(null),
    upsertNetwork: () => Effect.succeed({
      id: "network-row", userId: "user-net", provider: "freestyle" as const, providerNetworkId: "network-1",
      slug: "cmux-net", cidr: "10.0.0.0/24", cidrV6: "fd00::/64", createdAt: NOW, updatedAt: NOW,
    }),
  } as unknown as VmRepositoryShape;
  const providers = {
    create: (_provider: string, createOptions: { networkRules?: NetworkRulePlan }) => Effect.sync(() => {
      created.push(createOptions);
      return { provider: "freestyle" as const, providerVmId: "vm-net", status: "running" as const, image: "snapshot-test", createdAt: NOW.getTime() };
    }),
    destroy: () => Effect.void,
    exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
    supportsPrivateNetworking: () => true,
    ensureNetwork: () => Effect.succeed({ id: "network-1", slug: "cmux-net", cidr: "10.0.0.0/24", cidrV6: "fd00::/64" }),
    ...(options.supportsApply === false ? {} : {
      applyNetworkPolicy: (_provider: string, _vmId: string, plan: NetworkRulePlan) =>
        (options.apply?.(plan) ?? Effect.void).pipe(Effect.tap(() => Effect.sync(() => { applied.push(plan); }))),
    }),
  } as unknown as VmProviderGatewayShape;
  const layer = Layer.mergeAll(
    Layer.succeed(VmRepository, repo),
    Layer.succeed(VmProviderGateway, providers),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
  return { layer, writes, created, applied };
}

const access = { userId: "user-net", billingTeamId: "team-net", teamIds: ["team-net"], providerVmId: "vm-net", callerPlanId: "pro" };
const allowlist = parseNetworkPolicy({ mode: "allowlist", presets: ["openrouter"], ranges: ["1.1.1.1"] });

describe("network policy workflows", () => {
  test("legacy rows read as full and applied", async () => {
    const { layer } = harness();
    const view = await Effect.runPromise(getVmNetworkPolicy(access).pipe(Effect.provide(layer)));
    expect(view.policy.mode).toBe("full");
    expect(view.status.state).toBe("applied");
  });

  test("update stores intent before applying, then records applied", async () => {
    const { layer, writes, applied } = harness();
    const view = await Effect.runPromise(updateVmNetworkPolicy({ ...access, policy: allowlist }).pipe(Effect.provide(layer)));
    expect(writes[0]).toMatchObject({ policy: { mode: "allowlist" }, status: { state: "pending" } });
    expect(writes[1]?.status).toMatchObject({ state: "applied" });
    expect(applied[0]?.publicEgress).toBe(false);
    expect(applied[0]?.domains).toContain("openrouter.ai");
    expect(view.status.state).toBe("applied");
  });

  test("a provider failure keeps the stored policy and records the error", async () => {
    const { layer, writes } = harness({
      apply: () => Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation: "applyNetworkPolicy", cause: new Error("edge down") })),
    });
    const exit = await Effect.runPromiseExit(updateVmNetworkPolicy({ ...access, policy: allowlist }).pipe(Effect.provide(layer)));
    expect(Exit.isFailure(exit)).toBe(true);
    expect(writes[0]?.policy).toMatchObject({ mode: "allowlist" });
    expect(writes.at(-1)?.status).toMatchObject({ state: "failed" });
  });

  test("a provider without egress control refuses a restricted policy and stores nothing", async () => {
    const { layer, writes } = harness({ supportsApply: false });
    const exit = await Effect.runPromiseExit(updateVmNetworkPolicy({ ...access, policy: allowlist }).pipe(Effect.provide(layer)));
    expect(Exit.isFailure(exit) && Exit.causeOption(exit)).toBeTruthy();
    if (Exit.isFailure(exit)) expect(String(exit.cause)).toContain("VmOperationUnsupportedError");
    expect(writes).toHaveLength(0);
    expect(VmOperationUnsupportedError).toBeDefined();
  });

  test("create records the policy on the row and installs it in the provider create", async () => {
    const { layer, writes, created } = harness();
    await Effect.runPromise(createVm({
      userId: "user-net",
      billingCustomerType: "team",
      billingTeamId: "team-net",
      billingPlanId: "max",
      maxActiveVms: 50,
      provider: "freestyle",
      image: "snapshot-test",
      imageSize: { name: "xl", cpu: 16, memoryMb: 32768, storageMb: 131072 },
      networkPolicy: allowlist,
    }).pipe(Effect.provide(layer)));
    expect(writes[0]).toMatchObject({ policy: { mode: "allowlist" }, status: { state: "pending" } });
    expect(created[0]?.networkRules?.publicEgress).toBe(false);
    expect(writes.at(-1)?.status).toMatchObject({ state: "applied" });
  });
});

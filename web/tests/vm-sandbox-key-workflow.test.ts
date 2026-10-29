import { describe, expect, test } from "bun:test";
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Layer from "effect/Layer";

import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { createVm, forkVm } from "../services/vms/workflows";

// A sandboxed Run's VM (hq#3367) is the launcher's alone: created under the sandbox key with the
// server-set marker, which must survive the provider's metadata, and no other row may be reused
// under that key. Fake repository and provider layers; no database.

const NOW = new Date("2026-01-01T00:00:00.000Z");
const KEY = "sandbox-run:run-1:attempt:a-1";

function row(overrides: Partial<CloudVmRow>): CloudVmRow {
  return {
    id: "00000000-0000-4000-8000-000000000201", userId: "user-1", billingTeamId: "team-1", billingPlanId: "pro",
    provider: "freestyle", providerVmId: null, displayName: null, slug: null, imageId: "snapshot", imageVersion: null,
    status: "provisioning", idempotencyKey: KEY, createdAt: NOW, updatedAt: NOW, destroyedAt: null, failureCode: null,
    failureMessage: null, providerMetadata: {}, networkPolicy: null, networkPolicyStatus: null, agentUpdates: null,
    ownerTeamId: "team-1", coderouterPoolId: null, ...overrides,
  };
}

function layers(repo: Partial<VmRepositoryShape>, handleMetadata: Record<string, unknown>) {
  const provider = {
    create: () => Effect.succeed({ provider: "freestyle" as const, providerVmId: "vm-1", status: "running" as const, image: "snapshot", createdAt: NOW.getTime(), providerMetadata: handleMetadata }),
    destroy: () => Effect.void,
    exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
    supportsPrivateNetworking: () => true,
    ensureNetwork: () => Effect.succeed({ id: "network-1", slug: "cmux-net", cidr: "10.0.0.0/24", cidrV6: "fd00::/64" }),
  } as unknown as VmProviderGatewayShape;
  return Layer.mergeAll(
    Layer.succeed(VmRepository, repo as VmRepositoryShape),
    Layer.succeed(VmProviderGateway, provider),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
}

const begun: Array<{ sandboxMarker?: string }> = [];

const baseRepo = (captured: Array<Record<string, unknown>>): Partial<VmRepositoryShape> => ({
  beginCreate: ((input: { sandboxMarker?: string }) => {
    begun.push({ sandboxMarker: input.sandboxMarker });
    return Effect.succeed({ inserted: true, vm: row({}) });
  }) as unknown as VmRepositoryShape["beginCreate"],
  claimBillingGrant: () => Effect.succeed({ kind: "already_claimed" as const }),
  markBillingGrantApplied: () => Effect.void,
  deleteBillingGrant: () => Effect.void,
  markCreateRunning: ((input: { providerMetadata?: Record<string, unknown> }) => {
    captured.push(input.providerMetadata ?? {});
    return Effect.succeed(row({ status: "running", providerVmId: "vm-1", providerMetadata: input.providerMetadata ?? {} }));
  }) as unknown as VmRepositoryShape["markCreateRunning"],
  markCreateFailed: () => Effect.succeed(true),
  recordUsageEvent: () => Effect.void,
  recordUsageEvents: () => Effect.void,
  findNetwork: () => Effect.succeed(null),
  upsertNetwork: () => Effect.succeed({ id: "network-row", userId: "user-1", provider: "freestyle" as const, providerNetworkId: "network-1", slug: "cmux-net", cidr: "10.0.0.0/24", cidrV6: "fd00::/64", createdAt: NOW, updatedAt: NOW }),
});

const create = (providerMetadata?: Record<string, unknown>) => createVm({
  userId: "user-1", billingCustomerType: "team", billingTeamId: "team-1", billingPlanId: "pro", maxActiveVms: 5,
  provider: "freestyle", image: "snapshot", idempotencyKey: KEY, providerMetadata,
});

function failureTag(exit: Exit.Exit<unknown, unknown>): string | null {
  if (Exit.isSuccess(exit)) return null;
  const failure = Cause.failureOption(exit.cause);
  return failure._tag === "Some" ? ((failure.value as { _tag?: string })._tag ?? "unknown") : "die";
}

describe("the sandbox VM key in createVm", () => {
  test("the server-set marker survives provider metadata that does not carry it", async () => {
    const captured: Array<Record<string, unknown>> = [];
    await Effect.runPromise(create({ cmuxSandboxRun: KEY }).pipe(Effect.provide(layers(baseRepo(captured), { networkId: "net-1" }))));
    expect(captured[0]).toMatchObject({ networkId: "net-1", cmuxSandboxRun: KEY });
    // The row carries the marker from its first insert, before the provider is called.
    expect(begun.at(-1)).toEqual({ sandboxMarker: KEY });
  });

  test("a retry under a sandbox key never reuses a row that is not the launcher's", async () => {
    const captured: Array<Record<string, unknown>> = [];
    const unmarked = row({ status: "running", providerVmId: "vm-persistent", providerMetadata: {} });
    const repo = { ...baseRepo(captured), findCreateByIdempotencyKey: () => Effect.succeed(unmarked) };
    const exit = await Effect.runPromiseExit(create({ cmuxSandboxRun: KEY }).pipe(Effect.provide(layers(repo, {}))));
    expect(failureTag(exit)).toBe("VmOperationUnsupportedError");
    expect(captured).toEqual([]);
  });
  test("a retry under a sandbox key never hands back another user's marked machine", async () => {
    const captured: Array<Record<string, unknown>> = [];
    const someoneElses = row({ userId: "user-2", status: "running", providerVmId: "vm-other", providerMetadata: { cmuxSandboxRun: KEY } });
    const repo = { ...baseRepo(captured), findCreateByIdempotencyKey: () => Effect.succeed(someoneElses) };
    const exit = await Effect.runPromiseExit(create({ cmuxSandboxRun: KEY }).pipe(Effect.provide(layers(repo, {}))));
    expect(failureTag(exit)).toBe("VmOperationUnsupportedError");
    expect(captured).toEqual([]);
  });

  test("a fork never takes a sandbox key, so its retry lookup can't return a sandbox's machine", async () => {
    let looked = false;
    const sandbox = row({ status: "running", providerVmId: "vm-sandbox", providerMetadata: { cmuxSandboxRun: KEY } });
    const source = row({ id: "00000000-0000-4000-8000-000000000202", status: "running", providerVmId: "vm-src", idempotencyKey: null });
    const repo = {
      ...baseRepo([]),
      findUserVm: () => Effect.succeed(source),
      findCreateByIdempotencyKey: () => {
        looked = true;
        return Effect.succeed(sandbox);
      },
    } as unknown as Partial<VmRepositoryShape>;
    const exit = await Effect.runPromiseExit(forkVm({
      userId: "user-1", billingCustomerType: "team", billingTeamId: "team-1", billingPlanId: "pro", maxActiveVms: 5,
      providerVmId: "vm-src", idempotencyKey: KEY, teamIds: ["team-1"],
    }).pipe(Effect.provide(layers(repo, {}))));
    expect(failureTag(exit)).toBe("VmOperationUnsupportedError");
    expect(looked).toBe(false);
  });

  test("a sandbox key whose machine was destroyed ends the create instead of handing back a dead machine", async () => {
    const captured: Array<Record<string, unknown>> = [];
    const destroyed = row({ status: "destroyed", providerVmId: "vm-gone", destroyedAt: NOW, providerMetadata: { cmuxSandboxRun: KEY } });
    const repo = {
      ...baseRepo(captured),
      findCreateByIdempotencyKey: () => Effect.succeed(destroyed),
      beginCreate: (() => Effect.succeed({ inserted: false, vm: destroyed })) as unknown as VmRepositoryShape["beginCreate"],
    };
    const exit = await Effect.runPromiseExit(create({ cmuxSandboxRun: KEY }).pipe(Effect.provide(layers(repo, {}))));
    expect(failureTag(exit)).toBe("VmCreateFailedError");
    expect(captured).toEqual([]);
  });
});

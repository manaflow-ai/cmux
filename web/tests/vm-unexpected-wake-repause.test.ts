import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { VmProviderOperationError } from "../services/vms/errors";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { reconcileVmProviderStatuses } from "../services/vms/workflows";

// A paused machine that runs at the provider without a recorded resume was
// woken by traffic (cmux#21379). The status cron pauses it again instead of
// relabelling it running, unless a resume landed while it confirmed.

type UsageEvent = Parameters<VmRepositoryShape["recordUsageEvent"]>[0];
type StatusWrite = Parameters<VmRepositoryShape["markProviderObservedStatus"]>[0];

const PROVIDER_VM_ID = "provider-vm-woken";

function row(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  const now = new Date();
  return {
    id: "00000000-0000-4000-8000-00000000a11e",
    userId: "user-wake",
    billingTeamId: "team-wake",
    billingPlanId: "pro",
    provider: "freestyle",
    providerVmId: PROVIDER_VM_ID,
    displayName: null,
    slug: null,
    imageId: "snapshot-test",
    imageVersion: null,
    status: "paused",
    idempotencyKey: null,
    createdAt: now,
    updatedAt: now,
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: { cmuxResourceReservation: { vcpus: 2, memoryMb: 8192, diskMb: 32768 } },
    networkPolicy: null,
    networkPolicyStatus: null,
    agentUpdates: null,
    ownerTeamId: "team-wake",
    coderouterPoolId: null,
    ...overrides,
  };
}

function fixture(input: {
  readonly candidate: CloudVmRow;
  /** The row a confirmation re-read returns; defaults to the candidate. */
  readonly reread?: () => CloudVmRow | null;
  readonly providerStatuses: ("running" | "paused")[];
  readonly pauseFails?: boolean;
}) {
  const usageEvents: UsageEvent[] = [];
  const statusWrites: StatusWrite[] = [];
  const pauses: string[] = [];
  const statuses = [...input.providerStatuses];
  const repo: Partial<VmRepositoryShape> = {
    reconciliationCandidates: () => Effect.succeed([input.candidate]),
    findUserVm: () => Effect.succeed(input.reread ? input.reread() : input.candidate),
    markProviderObservedStatus: (write) => Effect.sync(() => {
      statusWrites.push(write);
      return true;
    }),
    recordUsageEvent: (event) => Effect.sync(() => {
      usageEvents.push(event);
    }),
  };
  const providers: Partial<VmProviderGatewayShape> = {
    getStatus: () => Effect.succeed(statuses.length > 1 ? statuses.shift()! : statuses[0]!),
    pause: (_provider, vmId) => input.pauseFails
      ? Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation: `pause(${vmId})`, cause: new Error("refused") }))
      : Effect.sync(() => {
        pauses.push(vmId);
      }),
  };
  const layer = Layer.mergeAll(
    Layer.succeed(VmRepository, repo as VmRepositoryShape),
    Layer.succeed(VmProviderGateway, providers as VmProviderGatewayShape),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
  const run = () => Effect.runPromise(
    reconcileVmProviderStatuses({ unexpectedWakeConfirmMs: 0 }).pipe(Effect.provide(layer)),
  );
  return { run, usageEvents, statusWrites, pauses };
}

describe("status cron and machines woken while paused", () => {
  test("pauses a woken machine again and keeps its row paused", async () => {
    const f = fixture({ candidate: row(), providerStatuses: ["running"] });
    const result = await f.run();
    expect(f.pauses).toEqual([PROVIDER_VM_ID]);
    expect(f.statusWrites.filter((write) => write.status === "running")).toEqual([]);
    expect(f.usageEvents).toEqual([
      expect.objectContaining({ eventType: "vm.paused", metadata: expect.objectContaining({ source: "unexpected_wake" }) }),
    ]);
    expect(result).toMatchObject({ checked: 1, repaused: 1, updated: 0 });
  });

  test("leaves a machine alone when a resume lands during confirmation", async () => {
    const f = fixture({
      candidate: row(),
      reread: () => row({ status: "running" }),
      providerStatuses: ["running"],
    });
    const result = await f.run();
    expect(f.pauses).toEqual([]);
    expect(f.statusWrites).toEqual([]);
    expect(result).toMatchObject({ repaused: 0 });
  });

  test("does nothing when the machine went back to sleep on its own", async () => {
    const f = fixture({ candidate: row(), providerStatuses: ["running", "paused"] });
    await f.run();
    expect(f.pauses).toEqual([]);
    expect(f.statusWrites).toEqual([]);
  });

  test("records the machine as running when the provider refuses the pause", async () => {
    const f = fixture({ candidate: row(), providerStatuses: ["running"], pauseFails: true });
    const result = await f.run();
    expect(f.statusWrites).toEqual([expect.objectContaining({ status: "running", providerVmId: PROVIDER_VM_ID })]);
    expect(result).toMatchObject({ repaused: 0, updated: 1 });
  });

  test("still records a running row the provider reports paused", async () => {
    const f = fixture({ candidate: row({ status: "running" }), providerStatuses: ["paused"] });
    const result = await f.run();
    expect(f.pauses).toEqual([]);
    expect(f.statusWrites).toEqual([expect.objectContaining({ status: "paused" })]);
    expect(result).toMatchObject({ updated: 1, repaused: 0 });
  });
});

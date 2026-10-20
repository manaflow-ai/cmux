import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { VmDatabaseError, VmProviderOperationError } from "../services/vms/errors";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, UNEXPECTED_WAKE_CLAIM_METADATA_KEY, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { reconcileVmProviderStatuses, resumeVm, UNEXPECTED_WAKE_REPAUSE_LIMIT } from "../services/vms/workflows";

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
  /** Every row the cron reads; defaults to the candidate alone. */
  readonly candidates?: CloudVmRow[];
  /** Rows successive confirmation re-reads return (the last repeats); defaults to the candidate. */
  readonly rereads?: (CloudVmRow | null | "fail")[];
  readonly providerStatuses: ("running" | "paused" | "fail")[];
  readonly pauseFails?: boolean;
  readonly pauseState?: "paused" | "in_progress" | "not_paused";
  readonly resumeFails?: boolean;
  /** Shared claim marker, so two fixtures can model overlapping cron runs. */
  readonly claims?: Map<string, number>;
}) {
  const usageEvents: UsageEvent[] = [];
  const statusWrites: StatusWrite[] = [];
  const pauses: string[] = [];
  const resumes: string[] = [];
  const statuses = [...input.providerStatuses];
  const rereads = [...(input.rereads ?? [input.candidate])];
  const claims = input.claims ?? new Map<string, number>();
  const next = <T>(queue: T[]) => (queue.length > 1 ? queue.shift()! : queue[0]!);
  const repo: Partial<VmRepositoryShape> = {
    // Oldest `updatedAt` first, as the live repository reads candidates.
    reconciliationCandidates: () => Effect.succeed(
      input.candidates ? [...input.candidates].sort((a, b) => a.updatedAt.getTime() - b.updatedAt.getTime()) : [input.candidate],
    ),
    findUserVm: ({ providerVmId }) => {
      if (input.candidates) return Effect.succeed(input.candidates.find((vm) => vm.providerVmId === providerVmId) ?? null);
      const reread = next(rereads);
      return reread === "fail"
        ? Effect.fail(new VmDatabaseError({ operation: "findUserVm", cause: new Error("db down") }))
        : Effect.succeed(reread);
    },
    claimUnexpectedWakeRepause: ({ id, ttlMs }) => Effect.sync(() => {
      const nowMs = Date.now();
      if ((claims.get(id) ?? 0) >= nowMs - ttlMs) return false;
      claims.set(id, nowMs);
      // The live claim also moves the row's `updatedAt` to the back.
      const claimed = input.candidates?.find((vm) => vm.id === id);
      if (claimed) claimed.updatedAt = new Date(nowMs + claims.size);
      return true;
    }),
    markProviderObservedStatus: (write) => Effect.sync(() => {
      statusWrites.push(write);
      return true;
    }),
    recordUsageEvent: (event) => Effect.sync(() => {
      usageEvents.push(event);
    }),
  };
  const providers: Partial<VmProviderGatewayShape> = {
    getStatus: (_provider, vmId) => {
      const status = next(statuses);
      return status === "fail"
        ? Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation: `getStatus(${vmId})`, cause: new Error("timeout") }))
        : Effect.succeed(status);
    },
    pause: (_provider, vmId) => Effect.sync(() => {
      pauses.push(vmId);
    }).pipe(Effect.andThen(input.pauseFails
      ? Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation: `pause(${vmId})`, cause: new Error("refused") }))
      : Effect.void)),
    getPauseState: () => Effect.succeed(input.pauseState ?? "not_paused"),
    resume: (_provider, vmId) => Effect.sync(() => {
      resumes.push(vmId);
    }).pipe(Effect.andThen(input.resumeFails
      ? Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation: `resume(${vmId})`, cause: new Error("refused") }))
      : Effect.sync(() => ({ provider: "freestyle" as const, providerVmId: vmId, status: "running" as const, image: "snapshot-test", createdAt: Date.now() })))),
  };
  const layer = Layer.mergeAll(
    Layer.succeed(VmRepository, repo as VmRepositoryShape),
    Layer.succeed(VmProviderGateway, providers as VmProviderGatewayShape),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
  const run = () => Effect.runPromise(
    reconcileVmProviderStatuses({ unexpectedWakeConfirmMs: 0 }).pipe(Effect.provide(layer)),
  );
  const open = () => Effect.runPromise(
    resumeVm({ userId: input.candidate.userId, billingTeamId: null, providerVmId: PROVIDER_VM_ID }).pipe(Effect.provide(layer)),
  );
  return { run, open, usageEvents, statusWrites, pauses, resumes };
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
      rereads: [row({ status: "running" })],
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

  test("resumes the machine again when a resume lands while the pause runs", async () => {
    const f = fixture({
      candidate: row(),
      rereads: [row(), row({ status: "running" })],
      providerStatuses: ["running"],
    });
    const result = await f.run();
    expect(f.pauses).toEqual([PROVIDER_VM_ID]);
    expect(f.resumes).toEqual([PROVIDER_VM_ID]);
    expect(f.usageEvents).toEqual([]);
    expect(f.statusWrites).toEqual([]);
    expect(result).toMatchObject({ repaused: 0 });
  });

  test("overlapping cron runs pause and record a wake once", async () => {
    const claims = new Map<string, number>();
    const first = fixture({ candidate: row(), providerStatuses: ["running"], claims });
    const second = fixture({ candidate: row(), providerStatuses: ["running"], claims });
    const [a, b] = await Promise.all([first.run(), second.run()]);
    expect([...first.pauses, ...second.pauses]).toEqual([PROVIDER_VM_ID]);
    expect([...first.usageEvents, ...second.usageEvents]).toHaveLength(1);
    expect(a.repaused + b.repaused).toBe(1);
    expect([...first.statusWrites, ...second.statusWrites]).toEqual([]);
  });

  test("counts a pause that errored but landed as a re-pause", async () => {
    const f = fixture({ candidate: row(), providerStatuses: ["running"], pauseFails: true, pauseState: "paused" });
    const result = await f.run();
    expect(f.statusWrites).toEqual([]);
    expect(result).toMatchObject({ repaused: 1, updated: 0 });
  });

  test("leaves a pause still in progress to the next run", async () => {
    const f = fixture({ candidate: row(), providerStatuses: ["running"], pauseFails: true, pauseState: "in_progress" });
    const result = await f.run();
    expect(f.statusWrites).toEqual([]);
    expect(f.usageEvents).toEqual([]);
    expect(result).toMatchObject({ repaused: 0, updated: 0, skipped: 1 });
  });

  test("records the machine as running when the confirmation re-read fails", async () => {
    const f = fixture({ candidate: row(), rereads: ["fail"], providerStatuses: ["running"] });
    const result = await f.run();
    expect(f.pauses).toEqual([]);
    expect(f.statusWrites).toEqual([expect.objectContaining({ status: "running" })]);
    expect(result).toMatchObject({ updated: 1, repaused: 0 });
  });

  test("re-pauses at most a capped number of woken machines per run", async () => {
    const candidates = Array.from({ length: UNEXPECTED_WAKE_REPAUSE_LIMIT + 5 }, (_, index) => row({
      id: `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
      providerVmId: `${PROVIDER_VM_ID}-${index}`,
    }));
    const f = fixture({ candidate: candidates[0]!, candidates, providerStatuses: ["running"] });
    const result = await f.run();
    expect(f.pauses).toHaveLength(UNEXPECTED_WAKE_REPAUSE_LIMIT);
    expect(f.statusWrites).toEqual([]);
    expect(result).toMatchObject({ checked: UNEXPECTED_WAKE_REPAUSE_LIMIT + 5, repaused: UNEXPECTED_WAKE_REPAUSE_LIMIT, skipped: 5 });
  });

  test("a later run reaches the woken machines a capped run left behind", async () => {
    const total = UNEXPECTED_WAKE_REPAUSE_LIMIT + 5;
    const candidates = Array.from({ length: total }, (_, index) => row({
      id: `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
      providerVmId: `${PROVIDER_VM_ID}-${index}`,
      updatedAt: new Date(Date.UTC(2026, 0, 1, 0, index)),
    }));
    // Traffic keeps waking every machine, so all of them run at each probe.
    const f = fixture({ candidate: candidates[0]!, candidates, providerStatuses: ["running"] });
    await f.run();
    await f.run();
    expect(new Set(f.pauses).size).toBe(total);
  });

  test("rows another run has claimed don't use up the cap", async () => {
    const claimedCount = 5;
    const claims = new Map<string, number>();
    const candidates = Array.from({ length: UNEXPECTED_WAKE_REPAUSE_LIMIT + claimedCount }, (_, index) => {
      const id = `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`;
      const claimedAtMs = index < claimedCount ? Date.now() : null;
      if (claimedAtMs) claims.set(id, claimedAtMs);
      return row({
        id,
        providerVmId: `${PROVIDER_VM_ID}-${index}`,
        updatedAt: new Date(Date.UTC(2026, 0, 1, 0, index)),
        ...(claimedAtMs ? { providerMetadata: { [UNEXPECTED_WAKE_CLAIM_METADATA_KEY]: claimedAtMs } } : {}),
      });
    });
    const f = fixture({ candidate: candidates[0]!, candidates, providerStatuses: ["running"], claims });
    const result = await f.run();
    expect(f.pauses).toHaveLength(UNEXPECTED_WAKE_REPAUSE_LIMIT);
    expect(result).toMatchObject({ repaused: UNEXPECTED_WAKE_REPAUSE_LIMIT, skipped: claimedCount });
  });

  test("records the machine as running when the confirmation probe fails", async () => {
    const f = fixture({ candidate: row(), providerStatuses: ["running", "fail"] });
    const result = await f.run();
    expect(f.pauses).toEqual([]);
    expect(f.statusWrites).toEqual([expect.objectContaining({ status: "running" })]);
    expect(result).toMatchObject({ updated: 1, repaused: 0 });
  });
});

// A personal machine's open writes `running` without a reservation, so it can
// land after the cron's post-pause re-read and leave the machine paused under
// a running row. While a re-pause claim is fresh the open resumes it itself.
describe("opening a personal machine during a re-pause", () => {
  const personal = (overrides: Partial<CloudVmRow> = {}) => row({ billingTeamId: null, ownerTeamId: "user-wake", billingPlanId: "free", ...overrides });
  const claimed = (overrides: Partial<CloudVmRow> = {}) => personal({
    providerMetadata: { [UNEXPECTED_WAKE_CLAIM_METADATA_KEY]: Date.now() },
    ...overrides,
  });

  test("resumes the machine when the row carries a fresh re-pause claim", async () => {
    const f = fixture({ candidate: claimed(), rereads: [claimed(), claimed({ status: "running" })], providerStatuses: ["running"] });
    await f.open();
    expect(f.statusWrites).toEqual([expect.objectContaining({ status: "running" })]);
    expect(f.resumes).toEqual([PROVIDER_VM_ID]);
  });

  test("resumes the machine when the cron claims the row while the open runs", async () => {
    const f = fixture({ candidate: personal(), rereads: [personal(), claimed({ status: "running" })], providerStatuses: ["running"] });
    await f.open();
    expect(f.resumes).toEqual([PROVIDER_VM_ID]);
  });

  test("still opens the machine when that resume fails", async () => {
    const f = fixture({
      candidate: claimed(),
      rereads: [claimed(), claimed({ status: "running" })],
      providerStatuses: ["running"],
      resumeFails: true,
    });
    await expect(f.open()).resolves.toMatchObject({ status: "running" });
    expect(f.resumes).toEqual([PROVIDER_VM_ID]);
    // The open reports running, so a failed resume must not pause the machine.
    expect(f.pauses).toEqual([]);
  });

  test("only records the wake when no re-pause claim is fresh", async () => {
    const stale = personal({ providerMetadata: { [UNEXPECTED_WAKE_CLAIM_METADATA_KEY]: Date.now() - 60 * 60 * 1000 } });
    const f = fixture({ candidate: stale, providerStatuses: ["running"] });
    await f.open();
    expect(f.statusWrites).toEqual([expect.objectContaining({ status: "running" })]);
    expect(f.resumes).toEqual([]);
  });
});

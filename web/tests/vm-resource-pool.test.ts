import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import {
  lockedMemoryOptionsMbForPlan,
  maxActiveVmsForPlan,
  maxMemoryMbForPlan,
  resourcePoolForPlan,
  resourcePoolPolicyForPlan,
  maxVcpusForPlan,
  memoryOptionsMbForPlan,
} from "../services/vms/entitlements";
import { vmResourceReservationForCreate } from "../services/vms/machineSpec";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { VmRepository, VmRepositoryLive, type VmRepositoryShape } from "../services/vms/repository";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { forkVm, openVmCmuxRemote, resizeVm, resumeVm } from "../services/vms/workflows";
import { VmResourcePoolExceededError } from "../services/vms/errors";
import { respondVmWorkflowError } from "../services/vms/routeHelpers";

const serialTest = (test as typeof test & { serial: typeof test }).serial;
const dbTest = process.env.CMUX_DB_TEST === "1" ? serialTest : test.skip;
let sql: Sql;
beforeAll(() => {
  if (process.env.CMUX_DB_TEST === "1") {
    sql = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!, { max: 1 });
  }
});
afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

const GB = 1024;
const PRO_POOL = { vcpus: 20, memoryMb: 40 * GB };
/** The policy a Pro workflow passes to the repository for one billing scope. */
const PRO_POOL_POLICY = {
  capacity: PRO_POOL,
  // Markerless legacy rows are charged at the provider maximum until provider
  // reconciliation proves their actual shape. This avoids undercounting a
  // 12/16-vCPU machine created before reservation metadata existed.
  legacyReservation: { vcpus: 32, memoryMb: 64 * GB },
  planId: "pro",
};

const runRepo = <T>(operation: (repo: VmRepositoryShape) => Effect.Effect<T, unknown>) =>
  Effect.runPromise(Effect.flatMap(VmRepository, operation).pipe(Effect.provide(VmRepositoryLive)));

const runWorkflow = <A>(program: Effect.Effect<A, unknown, unknown>, provider: VmProviderGatewayShape) =>
  Effect.runPromise((program as Effect.Effect<A, unknown, never>).pipe(
    Effect.either,
    Effect.provide(Layer.mergeAll(
      VmRepositoryLive,
      Layer.succeed(VmProviderGateway, provider),
      Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
    )),
  ));

/** Give every case its own billing scope and remove it even on failure. */
async function withTeam(operation: (team: string) => Promise<void>) {
  const team = `pool-${randomUUID()}`;
  try {
    await operation(team);
  } finally {
    await sql`delete from cloud_vm_bases where scope_id = ${team}`;
    await sql`delete from cloud_vms where billing_team_id = ${team}`;
  }
}

/** Insert one VM row with an optional reservation marker (undefined = legacy row). */
async function seedVm(team: string, input: {
  readonly status: "running" | "provisioning" | "paused";
  readonly vcpus?: number;
  readonly memoryMb?: number;
  readonly marker?: unknown;
  readonly providerVmId?: string;
  readonly planId?: string;
  readonly extraMetadata?: Record<string, unknown>;
}) {
  const providerVmId = input.providerVmId ?? `${team}-${randomUUID()}`;
  const marker = input.marker !== undefined
    ? input.marker
    : input.vcpus !== undefined && input.memoryMb !== undefined
      ? { vcpus: input.vcpus, memoryMb: input.memoryMb, diskMb: 32768 }
      : undefined;
  const metadata = {
    ...(marker === undefined ? {} : { cmuxResourceReservation: marker }),
    ...input.extraMetadata,
  };
  await sql`
    insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status, provider_metadata)
    values (${team}, ${team}, ${input.planId ?? "pro"}, 'freestyle', ${providerVmId}, 'snapshot-test', ${input.status}, ${sql.json(metadata as never)})
  `;
  return providerVmId;
}

function createInput(team: string, reservation: { vcpus: number; memoryMb: number }) {
  return {
    userId: team, billingTeamId: team, billingPlanId: "pro", billingCustomerType: "team" as const,
    provider: "freestyle" as const, image: "snapshot-test", maxActiveVms: 5,
    resourceReservation: { ...reservation, diskMb: 32768 },
    resourcePool: PRO_POOL_POLICY,
  };
}

describe("Cloud VM plan ceilings", () => {
  test("Pro, Team, and Founder's machines go up to the 16 GB / 8 vCPU lg row", () => {
    for (const plan of ["pro", "team", "founders"]) {
      expect(maxMemoryMbForPlan(plan, {})).toBe(16 * GB);
      expect(maxVcpusForPlan(plan, {})).toBe(8);
      expect(memoryOptionsMbForPlan(plan, {})).toContain(16 * GB);
      expect(memoryOptionsMbForPlan(plan, {})).not.toContain(64 * GB);
    }
    expect(lockedMemoryOptionsMbForPlan("pro", {})).toEqual({ memoryOptionsMb: [24 * GB, 32 * GB, 64 * GB], upgradePlanId: "max" });
  });

  test("Max machines go up to the validated 64 GB / 32 vCPU 2xl row", () => {
    expect(maxMemoryMbForPlan("max", {})).toBe(64 * GB);
    expect(maxVcpusForPlan("max", {})).toBe(32);
    expect(memoryOptionsMbForPlan("max", {})).toContain(64 * GB);
    expect(lockedMemoryOptionsMbForPlan("max", {})).toEqual({ memoryOptionsMb: [], upgradePlanId: null });
  });

  test("Go and Free ceilings are unchanged", () => {
    expect(maxMemoryMbForPlan("go", {})).toBe(4 * GB);
    expect(maxMemoryMbForPlan("free", {})).toBe(8 * GB);
  });

  test("a create reservation claims the image ladder's vCPUs for its memory", () => {
    expect(vmResourceReservationForCreate({ memoryMb: 8 * GB, env: {} })).toMatchObject({ vcpus: 4, memoryMb: 8 * GB });
    expect(vmResourceReservationForCreate({ memoryMb: 32 * GB, env: {} })).toMatchObject({ vcpus: 16, memoryMb: 32 * GB });
  });
});

describe("Cloud VM resource pool policy", () => {
  test("each plan's pool follows the paid seat count like the machine allowance", () => {
    for (const plan of ["pro", "founders"]) {
      expect(resourcePoolForPlan(plan, maxActiveVmsForPlan(plan, {}))).toEqual(PRO_POOL);
    }
    expect(resourcePoolForPlan("team", maxActiveVmsForPlan("team", {}, { seats: 3 }))).toEqual({ vcpus: 60, memoryMb: 120 * GB });
    expect(resourcePoolForPlan("max", maxActiveVmsForPlan("max", {}))).toEqual({ vcpus: 80, memoryMb: 160 * GB });
    // A Max caller on a large team keeps the larger pool in each dimension.
    expect(resourcePoolForPlan("max", 50)).toEqual({ vcpus: 200, memoryMb: 400 * GB });
    expect(resourcePoolForPlan("go", 1)).toBeNull();
    expect(resourcePoolForPlan("free", 0)).toBeNull();
    expect(resourcePoolForPlan("pro", null)).toBeNull();
    expect(resourcePoolPolicyForPlan("pro", 5)?.legacyReservation).toEqual({ vcpus: 32, memoryMb: 64 * GB });
  });

  const refusal = (planId: string, resource: "memoryMb" | "vcpus") => new VmResourcePoolExceededError({
    kind: "resource_pool", billingTeamId: "team", phase: "create", resource, planId,
    pool: planId === "max" ? { vcpus: 80, memoryMb: 160 * GB } : PRO_POOL,
    used: { vcpus: 16, memoryMb: 32 * GB },
    requested: { vcpus: 8, memoryMb: 16 * GB },
  });

  test("a full pool answers 402 with usage and the Max upgrade", async () => {
    const response = await respondVmWorkflowError(refusal("pro", "memoryMb"), { locale: "en" });
    expect(response?.status).toBe(402);
    expect(await response?.json()).toMatchObject({
      error: "vm_resource_pool_exceeded",
      message: "Your VMs already use 32 of 40 GB RAM. This VM needs 16 GB.",
      action: "Pause or delete a VM, or upgrade to Max.",
      phase: "create",
      retryable: false,
      pool: PRO_POOL,
      used: { vcpus: 16, memoryMb: 32 * GB },
      requested: { vcpus: 8, memoryMb: 16 * GB },
      upgradePlanId: "max",
      upgradeUrl: "https://cmux.com/api/billing/checkout?plan=max",
    });
  });

  test("Max names no upgrade, and a vCPU refusal counts vCPUs", async () => {
    const response = await respondVmWorkflowError(refusal("max", "vcpus"), { locale: "en" });
    expect(await response?.json()).toMatchObject({
      message: "Your VMs already use 16 of 80 vCPUs. This VM needs 8 vCPUs.",
      action: "Pause or delete a VM.",
      upgradePlanId: null,
    });
  });

  test("the refusal is localized", async () => {
    const response = await respondVmWorkflowError(refusal("pro", "memoryMb"), { locale: "ja" });
    const payload = await response?.json() as { message: string };
    expect(payload.message).toContain("32");
    expect(payload.message).toContain("40");
    expect(payload.message).not.toContain("Your VMs");
  });
});

describe("Cloud VM resource pool", () => {
  dbTest("create admits VMs until the shared memory pool is full; paused VMs do not count", () => withTeam(async team => {
    await seedVm(team, { status: "running", vcpus: 8, memoryMb: 16 * GB });
    await seedVm(team, { status: "running", vcpus: 8, memoryMb: 16 * GB });
    await seedVm(team, { status: "paused", vcpus: 16, memoryMb: 32 * GB });
    const fits = await runRepo(repo => repo.beginCreate({ ...createInput(team, { vcpus: 4, memoryMb: 8 * GB }), idempotencyKey: "fits" }));
    expect(fits.inserted).toBe(true);
    const failure = await runRepo(repo => repo.beginCreate({
      ...createInput(team, { vcpus: 2, memoryMb: 4 * GB }), idempotencyKey: "over",
    }).pipe(Effect.flip));
    expect(failure).toMatchObject({
      _tag: "VmResourcePoolExceededError",
      resource: "memoryMb",
      pool: PRO_POOL,
      used: { vcpus: 20, memoryMb: 40 * GB },
      requested: { vcpus: 2, memoryMb: 4 * GB },
      planId: "pro",
    });
  }));

  dbTest("create rejects a request that exceeds the shared vCPU pool", () => withTeam(async team => {
    await seedVm(team, { status: "running", vcpus: 16, memoryMb: 8 * GB });
    const failure = await runRepo(repo => repo.beginCreate(createInput(team, { vcpus: 8, memoryMb: 8 * GB })).pipe(Effect.flip));
    expect(failure).toMatchObject({
      _tag: "VmResourcePoolExceededError",
      resource: "vcpus",
      used: { vcpus: 16, memoryMb: 8 * GB },
      requested: { vcpus: 8, memoryMb: 8 * GB },
    });
  }));

  dbTest("legacy rows without a valid marker reserve the provider maximum", () => withTeam(async team => {
    await seedVm(team, { status: "running" });
    await seedVm(team, { status: "running", marker: { vcpus: "lots", memoryMb: 8 * GB, diskMb: 32768 } });
    const failure = await runRepo(repo => repo.beginCreate(createInput(team, { vcpus: 8, memoryMb: 16 * GB })).pipe(Effect.flip));
    expect(failure).toMatchObject({
      _tag: "VmResourcePoolExceededError",
      resource: "memoryMb",
      used: { vcpus: 64, memoryMb: 128 * GB },
    });
  }));

  dbTest("concurrent creates cannot both take the last pool capacity", () => withTeam(async team => {
    const results = await Promise.all([1, 2].map(i =>
      runRepo(repo => repo.beginCreate({
        ...createInput(team, { vcpus: 12, memoryMb: 24 * GB }), idempotencyKey: `race-${i}`,
      }).pipe(Effect.either)),
    ));
    expect(results.filter(result => result._tag === "Right")).toHaveLength(1);
    const rejected = results.find(result => result._tag === "Left");
    expect(rejected?._tag === "Left" ? rejected.left : null).toMatchObject({ _tag: "VmResourcePoolExceededError" });
  }));

  dbTest("Base open and reset draw from the same pool", () => withTeam(async team => {
    await seedVm(team, { status: "running", vcpus: 16, memoryMb: 32 * GB });
    const input = createInput(team, { vcpus: 8, memoryMb: 16 * GB });
    const open = await runRepo(repo => repo.beginBaseOpen(input).pipe(Effect.flip));
    expect(open).toMatchObject({ _tag: "VmResourcePoolExceededError", resource: "memoryMb" });
    const reset = await runRepo(repo => repo.beginBaseReset(input).pipe(Effect.flip));
    expect(reset).toMatchObject({ _tag: "VmResourcePoolExceededError", resource: "memoryMb" });
    const small = await runRepo(repo => repo.beginBaseOpen(createInput(team, { vcpus: 4, memoryMb: 8 * GB })));
    expect(small.kind).toBe("create");
  }));

  dbTest("resuming a paused VM needs room in the pool", () => withTeam(async team => {
    await seedVm(team, { status: "running", vcpus: 16, memoryMb: 32 * GB });
    const large = await seedVm(team, { status: "paused", vcpus: 8, memoryMb: 16 * GB });
    const small = await seedVm(team, { status: "paused", vcpus: 4, memoryMb: 8 * GB });
    let resumes = 0;
    const provider = {
      getStatus: () => Effect.succeed("paused"),
      resume: (_provider: string, providerVmId: string) => Effect.sync(() => {
        resumes += 1;
        return { provider: "freestyle", providerVmId, image: "snapshot-test", status: "running", createdAt: Date.now() };
      }),
    } as unknown as VmProviderGatewayShape;
    const resume = (providerVmId: string) => runWorkflow(resumeVm({
      userId: team, billingTeamId: team, teamIds: [team], providerVmId,
      maxActiveVms: 5, callerPlanId: "pro",
    }), provider);
    const blocked = await resume(large);
    expect(blocked._tag).toBe("Left");
    if (blocked._tag === "Left") {
      expect(blocked.left).toMatchObject({
        _tag: "VmResourcePoolExceededError",
        phase: "resume",
        resource: "memoryMb",
        used: { vcpus: 16, memoryMb: 32 * GB },
        requested: { vcpus: 8, memoryMb: 16 * GB },
      });
    }
    expect(resumes).toBe(0);
    const resumed = await resume(small);
    expect(resumed._tag).toBe("Right");
    expect(resumes).toBe(1);
  }));

  dbTest("growing a VM's memory or vCPUs needs room in the pool", () => withTeam(async team => {
    // Keep every fixture within the current Pro per-machine ceiling while
    // filling the shared pool around the target VM.
    await seedVm(team, { status: "running", vcpus: 8, memoryMb: 16 * GB });
    await seedVm(team, { status: "running", vcpus: 8, memoryMb: 16 * GB });
    const target = await seedVm(team, { status: "running", vcpus: 4, memoryMb: 8 * GB });
    let resizes = 0;
    let shape = { cpus: 4, memoryTotalMb: 8 * GB };
    const provider = {
      getStatus: () => Effect.succeed("running"),
      getStats: () => Effect.sync(() => ({
        state: "awake", sampledAt: Date.now(), ...shape, diskTotalMb: 32768,
      })),
      resize: (_provider: string, _id: string, request: { cpu?: number; memoryMb?: number }) => Effect.sync(() => {
        resizes += 1;
        shape = { cpus: request.cpu ?? shape.cpus, memoryTotalMb: request.memoryMb ?? shape.memoryTotalMb };
      }),
    } as unknown as VmProviderGatewayShape;
    const resize = (request: { cpu?: number; memoryMb?: number }) => runWorkflow(resizeVm({
      userId: team, billingTeamId: team, billingPlanId: "pro", teamIds: [team],
      providerVmId: target, maxActiveVms: 5, ...request,
    }), provider);

    const tooMuchMemory = await resize({ memoryMb: 16 * GB });
    expect(tooMuchMemory._tag).toBe("Left");
    if (tooMuchMemory._tag === "Left") {
      expect(tooMuchMemory.left).toMatchObject({
        _tag: "VmResourcePoolExceededError",
        phase: "resize",
        resource: "memoryMb",
        used: { vcpus: 16, memoryMb: 32 * GB },
        requested: { vcpus: 4, memoryMb: 16 * GB },
      });
    }
    const tooManyVcpus = await resize({ cpu: 8 });
    expect(tooManyVcpus._tag).toBe("Left");
    if (tooManyVcpus._tag === "Left") {
      expect(tooManyVcpus.left).toMatchObject({ _tag: "VmResourcePoolExceededError", resource: "vcpus" });
    }
    expect(resizes).toBe(0);
  }));

  dbTest("a disk-and-compute resize gives the compute claim back when the disk claim fails", () => withTeam(async team => {
    await seedVm(team, { status: "running", vcpus: 12, memoryMb: 24 * GB });
    // Another request already owns this VM's disk resize.
    const target = await seedVm(team, {
      status: "running", vcpus: 4, memoryMb: 8 * GB,
      extraMetadata: {
        cmuxResourceResizePending: {
          operationId: "concurrent-disk-resize", requestedDiskMb: 65536, previousDiskMb: 32768, createdAtMs: Date.now(),
        },
      },
    });
    let resizes = 0;
    const provider = {
      getStatus: () => Effect.succeed("running"),
      getStats: () => Effect.sync(() => ({
        state: "awake", sampledAt: Date.now(), cpus: 4, memoryTotalMb: 8 * GB, diskTotalMb: 32768,
      })),
      resize: () => Effect.sync(() => { resizes += 1; }),
    } as unknown as VmProviderGatewayShape;
    const result = await runWorkflow(resizeVm({
      userId: team, billingTeamId: team, billingPlanId: "pro", teamIds: [team],
      providerVmId: target, maxActiveVms: 5, storageMb: 65536, memoryMb: 16 * GB,
    }), provider);
    expect(result._tag).toBe("Left");
    if (result._tag === "Left") expect(result.left).toMatchObject({ _tag: "VmResizeInProgressError" });
    expect(resizes).toBe(0);
    const [row] = await sql`
      select provider_metadata->'cmuxResourceReservation' as reservation
      from cloud_vms where provider_vm_id = ${target}
    `;
    expect(row?.reservation).toMatchObject({ vcpus: 4, memoryMb: 8 * GB });
    // The pool still has the 8 GB the failed request never used.
    const fits = await runRepo(repo => repo.beginCreate(createInput(team, { vcpus: 4, memoryMb: 8 * GB })));
    expect(fits.inserted).toBe(true);
  }));

  dbTest("a resume after a failed attach uses the caller's current plan pool", () => withTeam(async team => {
    await seedVm(team, { status: "running", vcpus: 16, memoryMb: 32 * GB });
    // Made on Max, which has a larger pool; the caller is now on Pro.
    const target = await seedVm(team, { status: "running", vcpus: 8, memoryMb: 16 * GB, planId: "max" });
    let status = "running";
    let attaches = 0;
    let resumes = 0;
    const provider = {
      getStatus: () => Effect.sync(() => status),
      resume: (_provider: string, providerVmId: string) => Effect.sync(() => {
        resumes += 1;
        status = "running";
        return { provider: "freestyle", providerVmId, image: "snapshot-test", status: "running", createdAt: Date.now() };
      }),
      openCmuxRemote: () => Effect.suspend(() => {
        attaches += 1;
        if (attaches > 1) {
          return Effect.succeed({
            transport: "cmux-remote", route: "ws://10.0.0.5:1337/v1/link", token: "test-token",
            session: "test-session", expiresAtUnix: 2_000_000_000, trustedCarrier: true,
          });
        }
        // The provider idle-pauses the VM, and reconciliation records it,
        // between the preflight and the attach.
        return Effect.promise(async () => {
          status = "paused";
          await sql`update cloud_vms set status = 'paused' where provider_vm_id = ${target}`;
        }).pipe(Effect.andThen(Effect.fail(new Error("vm is paused"))));
      }),
    } as unknown as VmProviderGatewayShape;
    const result = await runWorkflow(openVmCmuxRemote({
      userId: team, billingTeamId: team, teamIds: [team], providerVmId: target,
      maxActiveVms: 5, callerPlanId: "pro",
    }), provider);
    expect(result._tag).toBe("Left");
    if (result._tag === "Left") {
      expect(result.left).toMatchObject({
        _tag: "VmResourcePoolExceededError",
        phase: "resume",
        pool: PRO_POOL,
        planId: "pro",
      });
    }
    expect(resumes).toBe(0);
  }));

  dbTest("a fork needs room in the pool for a copy of its source", () => withTeam(async team => {
    const source = await seedVm(team, { status: "running", vcpus: 8, memoryMb: 16 * GB });
    await seedVm(team, { status: "running", vcpus: 8, memoryMb: 16 * GB });
    let forks = 0;
    const provider = {
      capabilities: () => ({ fork: true }),
      getStatus: () => Effect.succeed("running"),
      fork: () => Effect.sync(() => {
        forks += 1;
        return { provider: "freestyle", providerVmId: `${team}-fork`, image: "snapshot-test", status: "running", createdAt: Date.now() };
      }),
    } as unknown as VmProviderGatewayShape;
    const result = await runWorkflow(forkVm({
      userId: team, billingCustomerType: "team", billingTeamId: team, teamIds: [team],
      billingPlanId: "pro", maxActiveVms: 5, providerVmId: source,
    }), provider);
    expect(result._tag).toBe("Left");
    if (result._tag === "Left") {
      expect(result.left).toMatchObject({
        _tag: "VmResourcePoolExceededError",
        phase: "fork",
        resource: "memoryMb",
        used: { vcpus: 16, memoryMb: 32 * GB },
        requested: { vcpus: 8, memoryMb: 16 * GB },
      });
    }
    expect(forks).toBe(0);
  }));
});

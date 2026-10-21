import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type VmRepositoryShape } from "../services/vms/repository";
import { handleVmHealthCron } from "../services/vms/health/cron";
import { sweepVmHealth, type VmHealthSweepOptions } from "../services/vms/health/sweep";
import type { ProviderInventoryVm, StoredVmHealthReport, VmControlProbe, VmHealthReport } from "../services/vms/health/types";

const READ_ONLY_MEMBERS = new Set(["listAccountVms", "listAccountTlsRules", "probeVmControl"]);

function vm(id: string, overrides: Partial<ProviderInventoryVm> = {}): ProviderInventoryVm {
  return {
    id,
    state: "running",
    metadata: { cmux: "cloud" },
    snapshot: "cmux-devbox",
    cpu: 2,
    memoryMib: 4096,
    storageMib: 10240,
    idleTimeoutSeconds: null,
    vpcIds: [],
    createdAt: "2026-10-01T00:00:00.000Z",
    updatedAt: "2026-10-01T00:00:00.000Z",
    ...overrides,
  };
}

type Harness = {
  readonly forbiddenCalls: string[];
  readonly probed: string[];
  readonly snapshots: StoredVmHealthReport[];
  readonly run: (options: VmHealthSweepOptions) => Promise<{ report: VmHealthReport; snapshotId: string | null }>;
};

/**
 * Gateway double: only the three read members exist. Any other member a sweep
 * touches (pause, destroy, deleteFirewallRule, ...) is recorded as a forbidden
 * call, which is how the tests prove the sweep is read-only.
 */
function harness(input: {
  readonly vms: readonly ProviderInventoryVm[];
  readonly probe: (vmId: string, timeoutMs: number) => Effect.Effect<VmControlProbe>;
}): Harness {
  const forbiddenCalls: string[] = [];
  const probed: string[] = [];
  const snapshots: StoredVmHealthReport[] = [];
  const reads: Partial<VmProviderGatewayShape> = {
    listAccountVms: () => Effect.succeed({ vms: input.vms, complete: true }),
    listAccountTlsRules: () => Effect.succeed({ totalCount: 2303, rules: [], complete: true }),
    probeVmControl: (_provider, vmId, options) => {
      probed.push(vmId);
      return input.probe(vmId, options.timeoutMs);
    },
  };
  const gateway = new Proxy(reads, {
    get(target, property) {
      if (typeof property === "string" && READ_ONLY_MEMBERS.has(property)) return target[property as keyof typeof target];
      if (typeof property !== "string") return undefined;
      return () => {
        forbiddenCalls.push(property);
        return Effect.die(new Error(`sweep called ${property}`));
      };
    },
  }) as VmProviderGatewayShape;
  const repo = {
    vmHealthDbRows: () => Effect.succeed([]),
    latestVmHealthSnapshot: () => Effect.succeed(snapshots.at(-1) ?? null),
    insertVmHealthSnapshot: (report: VmHealthReport) => Effect.sync(() => {
      const id = `snap-${snapshots.length + 1}`;
      snapshots.push({ id, createdAt: new Date(report.generatedAt), report });
      return { id };
    }),
    pruneVmHealthSnapshots: () => Effect.succeed(0),
  } as unknown as VmRepositoryShape;
  const layer = Layer.merge(Layer.succeed(VmProviderGateway, gateway), Layer.succeed(VmRepository, repo));
  return {
    forbiddenCalls,
    probed,
    snapshots,
    run: (options) => Effect.runPromise(sweepVmHealth(options).pipe(Effect.provide(layer))),
  };
}

/** A hung VM as the real driver sees it: no answer until the request's own timeout. */
const hangUntilTimeout = (_vmId: string, timeoutMs: number) =>
  Effect.sleep(timeoutMs).pipe(Effect.as<VmControlProbe>({ outcome: "hung", latencyMs: timeoutMs, detail: `timeout after ${timeoutMs}ms` }));

describe("sweepVmHealth", () => {
  test("is read-only toward the provider and stores one snapshot", async () => {
    const h = harness({
      vms: [vm("vm-ok"), vm("vm-hung"), vm("vm-paused", { state: "paused" }), vm("vm-chat", { metadata: { app: "chatmux2" } })],
      probe: (vmId) => Effect.succeed(vmId === "vm-hung"
        ? { outcome: "hung", latencyMs: 10, detail: "409 conflict stale runtime instance responsive=false" }
        : { outcome: "ok", latencyMs: 10 }),
    });
    const result = await h.run({});
    expect(h.forbiddenCalls).toEqual([]);
    // Paused VMs are never probed: a control-path request could wake them.
    expect(h.probed.sort()).toEqual(["vm-chat", "vm-hung", "vm-ok"]);
    expect(result.snapshotId).toBe("snap-1");
    expect(h.snapshots).toHaveLength(1);
    expect(result.report.hung.map((entry) => entry.vmId)).toEqual(["vm-hung"]);
    expect(result.report.tls?.totalCount).toBe(2303);
    expect(result.report.attention.needed).toBe(true);
  });

  test("VMs with a finite idle timeout are not probed unless the operator opts in", async () => {
    const h = harness({ vms: [vm("vm-idle", { idleTimeoutSeconds: 300 })], probe: () => Effect.succeed({ outcome: "ok", latencyMs: 1 }) });
    const skipped = await h.run({});
    expect(h.probed).toEqual([]);
    expect(skipped.report.coverage.skippedIdle).toBe(1);
    const opted = await h.run({ probeIdleVms: true });
    expect(h.probed).toEqual(["vm-idle"]);
    expect(opted.report.coverage.skippedIdle).toBe(0);
  });

  test("first-seen-hung time survives into the next sweep", async () => {
    const h = harness({ vms: [vm("vm-hung")], probe: () => Effect.succeed({ outcome: "hung", latencyMs: 1, detail: "timeout" }) });
    await h.run({});
    // Date the stored sighting in the past instead of waiting for time to pass.
    const firstSeenHungAt = "2026-10-01T00:00:00.000Z";
    const previous = h.snapshots.at(-1)!;
    h.snapshots.push({ ...previous, report: { ...previous.report, hung: previous.report.hung.map((entry) => ({ ...entry, firstSeenHungAt })) } });
    const second = await h.run({});
    expect(second.report.hung[0]!.firstSeenHungAt).toBe(firstSeenHungAt);
  });

  test("when every VM hangs, no probe starts past the deadline and the rest are reported skipped", async () => {
    const vms = Array.from({ length: 50 }, (_, index) => vm(`vm-${index}`));
    const h = harness({ vms, probe: hangUntilTimeout });
    const budgetMs = 600;
    const result = await h.run({ budgetMs, probeTimeoutMs: 200, probeConcurrency: 4 });
    const { coverage } = result.report;
    expect(coverage.probed).toBeLessThan(50);
    expect(coverage.probed).toBeGreaterThan(0);
    expect(coverage.probed + coverage.skippedBudget).toBe(50);
    expect(result.report.hung).toHaveLength(coverage.probed);
    expect(result.report.attention.reasons).toContainEqual({ code: "sweep_incomplete", unprobed: coverage.skippedBudget });
    expect(h.snapshots).toHaveLength(1);
  });

  test("a provider listing failure is recorded, not thrown, and still stores a snapshot", async () => {
    const stored: VmHealthReport[] = [];
    const repo = {
      latestVmHealthSnapshot: () => Effect.succeed(null),
      insertVmHealthSnapshot: (report: VmHealthReport) => Effect.sync(() => {
        stored.push(report);
        return { id: "snap-x" };
      }),
    } as unknown as VmRepositoryShape;
    const gateway = {
      listAccountVms: () => Effect.fail({ _tag: "VmProviderOperationError", operation: "listAccountVms", cause: new Error("503 upstream") }),
    } as unknown as VmProviderGatewayShape;
    const result = await Effect.runPromise(sweepVmHealth({}).pipe(
      Effect.provide(Layer.merge(Layer.succeed(VmProviderGateway, gateway), Layer.succeed(VmRepository, repo))),
    ));
    expect(result.report.errors).toEqual([{ stage: "inventory", message: "VmProviderOperationError listAccountVms: 503 upstream" }]);
    expect(result.report.attention.needed).toBe(true);
    expect(stored).toHaveLength(1);
  });
});

describe("sweep storage and listing deadlines", () => {
  test("a failed snapshot store still returns the report, so the cron can alert", async () => {
    const repo = {
      insertVmHealthSnapshot: () => Effect.fail({ _tag: "VmDatabaseError", operation: "insertVmHealthSnapshot", cause: new Error("relation does not exist") }),
    } as unknown as VmRepositoryShape;
    const gateway = {
      listAccountVms: () => Effect.succeed({ vms: [vm("vm-hung")], complete: true }),
      probeVmControl: () => Effect.succeed({ outcome: "hung", latencyMs: 1, detail: "timeout" }),
    } as unknown as VmProviderGatewayShape;
    const result = await Effect.runPromise(sweepVmHealth({}).pipe(
      Effect.provide(Layer.merge(Layer.succeed(VmProviderGateway, gateway), Layer.succeed(VmRepository, repo))),
    ));
    expect(result.snapshotId).toBeNull();
    expect(result.storeError).toContain("insertVmHealthSnapshot");
    expect(result.report.hung).toHaveLength(1);
  });

  test("a listing that never answers is cut at the sweep deadline and recorded", async () => {
    const gateway = {
      listAccountVms: () => Effect.never,
      listAccountTlsRules: () => Effect.never,
    } as unknown as VmProviderGatewayShape;
    const result = await Effect.runPromise(sweepVmHealth({ budgetMs: 200 }).pipe(
      Effect.provide(Layer.merge(Layer.succeed(VmProviderGateway, gateway), Layer.succeed(VmRepository, {} as VmRepositoryShape))),
    ));
    expect(result.report.errors.map((error) => error.stage)).toEqual(["inventory", "tls_rules"]);
    expect(result.report.attention.needed).toBe(true);
  });

  test("the stored report parses with the staff page schema", async () => {
    const { cloudVmHealthSchema } = await import("../orpc/server/dashboard/schemas/ops");
    const h = harness({ vms: [vm("vm-ok"), vm("vm-hung")], probe: (vmId) => Effect.succeed(vmId === "vm-hung"
      ? { outcome: "hung", latencyMs: 1, detail: "timeout" }
      : { outcome: "ok", latencyMs: 1 }) });
    const { report } = await h.run({});
    const parsed = cloudVmHealthSchema.parse({ snapshot: { id: "s", createdAt: report.generatedAt, ageSeconds: 1, stale: false }, report, owners: {} });
    expect(parsed.report?.hung[0]?.vmId).toBe("vm-hung");
  });
});

describe("GET /api/cron/vm-health", () => {
  const previousSecret = process.env.CRON_SECRET;
  beforeEach(() => {
    process.env.CRON_SECRET = "test-cron-secret";
  });
  afterEach(() => {
    if (previousSecret === undefined) delete process.env.CRON_SECRET;
    else process.env.CRON_SECRET = previousSecret;
  });

  const cronRequest = (secret?: string) => new Request("https://cmux.com/api/cron/vm-health", {
    headers: secret ? { authorization: `Bearer ${secret}` } : {},
  });

  test("rejects a caller without the cron secret before sweeping", async () => {
    let sweeps = 0;
    const response = await handleVmHealthCron(cronRequest("wrong"), {
      sweep: async () => {
        sweeps += 1;
        throw new Error("must not run");
      },
      alert: async () => "none",
      env: {},
    });
    expect(response.status).toBe(401);
    expect(sweeps).toBe(0);
  });

  test("with every probe hung, stops at the configured budget, reports skipped VMs, and alerts once", async () => {
    const vms = Array.from({ length: 40 }, (_, index) => vm(`vm-${index}`));
    const h = harness({ vms, probe: hangUntilTimeout });
    const alerts: Array<{ hung: number; pageUrl: string | null }> = [];
    const response = await handleVmHealthCron(cronRequest("test-cron-secret"), {
      sweep: (options) => h.run(options).then((result) => ({ ...result, storeError: null, pruned: 0 })),
      alert: async (report, pageUrl) => {
        alerts.push({ hung: report.hung.length, pageUrl });
        return "sent";
      },
      env: { CMUX_VM_HEALTH_BUDGET_MS: "500", CMUX_VM_HEALTH_PROBE_TIMEOUT_MS: "150", CMUX_VM_HEALTH_PROBE_CONCURRENCY: "8" },
    });
    expect(response.status).toBe(200);
    const body = await response.json() as { attentionNeeded: boolean; hung: number; coverage: { skippedBudget: number }; alert: string };
    expect(body.attentionNeeded).toBe(true);
    expect(body.hung).toBeGreaterThan(0);
    expect(body.coverage.skippedBudget).toBeGreaterThan(0);
    expect(body.alert).toBe("sent");
    expect(alerts).toEqual([{ hung: body.hung, pageUrl: "https://cmux.com/dashboard/ops/cloud-vms" }]);
    expect(h.forbiddenCalls).toEqual([]);
    // The cron response carries counts, never VM owners.
    expect(JSON.stringify(body)).not.toContain("user-");
  });

  test("a failed snapshot store answers 500 after alerting", async () => {
    const h = harness({ vms: [vm("vm-1")], probe: () => Effect.succeed({ outcome: "hung", latencyMs: 1, detail: "timeout" }) });
    let alerted = 0;
    const response = await handleVmHealthCron(cronRequest("test-cron-secret"), {
      sweep: (options) => h.run(options).then((result) => ({ ...result, snapshotId: null, storeError: "VmDatabaseError insertVmHealthSnapshot", pruned: 0 })),
      alert: async () => {
        alerted += 1;
        return "sent";
      },
      env: {},
    });
    expect(response.status).toBe(500);
    expect(alerted).toBe(1);
  });

  test("operator budget overrides are capped inside the route's maxDuration", async () => {
    const { sweepOptionsFromEnv } = await import("../services/vms/health/cron");
    expect(sweepOptionsFromEnv({ CMUX_VM_HEALTH_BUDGET_MS: "9999999" }).budgetMs).toBe(240_000);
    expect(sweepOptionsFromEnv({ CMUX_VM_HEALTH_BUDGET_MS: "2,000" }).budgetMs).toBeUndefined();
  });
});

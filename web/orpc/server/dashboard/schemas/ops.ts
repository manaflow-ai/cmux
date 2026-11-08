import { z } from "zod";

// Zod only: the dashboard client imports this module at runtime.

const nullableString = z.string().nullable();
const nullableNumber = z.number().nullable();

const ownerSchema = z.object({
  cloudVmId: z.string(),
  userId: z.string(),
  teamId: nullableString,
}).nullable();

const hungSchema = z.object({
  vmId: z.string(),
  workload: z.string(),
  owner: ownerSchema,
  snapshot: nullableString,
  size: z.object({ cpu: nullableNumber, memoryMib: nullableNumber, storageMib: nullableNumber }),
  firstSeenHungAt: z.string(),
  providerUpdatedAt: z.string(),
  dbUpdatedAt: nullableString,
  detail: z.string(),
});

const stuckSchema = z.object({
  vmId: z.string(),
  source: z.enum(["provider", "db"]),
  state: z.string(),
  workload: z.string(),
  owner: ownerSchema,
  since: z.string(),
  minutes: z.number(),
});

const driftSchema = z.object({
  vmId: z.string(),
  kind: z.enum([
    "provider_missing",
    "db_running_provider_paused",
    "db_paused_provider_running",
    "db_destroyed_provider_present",
    "provider_untracked",
  ]),
  dbStatus: nullableString,
  providerState: nullableString,
  owner: ownerSchema,
  dbUpdatedAt: nullableString,
  providerUpdatedAt: nullableString,
});

const tlsSchema = z.object({
  totalCount: z.number(),
  limit: z.number(),
  listed: z.number(),
  complete: z.boolean(),
  byOwner: z.record(z.string(), z.number()),
  pausedOverDays: z.number(),
  pausedHolders: z.object({
    vmCount: z.number(),
    ruleCount: z.number(),
    top: z.array(z.object({
      vmId: z.string(),
      workload: z.string(),
      owner: ownerSchema,
      pausedSince: z.string(),
      rules: z.number(),
    })),
  }),
}).nullable();

const reasonSchema = z.discriminatedUnion("code", [
  z.object({ code: z.literal("hung_vms"), count: z.number() }),
  z.object({ code: z.literal("stuck_transitions"), count: z.number() }),
  z.object({ code: z.literal("drift"), count: z.number() }),
  z.object({ code: z.literal("tls_over_limit"), count: z.number(), limit: z.number() }),
  z.object({ code: z.literal("tls_near_limit"), count: z.number(), limit: z.number() }),
  z.object({ code: z.literal("sweep_incomplete"), unprobed: z.number() }),
  z.object({ code: z.literal("sweep_errors"), count: z.number() }),
]);

const reportSchema = z.object({
  version: z.literal(1),
  generatedAt: z.string(),
  durationMs: z.number(),
  stateCounts: z.record(z.string(), z.number()),
  workloadCounts: z.record(z.string(), z.number()),
  coverage: z.object({
    inventoryComplete: z.boolean(),
    running: z.number(),
    probed: z.number(),
    probeErrors: z.number(),
    skippedBudget: z.number(),
    skippedIdle: z.number(),
    skippedNotRunning: z.number().optional(),
  }),
  hung: z.array(hungSchema),
  stuck: z.array(stuckSchema),
  drift: z.array(driftSchema),
  tls: tlsSchema,
  errors: z.array(z.object({
    stage: z.enum(["previous_snapshot", "inventory", "tls_rules", "db_rows"]),
    message: z.string(),
  })),
  attention: z.object({ needed: z.boolean(), reasons: z.array(reasonSchema) }),
});

/** `GET /api/admin/cloud-vm-health`: the newest stored sweep, staff only. */
export const cloudVmHealthSchema = z.object({
  snapshot: z.object({
    id: z.string(),
    createdAt: z.string(),
    ageSeconds: z.number(),
    stale: z.boolean(),
  }).nullable(),
  report: reportSchema.nullable(),
  owners: z.record(z.string(), z.object({ email: nullableString, displayName: nullableString })),
});

export type CloudVmHealth = z.output<typeof cloudVmHealthSchema>;
export type CloudVmHealthReport = z.output<typeof reportSchema>;

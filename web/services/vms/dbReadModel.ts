import { count, eq } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { cloudVms, cloudVmUsageEvents } from "../../db/schema";

export type UserVmDbSummary = {
  cloudVms: {
    total: number;
    byStatus: Record<string, number>;
  };
  usageEvents: {
    total: number;
  };
};

function countNumber(value: unknown): number {
  return typeof value === "number" ? value : Number(value ?? 0);
}

export async function loadUserVmDbSummary(userId: string): Promise<UserVmDbSummary> {
  const db = cloudDb();
  const [[{ total: vmTotal }], vmStatusRows, [{ total: usageEventTotal }]] =
    await Promise.all([
      db
        .select({ total: count() })
        .from(cloudVms)
        .where(eq(cloudVms.userId, userId)),
      db
        .select({ status: cloudVms.status, total: count() })
        .from(cloudVms)
        .where(eq(cloudVms.userId, userId))
        .groupBy(cloudVms.status),
      db
        .select({ total: count() })
        .from(cloudVmUsageEvents)
        .where(eq(cloudVmUsageEvents.userId, userId)),
    ]);

  return {
    cloudVms: {
      total: countNumber(vmTotal),
      byStatus: Object.fromEntries(
        vmStatusRows.map((row) => [row.status, countNumber(row.total)]),
      ),
    },
    usageEvents: {
      total: countNumber(usageEventTotal),
    },
  };
}

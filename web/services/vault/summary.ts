import { eq, sql } from "drizzle-orm";
import type { cloudDb } from "@/db/client";
import { vaultSessions } from "@/db/schema";

type VaultDb = ReturnType<typeof cloudDb>;

export type VaultAgentSummaryRow = {
  readonly agent: string;
  readonly sessionCount: number;
  readonly rawBytes: number;
  readonly compressedBytes: number;
  readonly lastUploadedAt: Date | null;
};

/** Wire shape of `GET /api/vault/summary`. */
export type VaultSummary = {
  readonly sessionCount: number;
  readonly rawBytes: number;
  readonly compressedBytes: number;
  readonly lastUploadedAt: string | null;
  /** Session count per agent, largest first. Empty when nothing is synced. */
  readonly agents: readonly { readonly agent: string; readonly sessionCount: number }[];
};

/** Per-agent totals of the signed-in user's synced sessions. */
export async function queryVaultAgentSummary(
  db: VaultDb,
  userId: string,
): Promise<readonly VaultAgentSummaryRow[]> {
  return db
    .select({
      agent: vaultSessions.agent,
      sessionCount: sql<number>`count(*)::int`,
      rawBytes: sql<number>`coalesce(sum(${vaultSessions.sizeBytes}), 0)::double precision`,
      compressedBytes: sql<number>`coalesce(sum(coalesce(${vaultSessions.compressedSizeBytes}, 0)), 0)::double precision`,
      lastUploadedAt: sql<Date | null>`max(${vaultSessions.lastUploadedAt})`,
    })
    .from(vaultSessions)
    .where(eq(vaultSessions.userId, userId))
    .groupBy(vaultSessions.agent);
}

export function summarizeVaultAgents(rows: readonly VaultAgentSummaryRow[]): VaultSummary {
  let sessionCount = 0;
  let rawBytes = 0;
  let compressedBytes = 0;
  let lastUploadedAt: Date | null = null;
  for (const row of rows) {
    sessionCount += row.sessionCount;
    rawBytes += row.rawBytes;
    compressedBytes += row.compressedBytes;
    const rowLast = row.lastUploadedAt === null ? null : new Date(row.lastUploadedAt);
    if (rowLast && (!lastUploadedAt || rowLast > lastUploadedAt)) lastUploadedAt = rowLast;
  }
  return {
    sessionCount,
    rawBytes,
    compressedBytes,
    lastUploadedAt: lastUploadedAt?.toISOString() ?? null,
    agents: [...rows]
      .sort((a, b) => b.sessionCount - a.sessionCount)
      .map((row) => ({ agent: row.agent, sessionCount: row.sessionCount })),
  };
}

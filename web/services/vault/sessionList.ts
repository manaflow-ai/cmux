import { and, desc, eq, ilike, lt, or, sql, type SQL } from "drizzle-orm";
import type { cloudDb } from "@/db/client";
import { vaultSessions, vaultSnapshots } from "@/db/schema";
import { normalizeAgent, type VaultAgent } from "./validation";

export const VAULT_SESSION_LIST_PAGE_SIZE = 100;

type VaultDb = ReturnType<typeof cloudDb>;

export type VaultSessionListAgent = VaultAgent | "all";

export type VaultSessionListRow = {
  readonly id: string;
  readonly agent: string;
  readonly agentSessionId: string;
  readonly relPath: string;
  readonly cwd: string | null;
  readonly latestSha256: string;
  readonly sizeBytes: number;
  readonly compressedSizeBytes: number | null;
  readonly snapshotCount: number;
  readonly firstUploadedAt: Date;
  readonly lastUploadedAt: Date;
};

export type SerializedVaultSessionListRow = Omit<
  VaultSessionListRow,
  "firstUploadedAt" | "lastUploadedAt"
> & {
  readonly firstUploadedAt: string;
  readonly lastUploadedAt: string;
};

export type VaultSessionListPage = {
  readonly sessions: readonly VaultSessionListRow[];
  readonly nextCursor: string | null;
};

export type SerializedVaultSessionListPage = {
  readonly sessions: readonly SerializedVaultSessionListRow[];
  readonly nextCursor?: string;
};

export type VaultSessionListQuery = {
  readonly userId: string;
  readonly agent?: VaultAgent;
  readonly agentSessionId?: string;
  readonly q?: string;
  readonly cursor?: string | null;
  readonly limit?: number;
};

export function normalizeVaultSessionListAgent(value: string | null): VaultSessionListAgent {
  if (!value || value === "all") return "all";
  const agent = normalizeAgent(value);
  return agent.ok ? agent.value : "all";
}

export function normalizeVaultSessionListLimit(value: string | null): number {
  if (!value || !/^\d+$/.test(value)) return VAULT_SESSION_LIST_PAGE_SIZE;
  return Math.min(Math.max(Number(value), 1), VAULT_SESSION_LIST_PAGE_SIZE);
}

export function normalizeVaultSessionSearch(value: string | null | undefined): {
  readonly raw: string;
  readonly containsPattern: string;
  readonly prefixPattern: string;
} | null {
  const raw = value?.trim();
  if (!raw) return null;
  const escaped = raw.replaceAll("\\", "\\\\").replaceAll("%", "\\%").replaceAll("_", "\\_");
  return {
    raw,
    containsPattern: `%${escaped}%`,
    prefixPattern: `${escaped}%`,
  };
}

export async function queryVaultSessionListPage(
  db: VaultDb,
  query: VaultSessionListQuery,
): Promise<VaultSessionListPage> {
  const limit = Math.min(Math.max(query.limit ?? VAULT_SESSION_LIST_PAGE_SIZE, 1), VAULT_SESSION_LIST_PAGE_SIZE);
  const conditions: SQL[] = [eq(vaultSessions.userId, query.userId)];

  if (query.agent) {
    conditions.push(eq(vaultSessions.agent, query.agent));
  }

  if (query.agentSessionId) {
    conditions.push(eq(vaultSessions.agentSessionId, query.agentSessionId));
  }

  const search = normalizeVaultSessionSearch(query.q);
  if (search) {
    // Content search is a follow-up that needs an upload-time transcript indexing pipeline.
    conditions.push(
      or(
        ilike(vaultSessions.cwd, search.containsPattern),
        ilike(vaultSessions.relPath, search.containsPattern),
        ilike(vaultSessions.agentSessionId, search.prefixPattern),
      )!,
    );
  }

  const cursor = parseVaultSessionCursor(query.cursor ?? null);
  if (cursor) {
    conditions.push(
      or(
        lt(vaultSessions.lastUploadedAt, cursor.lastUploadedAt),
        and(
          eq(vaultSessions.lastUploadedAt, cursor.lastUploadedAt),
          lt(vaultSessions.id, cursor.id),
        ),
      )!,
    );
  }

  const rows = await db
    .select({
      id: vaultSessions.id,
      agent: vaultSessions.agent,
      agentSessionId: vaultSessions.agentSessionId,
      relPath: vaultSessions.relPath,
      cwd: vaultSessions.cwd,
      latestSha256: vaultSessions.latestSha256,
      sizeBytes: vaultSessions.sizeBytes,
      compressedSizeBytes: vaultSessions.compressedSizeBytes,
      snapshotCount: sql<number>`(
        select count(*)::int
        from ${vaultSnapshots}
        where ${vaultSnapshots.sessionId} = ${sql.raw('"vault_sessions"."id"')}
      )`,
      firstUploadedAt: vaultSessions.firstUploadedAt,
      lastUploadedAt: vaultSessions.lastUploadedAt,
    })
    .from(vaultSessions)
    .where(and(...conditions))
    .orderBy(desc(vaultSessions.lastUploadedAt), desc(vaultSessions.id))
    .limit(limit + 1);

  const sessions = rows.slice(0, limit);
  const last = sessions.at(-1);
  return {
    sessions,
    nextCursor: rows.length > limit && last
      ? encodeVaultSessionCursor(last.lastUploadedAt, last.id)
      : null,
  };
}

export function serializeVaultSessionListPage(
  page: VaultSessionListPage,
): SerializedVaultSessionListPage {
  return {
    sessions: page.sessions.map((row) => ({
      ...row,
      firstUploadedAt: row.firstUploadedAt.toISOString(),
      lastUploadedAt: row.lastUploadedAt.toISOString(),
    })),
    ...(page.nextCursor ? { nextCursor: page.nextCursor } : {}),
  };
}

export function encodeVaultSessionCursor(lastUploadedAt: Date, id: string): string {
  return Buffer.from(
    JSON.stringify({ lastUploadedAt: lastUploadedAt.toISOString(), id }),
  ).toString("base64url");
}

function parseVaultSessionCursor(value: string | null): { lastUploadedAt: Date; id: string } | null {
  if (!value) return null;
  try {
    const parsed = JSON.parse(Buffer.from(value, "base64url").toString("utf8")) as {
      lastUploadedAt?: unknown;
      id?: unknown;
    };
    if (typeof parsed.lastUploadedAt !== "string" || typeof parsed.id !== "string") return null;
    const date = new Date(parsed.lastUploadedAt);
    if (Number.isNaN(date.getTime())) return null;
    return { lastUploadedAt: date, id: parsed.id };
  } catch {
    return null;
  }
}

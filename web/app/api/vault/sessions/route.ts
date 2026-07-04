import { and, desc, eq, ilike, lt, or, type SQL } from "drizzle-orm";
import { cloudDb } from "../../../../db/client";
import { vaultSessions } from "../../../../db/schema";
import { isVaultConfigured } from "../../../../services/vault/config";
import {
  normalizeAgent,
  normalizeAgentSessionId,
} from "../../../../services/vault/validation";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { unauthorized, verifyRequest } from "../../../../services/vms/auth";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  if (!isVaultConfigured()) return jsonResponse({ error: "vault_not_configured" }, 503);
  const user = await verifyRequest(request);
  if (!user) return unauthorized();

  const url = new URL(request.url);
  const limit = parseLimit(url.searchParams.get("limit"));
  const conditions: SQL[] = [eq(vaultSessions.userId, user.id)];

  const agentParam = url.searchParams.get("agent");
  if (agentParam) {
    const agent = normalizeAgent(agentParam);
    if (!agent.ok) return jsonResponse({ error: agent.error }, 400);
    conditions.push(eq(vaultSessions.agent, agent.value));
  }

  const agentSessionIdParam = url.searchParams.get("agentSessionId");
  if (agentSessionIdParam) {
    const agentSessionId = normalizeAgentSessionId(agentSessionIdParam);
    if (!agentSessionId.ok) return jsonResponse({ error: agentSessionId.error }, 400);
    conditions.push(eq(vaultSessions.agentSessionId, agentSessionId.value));
  }

  const q = url.searchParams.get("q")?.trim();
  if (q) {
    const pattern = `%${q.replaceAll("%", "\\%").replaceAll("_", "\\_")}%`;
    conditions.push(or(ilike(vaultSessions.cwd, pattern), ilike(vaultSessions.relPath, pattern))!);
  }

  const cursor = parseCursor(url.searchParams.get("cursor"));
  if (cursor) {
    conditions.push(
      or(
        lt(vaultSessions.lastUploadedAt, cursor.lastUploadedAt),
        and(eq(vaultSessions.lastUploadedAt, cursor.lastUploadedAt), lt(vaultSessions.id, cursor.id)),
      )!,
    );
  }

  const rows = await cloudDb()
    .select({
      id: vaultSessions.id,
      agent: vaultSessions.agent,
      agentSessionId: vaultSessions.agentSessionId,
      relPath: vaultSessions.relPath,
      cwd: vaultSessions.cwd,
      latestSha256: vaultSessions.latestSha256,
      sizeBytes: vaultSessions.sizeBytes,
      lastUploadedAt: vaultSessions.lastUploadedAt,
    })
    .from(vaultSessions)
    .where(and(...conditions))
    .orderBy(desc(vaultSessions.lastUploadedAt), desc(vaultSessions.id))
    .limit(limit + 1);

  const page = rows.slice(0, limit);
  const last = page.at(-1);
  const nextCursor = rows.length > limit && last
    ? encodeCursor(last.lastUploadedAt, last.id)
    : null;

  return jsonResponse({
    sessions: page.map((row) => ({
      ...row,
      lastUploadedAt: row.lastUploadedAt.toISOString(),
    })),
    ...(nextCursor ? { nextCursor } : {}),
  });
}

function parseLimit(value: string | null): number {
  if (!value || !/^\d+$/.test(value)) return 50;
  return Math.min(Math.max(Number(value), 1), 100);
}

function encodeCursor(lastUploadedAt: Date, id: string): string {
  return Buffer.from(JSON.stringify({ lastUploadedAt: lastUploadedAt.toISOString(), id })).toString("base64url");
}

function parseCursor(value: string | null): { lastUploadedAt: Date; id: string } | null {
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

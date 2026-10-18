import { createHash, randomBytes } from "node:crypto";
import { and, eq, gt, isNull } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { persistentWorkspaces, hugeBlueAttachTokens } from "../../db/schema";

export type HugeBlueAttachScope = { runtimeId: string; ownerId: string; tenantId: string };
export type HugeBlueRelayIdentity = { hostId: string; session: string };

export function attachTokenHash(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

export function hugeBlueRelayConfig(env: Readonly<Record<string, string | undefined>> = process.env) {
  const route = new URL(env.HUGE_BLUE_CMUX_REMOTE_URL ?? "");
  if (route.protocol !== "wss:" || route.username || route.password || route.search || route.hash || route.pathname !== "/v1/link") {
    throw new Error("Huge Blue relay requires a credential-free wss /v1/link URL");
  }
  const hostId = env.HUGE_BLUE_VM_ID?.trim();
  const session = env.HUGE_BLUE_CMUX_REMOTE_SESSION?.trim();
  const ttlMs = Number(env.HUGE_BLUE_ATTACH_TTL_MS ?? 300_000);
  if (!hostId || !session || !Number.isSafeInteger(ttlMs) || ttlMs < 1_000 || ttlMs > 300_000) {
    throw new Error("Huge Blue relay identity or TTL is invalid");
  }
  return { route, hostId, session, ttlMs };
}

/** Serialize rotation with the workspace row, including concurrent attaches. */
export async function issueHugeBlueAttachToken(
  scope: HugeBlueAttachScope,
  env: Readonly<Record<string, string | undefined>> = process.env,
) {
  const config = hugeBlueRelayConfig(env);
  const allowed = (env.HUGE_BLUE_ALLOWED_OWNER_IDS ?? "").split(",").map((id) => id.trim());
  if (!allowed.includes(scope.ownerId)) throw new Error("Huge Blue owner is not allowlisted");
  const token = `hba_${randomBytes(32).toString("hex")}`;
  const expiresAt = new Date(Date.now() + config.ttlMs);
  await cloudDb().transaction(async (tx) => {
    const [workspace] = await tx.select().from(persistentWorkspaces).where(and(
      eq(persistentWorkspaces.id, scope.runtimeId),
      eq(persistentWorkspaces.ownerId, scope.ownerId),
      eq(persistentWorkspaces.tenantId, scope.tenantId),
      eq(persistentWorkspaces.provider, "huge-blue"),
      eq(persistentWorkspaces.providerVmId, config.hostId),
      eq(persistentWorkspaces.lifecycle, "running"),
    )).for("update").limit(1);
    if (!workspace) throw new Error("Huge Blue workspace is not owned and running");
    await tx.update(hugeBlueAttachTokens).set({ revokedAt: new Date() }).where(and(
      eq(hugeBlueAttachTokens.runtimeId, scope.runtimeId), isNull(hugeBlueAttachTokens.revokedAt),
    ));
    await tx.insert(hugeBlueAttachTokens).values({
      tokenHash: attachTokenHash(token), ...scope,
      hostId: config.hostId, session: config.session, expiresAt,
    });
  });
  config.route.searchParams.set("token", token);
  return {
    transport: "cmux-remote" as const,
    route: config.route.href,
    token,
    expiresAtUnix: Math.floor(expiresAt.getTime() / 1_000),
    session: config.session,
    trustedCarrier: true,
  };
}

/** Relay-only read path; a DB outage must deny rather than reuse authorization. */
export async function authorizeHugeBlueAttachToken(token: string, identity: HugeBlueRelayIdentity): Promise<boolean> {
  if (!/^hba_[a-f0-9]{64}$/.test(token)) return false;
  const [row] = await cloudDb().select({ hash: hugeBlueAttachTokens.tokenHash }).from(hugeBlueAttachTokens)
    .innerJoin(persistentWorkspaces, eq(persistentWorkspaces.id, hugeBlueAttachTokens.runtimeId))
    .where(and(
      eq(hugeBlueAttachTokens.tokenHash, attachTokenHash(token)),
      eq(hugeBlueAttachTokens.hostId, identity.hostId),
      eq(hugeBlueAttachTokens.session, identity.session),
      isNull(hugeBlueAttachTokens.revokedAt),
      gt(hugeBlueAttachTokens.expiresAt, new Date()),
      eq(persistentWorkspaces.provider, "huge-blue"),
      eq(persistentWorkspaces.providerVmId, identity.hostId),
      eq(persistentWorkspaces.ownerId, hugeBlueAttachTokens.ownerId),
      eq(persistentWorkspaces.tenantId, hugeBlueAttachTokens.tenantId),
      eq(persistentWorkspaces.lifecycle, "running"),
    )).limit(1);
  return Boolean(row);
}

import { test, expect, afterAll } from "bun:test";
import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import { cloudDb, closeCloudDbForTests } from "../db/client";
import { cloudRuntimes, cloudRuntimeWorkspaces, hugeBlueAttachTokens } from "../db/schema";
import { persistentWorkspaceStoreFromRuntime } from "../services/vms/runtimeWorkspaceStore";
import { issueHugeBlueAttachToken, authorizeHugeBlueAttachToken } from "../services/vms/hugeBlueAttachTokens";

const dbTest = process.env.CMUX_DB_TEST === "1" ? test : test.skip;
afterAll(async () => { if (process.env.CMUX_DB_TEST === "1") await closeCloudDbForTests(); });
dbTest("DB token issuance fences ownership, serializes rotation, expires and revokes on suspend", async () => {
  const runtimeId = randomUUID();
  const ownerId = `owner-${randomUUID()}`;
  const scope = { runtimeId, ownerId, tenantId: ownerId };
  const identity = { hostId: "huge-blue-staging", session: "huge-blue-staging" };
  const env = { HUGE_BLUE_CMUX_REMOTE_URL: "wss://relay.example/v1/link", HUGE_BLUE_VM_ID: identity.hostId,
    HUGE_BLUE_CMUX_REMOTE_SESSION: identity.session, HUGE_BLUE_ALLOWED_OWNER_IDS: ownerId };
  const db = cloudDb();
  await db.insert(cloudRuntimes).values({ id: runtimeId, ownerTeamId: ownerId, runtimeKind: "persistent", lifecycleState: "running" });
  await db.insert(cloudRuntimeWorkspaces).values({ runtimeId, ownerTeamId: ownerId, ownerId, workspaceId: randomUUID(),
    workspaceName: "token gate", provider: "huge-blue", providerVmId: identity.hostId,
    lifecycle: "running", idempotencyKey: randomUUID(), requestDigest: "test" });
  try {
    const first = await issueHugeBlueAttachToken(scope, env);
    expect(await authorizeHugeBlueAttachToken(first.token, identity)).toBe(true);
    expect(await authorizeHugeBlueAttachToken(first.token, { ...identity, session: "other" })).toBe(false);
    await expect(issueHugeBlueAttachToken({ ...scope, tenantId: "foreign" }, env)).rejects.toThrow();
    const rotations = await Promise.all([issueHugeBlueAttachToken(scope, env), issueHugeBlueAttachToken(scope, env)]);
    expect(await authorizeHugeBlueAttachToken(first.token, identity)).toBe(false);
    const accepted = await Promise.all(rotations.map((endpoint) => authorizeHugeBlueAttachToken(endpoint.token, identity)));
    expect(accepted.filter(Boolean)).toHaveLength(1);
    const current = rotations[accepted.indexOf(true)];
    const rows = await db.select().from(hugeBlueAttachTokens).where(eq(hugeBlueAttachTokens.runtimeId, runtimeId));
    expect(JSON.stringify(rows)).not.toContain(current.token);
    await persistentWorkspaceStoreFromRuntime().updateRuntime({ runtimeId, patch: { lifecycle: "suspended" } });
    expect(await authorizeHugeBlueAttachToken(current.token, identity)).toBe(false);
    await db.update(cloudRuntimeWorkspaces).set({ lifecycle: "running" }).where(eq(cloudRuntimeWorkspaces.runtimeId, runtimeId));
    // Resume must not resurrect a capability issued before suspension.
    expect(await authorizeHugeBlueAttachToken(current.token, identity)).toBe(false);
    const expired = await issueHugeBlueAttachToken(scope, env);
    await db.update(hugeBlueAttachTokens).set({ expiresAt: new Date(0) }).where(eq(hugeBlueAttachTokens.runtimeId, runtimeId));
    expect(await authorizeHugeBlueAttachToken(expired.token, identity)).toBe(false);
  } finally { await db.delete(cloudRuntimes).where(eq(cloudRuntimes.id, runtimeId)); }
}, 30_000);

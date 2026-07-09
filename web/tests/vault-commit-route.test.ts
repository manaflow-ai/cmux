import { afterEach, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { eq, sql } from "drizzle-orm";
import { cloudDb } from "../db/client";
import { vaultSnapshots, vaultUploadGrants } from "../db/schema";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const userId = "user-vault-commit-test";
const sha256 = "b".repeat(64);

const storageModule = await import("../services/vault/storage");
const realBuildObjectKey = storageModule.buildObjectKey;
let objectContentLength = 456;
let deleteFailure: Error | null = null;
const headedKeys: string[] = [];
const headObject = mock(async (...args: unknown[]) => {
  const [key] = args as [string];
  headedKeys.push(key);
  return { contentLength: objectContentLength };
});
const copyObject = mock(async () => undefined);
const deleteObject = mock(async () => {
  if (deleteFailure) throw deleteFailure;
});
const getUser = mock(async () => stackUser());

mock.module("../services/vault/storage", () => ({
  ...storageModule,
  copyObject,
  deleteObject,
  headObject,
}));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

const { POST } = await import("../app/api/vault/sessions/commit/route");

const ORIGINAL_ENV = {
  CMUX_VAULT_ENABLED: process.env.CMUX_VAULT_ENABLED,
  CMUX_VAULT_S3_BUCKET: process.env.CMUX_VAULT_S3_BUCKET,
  CMUX_VAULT_MAX_UPLOAD_BYTES: process.env.CMUX_VAULT_MAX_UPLOAD_BYTES,
  CMUX_VAULT_MAX_USER_BYTES: process.env.CMUX_VAULT_MAX_USER_BYTES,
};

beforeAll(() => {
  if (runDbTests && !process.env.DATABASE_URL) {
    throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  }
});

beforeEach(async () => {
  process.env.CMUX_VAULT_ENABLED = "1";
  process.env.CMUX_VAULT_S3_BUCKET = "test-bucket";
  process.env.CMUX_VAULT_MAX_UPLOAD_BYTES = "1000000";
  process.env.CMUX_VAULT_MAX_USER_BYTES = "1000000";
  objectContentLength = 456;
  deleteFailure = null;
  headedKeys.length = 0;
  headObject.mockClear();
  copyObject.mockClear();
  deleteObject.mockClear();
  getUser.mockClear();
  if (runDbTests) await resetVaultTables();
});

afterEach(() => {
  restoreEnvValue("CMUX_VAULT_ENABLED", ORIGINAL_ENV.CMUX_VAULT_ENABLED);
  restoreEnvValue("CMUX_VAULT_S3_BUCKET", ORIGINAL_ENV.CMUX_VAULT_S3_BUCKET);
  restoreEnvValue("CMUX_VAULT_MAX_UPLOAD_BYTES", ORIGINAL_ENV.CMUX_VAULT_MAX_UPLOAD_BYTES);
  restoreEnvValue("CMUX_VAULT_MAX_USER_BYTES", ORIGINAL_ENV.CMUX_VAULT_MAX_USER_BYTES);
});

describe("Vault commit route", () => {
  dbTest("commits only when the current grant matches the uploaded size", async () => {
    const db = cloudDb();
    const objectKey = realBuildObjectKey(userId, "codex", "session-1", sha256);
    await insertGrant(objectKey, 456);

    const response = await POST(commitRequest({ compressedSizeBytes: 456 }));

    expect(response.status).toBe(200);
    expect((await response.json()).items[0].status).toBe("committed");
    expect(headObject).toHaveBeenCalledTimes(1);
    expect(headedKeys).toEqual([`${objectKey}.upload`]);
    expect(copyObject).toHaveBeenCalledWith(`${objectKey}.upload`, objectKey);
    expect(deleteObject).toHaveBeenCalledWith(`${objectKey}.upload`);
    const grants = await db
      .select({ id: vaultUploadGrants.id })
      .from(vaultUploadGrants)
      .where(eq(vaultUploadGrants.objectKey, objectKey));
    expect(grants).toHaveLength(0);
    const snapshots = await db
      .select({ objectKey: vaultSnapshots.objectKey })
      .from(vaultSnapshots)
      .where(eq(vaultSnapshots.objectKey, objectKey));
    expect(snapshots).toHaveLength(1);
  });

  dbTest("rejects a stale large upload after the current grant is downsized", async () => {
    const db = cloudDb();
    const objectKey = realBuildObjectKey(userId, "codex", "session-1", sha256);
    await insertGrant(objectKey, 10);
    objectContentLength = 900;

    const response = await POST(commitRequest({ compressedSizeBytes: 900 }));

    expect(response.status).toBe(200);
    expect((await response.json()).items[0].error).toBe("upload_grant_mismatch");
    expect(headObject).not.toHaveBeenCalled();
    const grants = await db
      .select({ compressedSizeBytes: vaultUploadGrants.compressedSizeBytes })
      .from(vaultUploadGrants)
      .where(eq(vaultUploadGrants.objectKey, objectKey));
    expect(grants).toHaveLength(1);
    expect(grants[0].compressedSizeBytes).toBe(10);
    const snapshots = await db
      .select({ objectKey: vaultSnapshots.objectKey })
      .from(vaultSnapshots)
      .where(eq(vaultSnapshots.objectKey, objectKey));
    expect(snapshots).toHaveLength(0);
  });

  dbTest("keeps the grant retryable when staging cleanup fails after commit", async () => {
    const db = cloudDb();
    const objectKey = realBuildObjectKey(userId, "codex", "session-1", sha256);
    await insertGrant(objectKey, 456);
    deleteFailure = new Error("storage delete failed");

    const response = await POST(commitRequest({ compressedSizeBytes: 456 }));

    expect(response.status).toBe(200);
    expect((await response.json()).items[0].status).toBe("committed");
    const grants = await db
      .select({ id: vaultUploadGrants.id })
      .from(vaultUploadGrants)
      .where(eq(vaultUploadGrants.objectKey, objectKey));
    expect(grants).toHaveLength(1);
    const snapshots = await db
      .select({ objectKey: vaultSnapshots.objectKey })
      .from(vaultSnapshots)
      .where(eq(vaultSnapshots.objectKey, objectKey));
    expect(snapshots).toHaveLength(1);
  });

  dbTest("commits legacy final-key grants without deleting the committed object", async () => {
    const db = cloudDb();
    const objectKey = realBuildObjectKey(userId, "codex", "session-1", sha256);
    await insertGrant(objectKey, 456, objectKey);

    const response = await POST(commitRequest({ compressedSizeBytes: 456 }));

    expect(response.status).toBe(200);
    expect((await response.json()).items[0].status).toBe("committed");
    expect(headObject).toHaveBeenCalledTimes(1);
    expect(headedKeys).toEqual([objectKey]);
    expect(copyObject).not.toHaveBeenCalled();
    expect(deleteObject).not.toHaveBeenCalled();
    const grants = await db
      .select({ id: vaultUploadGrants.id })
      .from(vaultUploadGrants)
      .where(eq(vaultUploadGrants.objectKey, objectKey));
    expect(grants).toHaveLength(0);
    const snapshots = await db
      .select({ objectKey: vaultSnapshots.objectKey })
      .from(vaultSnapshots)
      .where(eq(vaultSnapshots.objectKey, objectKey));
    expect(snapshots).toHaveLength(1);
  });

  dbTest("deletes a copied final object when the database commit rolls back", async () => {
    const db = cloudDb();
    const objectKey = realBuildObjectKey(userId, "codex", "session-1", sha256);
    await insertGrant(objectKey, 456);
    await db.execute(sql`
      alter table vault_snapshots
      add constraint vault_snapshots_force_failure check (compressed_size_bytes < 0)
    `);

    try {
      const response = await POST(commitRequest({ compressedSizeBytes: 456 }));

      expect(response.status).toBe(500);
      expect(copyObject).toHaveBeenCalledWith(`${objectKey}.upload`, objectKey);
      expect(deleteObject).toHaveBeenCalledWith(objectKey);
      const grants = await db
        .select({ id: vaultUploadGrants.id })
        .from(vaultUploadGrants)
        .where(eq(vaultUploadGrants.objectKey, objectKey));
      expect(grants).toHaveLength(1);
      const snapshots = await db
        .select({ objectKey: vaultSnapshots.objectKey })
        .from(vaultSnapshots)
        .where(eq(vaultSnapshots.objectKey, objectKey));
      expect(snapshots).toHaveLength(0);
    } finally {
      await db.execute(sql`alter table vault_snapshots drop constraint if exists vault_snapshots_force_failure`);
    }
  });
});

async function insertGrant(
  objectKey: string,
  compressedSizeBytes: number,
  uploadObjectKey = `${objectKey}.upload`,
): Promise<void> {
  await cloudDb()
    .insert(vaultUploadGrants)
    .values({
      userId,
      objectKey,
      uploadObjectKey,
      compressedSizeBytes,
      createdAt: new Date("2030-01-01T00:00:00.000Z"),
      expiresAt: new Date("2030-01-02T00:00:00.000Z"),
    });
}

function commitRequest(input: { readonly compressedSizeBytes: number }): Request {
  return new Request("https://cmux.test/api/vault/sessions/commit", {
    method: "POST",
    headers: {
      authorization: "Bearer access-token",
      "x-stack-refresh-token": "refresh-token",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      items: [{
        agent: "codex",
        agentSessionId: "session-1",
        relPath: "sessions/session-1.jsonl.zst",
        cwd: "/workspace",
        sha256,
        sizeBytes: 999,
        compressedSizeBytes: input.compressedSizeBytes,
      }],
    }),
  });
}

async function resetVaultTables(): Promise<void> {
  await cloudDb().execute(sql`
    truncate vault_snapshots, vault_sessions, vault_upload_grants restart identity cascade
  `);
}

function stackUser() {
  return {
    id: userId,
    displayName: null,
    primaryEmail: "vault-commit@example.test",
    selectedTeam: null,
    clientReadOnlyMetadata: {},
    listTeams: async () => [],
  };
}

function restoreEnvValue(key: string, value: string | undefined): void {
  if (value === undefined) {
    delete process.env[key];
    return;
  }
  process.env[key] = value;
}

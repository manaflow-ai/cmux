import { afterEach, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { eq, sql } from "drizzle-orm";
import { cloudDb } from "../db/client";
import { vaultSessions, vaultSnapshots, vaultUploadGrants } from "../db/schema";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const userId = "user-vault-upload-test";
const sha256 = "a".repeat(64);

const storageModule = await import("../services/vault/storage");
const realBuildObjectKey = storageModule.buildObjectKey;
let presignFailure: Error | null = null;
let beforeNextPresignFailure: (() => Promise<void>) | null = null;
let beforeNextDelete: ((key: string) => Promise<void>) | null = null;
const presignPut = mock(async (...args: unknown[]) => {
  const [key, contentLength] = args as [string, number];
  if (beforeNextPresignFailure) {
    const run = beforeNextPresignFailure;
    beforeNextPresignFailure = null;
    await run();
    throw new Error("transient presign failure");
  }
  if (presignFailure) throw presignFailure;
  return `https://storage.test/${encodeURIComponent(key)}?contentLength=${contentLength}`;
});
const deleteObject = mock(async (...args: unknown[]) => {
  const [key] = args as [string];
  if (!beforeNextDelete) return;
  const run = beforeNextDelete;
  beforeNextDelete = null;
  await run(key);
});
const getUser = mock(async () => stackUser());

mock.module("../services/vault/storage", () => ({
  ...storageModule,
  presignPut,
  deleteObject,
}));

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

const { POST } = await import("../app/api/vault/uploads/route");

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
  presignFailure = null;
  beforeNextPresignFailure = null;
  beforeNextDelete = null;
  presignPut.mockClear();
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

describe("Vault uploads route", () => {
  dbTest("restores an existing upload grant when retry presign fails", async () => {
    const db = cloudDb();
    const objectKey = realBuildObjectKey(userId, "codex", "session-1", sha256);
    const previousCreatedAt = new Date("2030-01-01T00:00:00.000Z");
    const previousExpiresAt = new Date("2030-01-02T00:00:00.000Z");
    const [previousGrant] = await db
      .insert(vaultUploadGrants)
      .values({
        userId,
        objectKey,
        uploadObjectKey: `${objectKey}.previous-upload`,
        compressedSizeBytes: 123,
        createdAt: previousCreatedAt,
        expiresAt: previousExpiresAt,
      })
      .returning({ id: vaultUploadGrants.id });
    expect(previousGrant).toBeDefined();

    presignFailure = new Error("transient presign failure");
    const response = await POST(uploadRequest({ compressedSizeBytes: 456 }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      items: [{
        agent: "codex",
        agentSessionId: "session-1",
        relPath: "sessions/session-1.jsonl.zst",
        status: "error",
        error: "upload_presign_failed",
      }],
    });
    const rows = await db
      .select()
      .from(vaultUploadGrants)
      .where(eq(vaultUploadGrants.objectKey, objectKey));
    expect(rows).toHaveLength(1);
    expect(rows[0].id).toBe(previousGrant!.id);
    expect(rows[0].compressedSizeBytes).toBe(123);
    expect(rows[0].createdAt.getTime()).toBe(previousCreatedAt.getTime());
    expect(rows[0].expiresAt.getTime()).toBe(previousExpiresAt.getTime());
  });

  dbTest("does not restore an older grant over a newer successful retry", async () => {
    const db = cloudDb();
    const objectKey = realBuildObjectKey(userId, "codex", "session-1", sha256);
    await db
      .insert(vaultUploadGrants)
      .values({
        userId,
        objectKey,
        uploadObjectKey: `${objectKey}.previous-upload`,
        compressedSizeBytes: 123,
        createdAt: new Date("2030-01-01T00:00:00.000Z"),
        expiresAt: new Date("2030-01-02T00:00:00.000Z"),
      });

    beforeNextPresignFailure = async () => {
      const [staleReservation] = await db
        .select({
          createdAt: vaultUploadGrants.createdAt,
          expiresAt: vaultUploadGrants.expiresAt,
        })
        .from(vaultUploadGrants)
        .where(eq(vaultUploadGrants.objectKey, objectKey))
        .limit(1);
      expect(staleReservation).toBeDefined();

      const response = await POST(uploadRequest({ compressedSizeBytes: 789 }));
      expect(response.status).toBe(200);
      expect((await response.json()).items[0].status).toBe("upload");
      await db
        .update(vaultUploadGrants)
        .set({
          createdAt: staleReservation!.createdAt,
          expiresAt: staleReservation!.expiresAt,
        })
        .where(eq(vaultUploadGrants.objectKey, objectKey));
    };
    const response = await POST(uploadRequest({ compressedSizeBytes: 456 }));

    expect(response.status).toBe(200);
    expect((await response.json()).items[0].error).toBe("upload_presign_failed");
    const rows = await db
      .select()
      .from(vaultUploadGrants)
      .where(eq(vaultUploadGrants.objectKey, objectKey));
    expect(rows).toHaveLength(1);
    expect(rows[0].compressedSizeBytes).toBe(789);
  });

  dbTest("reuses the active staging key when retrying an existing grant", async () => {
    const db = cloudDb();
    const objectKey = realBuildObjectKey(userId, "codex", "session-1", sha256);
    const uploadObjectKey = `${objectKey}.active-upload`;
    const [originalGrant] = await db
      .insert(vaultUploadGrants)
      .values({
        userId,
        objectKey,
        uploadObjectKey,
        compressedSizeBytes: 123,
        createdAt: new Date("2030-01-01T00:00:00.000Z"),
        expiresAt: new Date(Date.now() + 60_000),
      })
      .returning({ reservationToken: vaultUploadGrants.reservationToken });

    const response = await POST(uploadRequest({ compressedSizeBytes: 456 }));

    expect(response.status).toBe(200);
    expect((await response.json()).items[0].status).toBe("upload");
    expect(presignPut).toHaveBeenCalledWith(uploadObjectKey, 456);
    const rows = await db
      .select({
        uploadObjectKey: vaultUploadGrants.uploadObjectKey,
        reservationToken: vaultUploadGrants.reservationToken,
      })
      .from(vaultUploadGrants)
      .where(eq(vaultUploadGrants.objectKey, objectKey));
    expect(rows).toHaveLength(1);
    expect(rows[0].uploadObjectKey).toBe(uploadObjectKey);
    expect(rows[0].reservationToken).not.toBe(originalGrant!.reservationToken);
  });

  dbTest("removes a newly-created upload grant when presign fails", async () => {
    const db = cloudDb();
    const objectKey = realBuildObjectKey(userId, "codex", "session-1", sha256);

    presignFailure = new Error("transient presign failure");
    const response = await POST(uploadRequest({ compressedSizeBytes: 456 }));

    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.items[0].error).toBe("upload_presign_failed");
    const rows = await db
      .select({ id: vaultUploadGrants.id })
      .from(vaultUploadGrants)
      .where(eq(vaultUploadGrants.objectKey, objectKey));
    expect(rows).toHaveLength(0);
  });

  dbTest("rejects duplicate object keys before a later entry can overwrite the first grant", async () => {
    const db = cloudDb();
    const objectKey = realBuildObjectKey(userId, "codex", "session-1", sha256);

    const response = await POST(duplicateUploadRequest());

    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.items[0]).toMatchObject({
      agent: "codex",
      agentSessionId: "session-1",
      relPath: "sessions/session-1.jsonl.zst",
      status: "upload",
      objectKey,
    });
    expect(body.items[0].putUrl).toContain("vault%2Fuploads%2F");
    expect(body.items[0].putUrl).toContain("contentLength=456");
    expect(body.items[1]).toEqual({
      agent: "codex",
      agentSessionId: "session-1",
      relPath: "sessions/session-1-duplicate.jsonl.zst",
      status: "error",
      error: "duplicate_object_key",
    });
    expect(body.items).toHaveLength(2);
    expect(presignPut).toHaveBeenCalledTimes(1);
    const rows = await db
      .select({ compressedSizeBytes: vaultUploadGrants.compressedSizeBytes })
      .from(vaultUploadGrants)
      .where(eq(vaultUploadGrants.objectKey, objectKey));
    expect(rows).toHaveLength(1);
    expect(rows[0].compressedSizeBytes).toBe(456);
  });

  dbTest("deletes expired staged uploads even when the final object is committed", async () => {
    const db = cloudDb();
    const objectKey = realBuildObjectKey(userId, "codex", "session-1", sha256);
    const uploadObjectKey = `${objectKey}.staged`;
    const uploadedAt = new Date("2030-01-01T00:00:00.000Z");
    const [session] = await db
      .insert(vaultSessions)
      .values({
        userId,
        agent: "codex",
        agentSessionId: "session-1",
        relPath: "sessions/session-1.jsonl.zst",
        cwd: "/workspace",
        latestSha256: sha256,
        latestObjectKey: objectKey,
        sizeBytes: 999,
        compressedSizeBytes: 456,
        firstUploadedAt: uploadedAt,
        lastUploadedAt: uploadedAt,
        metadata: {},
      })
      .returning({ id: vaultSessions.id });
    await db.insert(vaultSnapshots).values({
      sessionId: session!.id,
      sha256,
      objectKey,
      sizeBytes: 999,
      compressedSizeBytes: 456,
      uploadedAt,
    });
    await db.insert(vaultUploadGrants).values({
      userId,
      objectKey,
      uploadObjectKey,
      compressedSizeBytes: 456,
      createdAt: new Date("2020-01-01T00:00:00.000Z"),
      expiresAt: new Date("2020-01-02T00:00:00.000Z"),
    });

    const response = await POST(uploadRequest({ compressedSizeBytes: 456 }));

    expect(response.status).toBe(200);
    expect(deleteObject).toHaveBeenCalledWith(uploadObjectKey);
    const grants = await db
      .select({ id: vaultUploadGrants.id })
      .from(vaultUploadGrants)
      .where(eq(vaultUploadGrants.objectKey, objectKey));
    expect(grants).toHaveLength(0);
  });

  dbTest("deletes expired staged uploads and uncommitted copied final objects", async () => {
    const db = cloudDb();
    const expiredSha = "c".repeat(64);
    const objectKey = realBuildObjectKey(userId, "codex", "session-gc", expiredSha);
    const uploadObjectKey = `${objectKey}.staged`;
    await db.insert(vaultUploadGrants).values({
      userId,
      objectKey,
      uploadObjectKey,
      compressedSizeBytes: 456,
      createdAt: new Date("2020-01-01T00:00:00.000Z"),
      expiresAt: new Date("2020-01-02T00:00:00.000Z"),
    });

    const response = await POST(uploadRequest({ compressedSizeBytes: 456 }));

    expect(response.status).toBe(200);
    expect(deleteObject).toHaveBeenCalledWith(uploadObjectKey);
    expect(deleteObject).toHaveBeenCalledWith(objectKey);
    const grants = await db
      .select({ id: vaultUploadGrants.id })
      .from(vaultUploadGrants)
      .where(eq(vaultUploadGrants.objectKey, objectKey));
    expect(grants).toHaveLength(0);
  });

  dbTest("does not delete an expired grant final object after it becomes committed", async () => {
    const db = cloudDb();
    const expiredSha = "d".repeat(64);
    const objectKey = realBuildObjectKey(userId, "codex", "session-gc-race", expiredSha);
    const uploadObjectKey = `${objectKey}.staged`;
    await db.insert(vaultUploadGrants).values({
      userId,
      objectKey,
      uploadObjectKey,
      compressedSizeBytes: 456,
      createdAt: new Date("2020-01-01T00:00:00.000Z"),
      expiresAt: new Date("2020-01-02T00:00:00.000Z"),
    });
    beforeNextDelete = async (key) => {
      expect(key).toBe(uploadObjectKey);
      const uploadedAt = new Date("2030-01-01T00:00:00.000Z");
      const [session] = await db
        .insert(vaultSessions)
        .values({
          userId,
          agent: "codex",
          agentSessionId: "session-gc-race",
          relPath: "sessions/session-gc-race.jsonl.zst",
          cwd: "/workspace",
          latestSha256: expiredSha,
          latestObjectKey: objectKey,
          sizeBytes: 999,
          compressedSizeBytes: 456,
          firstUploadedAt: uploadedAt,
          lastUploadedAt: uploadedAt,
          metadata: {},
        })
        .returning({ id: vaultSessions.id });
      await db.insert(vaultSnapshots).values({
        sessionId: session!.id,
        sha256: expiredSha,
        objectKey,
        sizeBytes: 999,
        compressedSizeBytes: 456,
        uploadedAt,
      });
    };

    const response = await POST(uploadRequest({ compressedSizeBytes: 456 }));

    expect(response.status).toBe(200);
    expect(deleteObject).toHaveBeenCalledWith(uploadObjectKey);
    expect(deleteObject).not.toHaveBeenCalledWith(objectKey);
    const grants = await db
      .select({ id: vaultUploadGrants.id })
      .from(vaultUploadGrants)
      .where(eq(vaultUploadGrants.objectKey, objectKey));
    expect(grants).toHaveLength(0);
  });
});

function uploadRequest(input: { readonly compressedSizeBytes: number }): Request {
  return new Request("https://cmux.test/api/vault/uploads", {
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

function duplicateUploadRequest(): Request {
  return new Request("https://cmux.test/api/vault/uploads", {
    method: "POST",
    headers: {
      authorization: "Bearer access-token",
      "x-stack-refresh-token": "refresh-token",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      items: [
        {
          agent: "codex",
          agentSessionId: "session-1",
          relPath: "sessions/session-1.jsonl.zst",
          cwd: "/workspace",
          sha256,
          sizeBytes: 999,
          compressedSizeBytes: 456,
        },
        {
          agent: "codex",
          agentSessionId: "session-1",
          relPath: "sessions/session-1-duplicate.jsonl.zst",
          cwd: "/workspace",
          sha256,
          sizeBytes: 999,
          compressedSizeBytes: 789,
        },
      ],
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
    primaryEmail: "vault-upload@example.test",
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

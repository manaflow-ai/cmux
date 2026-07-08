import { afterEach, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { eq, sql } from "drizzle-orm";
import { cloudDb } from "../db/client";
import { vaultUploadGrants } from "../db/schema";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const userId = "user-vault-upload-test";
const sha256 = "a".repeat(64);

const storageModule = await import("../services/vault/storage");
const realBuildObjectKey = storageModule.buildObjectKey;
let presignFailure: Error | null = null;
let beforeNextPresignFailure: (() => Promise<void>) | null = null;
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
const deleteObject = mock(async () => undefined);
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
        compressedSizeBytes: 123,
        createdAt: new Date("2030-01-01T00:00:00.000Z"),
        expiresAt: new Date("2030-01-02T00:00:00.000Z"),
      });

    beforeNextPresignFailure = async () => {
      await new Promise((resolve) => setTimeout(resolve, 5));
      const response = await POST(uploadRequest({ compressedSizeBytes: 789 }));
      expect(response.status).toBe(200);
      expect((await response.json()).items[0].status).toBe("upload");
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

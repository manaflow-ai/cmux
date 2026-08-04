import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { accountDeletionUserHash } from "../services/account/deletionLock";
import {
  IROH_ENROLLMENT_TOKEN_LIFETIME_MS,
  drizzleIrohEnrollmentStore,
  handleIrohEnrollment,
  handleIrohEnrollmentTokenMint,
  type IrohEnrollmentDependencies,
  type IrohEnrollmentStoreShape,
} from "../services/iroh/enrollment";
import { IrohQuotaExceededError } from "../services/iroh/errors";
import { sha256 } from "../services/iroh/model";
import type { AuthedUser } from "../services/vms/auth";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

const NOW = new Date("2026-07-09T20:00:00.000Z");
const USER = { id: "user-enroll-1" } as AuthedUser;
const BASE64URL_43 = /^[A-Za-z0-9_-]{43}$/;

type MintCall = { userId: string; tokenHash: string; now: Date; expiresAt: Date };
type ConsumeCall = { tokenHash: string; now: Date };

function fakeStore(options: {
  mintError?: unknown;
  consumeResult?: { userId: string } | null;
  consumeError?: unknown;
} = {}) {
  const mints: MintCall[] = [];
  const consumes: ConsumeCall[] = [];
  const store: IrohEnrollmentStoreShape = {
    mintToken: async (input) => {
      if (options.mintError) throw options.mintError;
      mints.push(input);
    },
    consumeToken: async (input) => {
      if (options.consumeError) throw options.consumeError;
      consumes.push(input);
      return options.consumeResult ?? null;
    },
  };
  return { store, mints, consumes };
}

function nativeMintRequest(body?: BodyInit): Request {
  return new Request("https://cmux.example/api/devices/iroh/enrollment-tokens", {
    method: "POST",
    headers: {
      authorization: "Bearer test-access",
      "x-stack-refresh-token": "test-refresh",
      ...(body === undefined ? {} : { "content-type": "application/json" }),
    },
    ...(body === undefined ? {} : { body }),
  });
}

function enrollRequest(body: string, contentType = "application/json"): Request {
  return new Request("https://cmux.example/api/devices/iroh/enroll", {
    method: "POST",
    headers: { "content-type": contentType },
    body,
  });
}

function mintDependencies(
  store: IrohEnrollmentStoreShape,
  overrides: IrohEnrollmentDependencies = {},
): IrohEnrollmentDependencies {
  return {
    verify: async () => USER,
    store,
    now: () => NOW,
    ...overrides,
  };
}

describe("Iroh enrollment token mint", () => {
  test("mints a one-use token, persists only its SHA-256, and reports the 15-minute expiry", async () => {
    const { store, mints } = fakeStore();
    const response = await handleIrohEnrollmentTokenMint(nativeMintRequest(), mintDependencies(store));
    expect(response.status).toBe(201);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = await response.json() as { token: string; expires_at: string };
    expect(body.token).toMatch(BASE64URL_43);
    expect(body.expires_at).toBe(new Date(NOW.getTime() + IROH_ENROLLMENT_TOKEN_LIFETIME_MS).toISOString());
    expect(mints).toHaveLength(1);
    expect(mints[0]?.userId).toBe(USER.id);
    expect(mints[0]?.tokenHash).toBe(sha256(body.token));
    expect(mints[0]?.tokenHash).toMatch(/^[0-9a-f]{64}$/);
    expect(mints[0]?.tokenHash).not.toBe(body.token);
    expect(mints[0]?.expiresAt.toISOString()).toBe(body.expires_at);
  });

  test("requires a native bearer session and never reaches the store unauthenticated", async () => {
    const { store, mints } = fakeStore();
    const seenOptions: unknown[] = [];
    const response = await handleIrohEnrollmentTokenMint(
      nativeMintRequest(),
      mintDependencies(store, {
        verify: async (_request, options) => {
          seenOptions.push(options);
          return null;
        },
      }),
    );
    expect(response.status).toBe(401);
    // Cookie sessions may not mint provisioning tokens: the handler must ask
    // verifyRequest for the native-bearer-only path.
    expect(seenOptions).toEqual([{ allowCookie: false }]);
    expect(mints).toHaveLength(0);
  });

  test("blocks cross-origin browser-shaped mutations even for an authenticated user", async () => {
    const { store, mints } = fakeStore();
    const request = new Request("https://cmux.example/api/devices/iroh/enrollment-tokens", {
      method: "POST",
      headers: { origin: "https://evil.example" },
    });
    const response = await handleIrohEnrollmentTokenMint(request, mintDependencies(store));
    expect(response.status).toBe(403);
    expect(mints).toHaveLength(0);
  });

  test("accepts only an empty body and rejects unknown parameters", async () => {
    const { store, mints } = fakeStore();
    expect((await handleIrohEnrollmentTokenMint(nativeMintRequest("{}"), mintDependencies(store))).status).toBe(201);
    const rejected = await handleIrohEnrollmentTokenMint(
      nativeMintRequest(JSON.stringify({ ttl: "forever" })),
      mintDependencies(store),
    );
    expect(rejected.status).toBe(400);
    expect(mints).toHaveLength(1);
  });

  test("maps the outstanding-token cap to 429 with a retry-after", async () => {
    const { store } = fakeStore({
      mintError: new IrohQuotaExceededError({ code: "enrollment_token_quota", retryAfterSeconds: 37 }),
    });
    const response = await handleIrohEnrollmentTokenMint(nativeMintRequest(), mintDependencies(store));
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("37");
    expect(await response.json()).toEqual({
      error: "enrollment_token_quota",
      retry_after_seconds: 37,
    });
  });
});

describe("Iroh enrollment exchange", () => {
  const PLAINTEXT = "u".repeat(43);

  function exchangeDependencies(
    store: IrohEnrollmentStoreShape,
    overrides: IrohEnrollmentDependencies = {},
  ): IrohEnrollmentDependencies {
    return {
      store,
      rateLimit: async () => null,
      mintSession: async () => ({ accessToken: "stack-access", refreshToken: "stack-refresh" }),
      now: () => NOW,
      ...overrides,
    };
  }

  test("exchanges a valid token exactly once for a Stack session", async () => {
    const { store, consumes } = fakeStore({ consumeResult: { userId: USER.id } });
    const mintedFor: string[] = [];
    const response = await handleIrohEnrollment(
      enrollRequest(JSON.stringify({ token: PLAINTEXT })),
      exchangeDependencies(store, {
        mintSession: async (userId) => {
          mintedFor.push(userId);
          return { accessToken: "stack-access", refreshToken: "stack-refresh" };
        },
      }),
    );
    expect(response.status).toBe(201);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({
      accessToken: "stack-access",
      refreshToken: "stack-refresh",
    });
    // The wire token never reaches storage: lookup happens by SHA-256 only.
    expect(consumes).toEqual([{ tokenHash: sha256(PLAINTEXT), now: NOW }]);
    expect(mintedFor).toEqual([USER.id]);
  });

  test("answers one uniform 404 for malformed, unknown, consumed, and expired tokens", async () => {
    const { store, consumes } = fakeStore({ consumeResult: null });
    const dependencies = exchangeDependencies(store);
    for (const malformed of ["", "short", "!".repeat(43), "v".repeat(44), "w".repeat(200)]) {
      const response = await handleIrohEnrollment(
        enrollRequest(JSON.stringify({ token: malformed })),
        dependencies,
      );
      expect(response.status).toBe(404);
      expect(await response.json()).toEqual({ error: "invalid_enrollment_token" });
    }
    // Malformed tokens are rejected before any store lookup.
    expect(consumes).toHaveLength(0);

    const unusable = await handleIrohEnrollment(
      enrollRequest(JSON.stringify({ token: PLAINTEXT })),
      dependencies,
    );
    expect(unusable.status).toBe(404);
    expect(await unusable.json()).toEqual({ error: "invalid_enrollment_token" });
    expect(consumes).toHaveLength(1);
  });

  test("does not leak whether the enrolled account still exists", async () => {
    const { store } = fakeStore({ consumeResult: { userId: "user-deleted" } });
    const response = await handleIrohEnrollment(
      enrollRequest(JSON.stringify({ token: PLAINTEXT })),
      exchangeDependencies(store, { mintSession: async () => null }),
    );
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "invalid_enrollment_token" });
  });

  test("rejects non-JSON media, unknown fields, and oversized bodies before consuming", async () => {
    const { store, consumes } = fakeStore({ consumeResult: { userId: USER.id } });
    const dependencies = exchangeDependencies(store);
    expect((await handleIrohEnrollment(enrollRequest("token=x", "text/plain"), dependencies)).status).toBe(415);
    expect((await handleIrohEnrollment(enrollRequest(""), dependencies)).status).toBe(400);
    expect((await handleIrohEnrollment(enrollRequest("not json"), dependencies)).status).toBe(400);
    expect((await handleIrohEnrollment(
      enrollRequest(JSON.stringify({ token: PLAINTEXT, extra: true })),
      dependencies,
    )).status).toBe(400);
    expect((await handleIrohEnrollment(
      enrollRequest(JSON.stringify({ token: "x".repeat(70 * 1_024) })),
      dependencies,
    )).status).toBe(413);
    expect(consumes).toHaveLength(0);
  });

  test("honors the platform rate limiter before touching the store", async () => {
    const { store, consumes } = fakeStore({ consumeResult: { userId: USER.id } });
    const response = await handleIrohEnrollment(
      enrollRequest(JSON.stringify({ token: PLAINTEXT })),
      exchangeDependencies(store, {
        rateLimit: async () => new Response(JSON.stringify({ error: "throttled" }), { status: 429 }),
      }),
    );
    expect(response.status).toBe(429);
    expect(consumes).toHaveLength(0);
  });

  test("maps unexpected store failures to an opaque 500", async () => {
    const { store } = fakeStore({ consumeError: new Error("database down") });
    const response = await handleIrohEnrollment(
      enrollRequest(JSON.stringify({ token: PLAINTEXT })),
      exchangeDependencies(store),
    );
    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: "iroh_internal_error" });
  });
});

describe("Iroh enrollment database behavior", () => {
  let sql: Sql | null = null;

  function requiredSql(): Sql {
    if (!sql) throw new Error("test database not initialized");
    return sql;
  }

  beforeEach(async () => {
    if (!runDbTests) return;
    if (!sql) {
      const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
      if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
      sql = postgres(databaseURL, { max: 1 });
    }
    await sql`truncate iroh_enrollment_tokens, account_deletion_tombstones restart identity cascade`;
  });

  afterAll(async () => {
    await closeCloudDbForTests();
    await sql?.end();
  });

  dbTest("a token minted before account deletion cannot be redeemed once deletion is pending", async () => {
    const userId = "user-enroll-fence";
    const plaintext = "f".repeat(43);
    const store = drizzleIrohEnrollmentStore();
    await store.mintToken({
      userId,
      tokenHash: sha256(plaintext),
      now: NOW,
      expiresAt: new Date(NOW.getTime() + IROH_ENROLLMENT_TOKEN_LIFETIME_MS),
    });

    // Deletion becomes pending after the mint but before the container
    // redeems its token.
    await requiredSql()`
      insert into account_deletion_tombstones (user_id_hash, user_id, status)
      values (${accountDeletionUserHash(userId)}, ${userId}, 'pending')
    `;

    const mintedSessions: string[] = [];
    const dependencies: IrohEnrollmentDependencies = {
      store,
      rateLimit: async () => null,
      mintSession: async (sessionUserId) => {
        mintedSessions.push(sessionUserId);
        return { accessToken: "stack-access", refreshToken: "stack-refresh" };
      },
      now: () => NOW,
    };
    const fenced = await handleIrohEnrollment(
      enrollRequest(JSON.stringify({ token: plaintext })),
      dependencies,
    );
    // Uniform unauthenticated failure: indistinguishable from an unknown or
    // spent token, and no Stack session is ever minted.
    expect(fenced.status).toBe(404);
    expect(await fenced.json()).toEqual({ error: "invalid_enrollment_token" });
    expect(mintedSessions).toHaveLength(0);

    // The fence aborts the transaction, so the conditional consume rolled
    // back and the token is still outstanding rather than silently burned.
    const [row] = await requiredSql()<Array<{ consumedAt: Date | null }>>`
      select consumed_at as "consumedAt" from iroh_enrollment_tokens
      where token_hash = ${sha256(plaintext)}
    `;
    expect(row?.consumedAt).toBeNull();

    // Once the deletion tombstone is gone (e.g. deletion failed and was
    // cleared), the same token redeems normally, proving the fence and not
    // token consumption produced the earlier refusal.
    await requiredSql()`delete from account_deletion_tombstones where user_id_hash = ${accountDeletionUserHash(userId)}`;
    const redeemed = await handleIrohEnrollment(
      enrollRequest(JSON.stringify({ token: plaintext })),
      dependencies,
    );
    expect(redeemed.status).toBe(201);
    expect(mintedSessions).toEqual([userId]);
  });
});

import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

process.env.SKIP_ENV_VALIDATION = "1";

const {
  NATIVE_SIGN_IN_CODE_TTL_MS,
  hashNativeSignInCode,
  isValidCodeChallenge,
  issueNativeSignInCode,
  redeemNativeSignInCode,
  s256CodeChallenge,
} = await import("../app/lib/native-sign-in-codes");
const { makeNativeTokenHandler } = await import("../app/api/native/token/handler");
type NativeSignInCodeRecord = import("../app/lib/native-sign-in-codes").NativeSignInCodeRecord;

const VERIFIER = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
// RFC 7636 appendix B.
const RFC_CHALLENGE = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";

/** An in-memory store with the Postgres store's contract: consume is atomic and honours expiry. */
function memoryStore() {
  const rows = new Map<string, NativeSignInCodeRecord>();
  return {
    rows,
    insert: async (record: NativeSignInCodeRecord) => {
      rows.set(record.codeHash, record);
    },
    consume: async (codeHash: string, now: Date) => {
      const record = rows.get(codeHash) ?? null;
      rows.delete(codeHash);
      return record && record.expiresAt > now ? record : null;
    },
  };
}

describe("native sign-in codes", () => {
  test("S256 matches RFC 7636's worked example", () => {
    expect(s256CodeChallenge(VERIFIER)).toBe(RFC_CHALLENGE);
    expect(isValidCodeChallenge(RFC_CHALLENGE)).toBe(true);
    expect(isValidCodeChallenge(VERIFIER.slice(1))).toBe(false);
  });

  test("issues a 256-bit code, stores only its hash, and expires within 60 seconds", async () => {
    const store = memoryStore();
    const now = 1_000_000;
    const code = await issueNativeSignInCode(store, { userId: "u1", codeChallenge: RFC_CHALLENGE, scheme: "cmux" }, () => now);

    expect(code).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(Buffer.from(code, "base64url")).toHaveLength(32);
    expect(store.rows.has(code)).toBe(false);
    const record = store.rows.get(hashNativeSignInCode(code))!;
    expect(record.userId).toBe("u1");
    expect(record.expiresAt.getTime() - now).toBe(NATIVE_SIGN_IN_CODE_TTL_MS);
    expect(NATIVE_SIGN_IN_CODE_TTL_MS).toBeLessThanOrEqual(60_000);
  });

  test("redeems once with the right verifier and scheme", async () => {
    const store = memoryStore();
    const code = await issueNativeSignInCode(store, { userId: "u1", codeChallenge: RFC_CHALLENGE, scheme: "cmux" });

    expect(await redeemNativeSignInCode(store, { code, codeVerifier: VERIFIER, scheme: "cmux" })).toEqual({ userId: "u1" });
    expect(await redeemNativeSignInCode(store, { code, codeVerifier: VERIFIER, scheme: "cmux" })).toBeNull();
  });

  test("a wrong verifier fails and burns the code", async () => {
    const store = memoryStore();
    const code = await issueNativeSignInCode(store, { userId: "u1", codeChallenge: RFC_CHALLENGE, scheme: "cmux" });

    expect(await redeemNativeSignInCode(store, { code, codeVerifier: `${VERIFIER.slice(0, -1)}A`, scheme: "cmux" })).toBeNull();
    expect(await redeemNativeSignInCode(store, { code, codeVerifier: VERIFIER, scheme: "cmux" })).toBeNull();
  });

  test("a different scheme fails and burns the code", async () => {
    const store = memoryStore();
    const code = await issueNativeSignInCode(store, { userId: "u1", codeChallenge: RFC_CHALLENGE, scheme: "cmux-next" });

    expect(await redeemNativeSignInCode(store, { code, codeVerifier: VERIFIER, scheme: "cmux" })).toBeNull();
    expect(await redeemNativeSignInCode(store, { code, codeVerifier: VERIFIER, scheme: "cmux-next" })).toBeNull();
  });

  test("an expired code fails", async () => {
    const store = memoryStore();
    let now = 5_000;
    const code = await issueNativeSignInCode(store, { userId: "u1", codeChallenge: RFC_CHALLENGE, scheme: "cmux" }, () => now);
    now += NATIVE_SIGN_IN_CODE_TTL_MS;

    expect(await redeemNativeSignInCode(store, { code, codeVerifier: VERIFIER, scheme: "cmux" }, () => now)).toBeNull();
  });

  test("malformed input never reaches the store", async () => {
    const store = memoryStore();
    const consume = mock(store.consume);
    for (const code of ["", "short", 42, null, "a".repeat(44)]) {
      expect(await redeemNativeSignInCode({ ...store, consume }, { code, codeVerifier: VERIFIER, scheme: "cmux" })).toBeNull();
    }
    expect(consume).not.toHaveBeenCalled();
  });

  test("refuses to issue for a malformed challenge", async () => {
    const store = memoryStore();
    await expect(issueNativeSignInCode(store, { userId: "u1", codeChallenge: "plain-text", scheme: "cmux" })).rejects.toThrow();
    expect(store.rows.size).toBe(0);
  });
});

describe("POST /api/native/token", () => {
  let store: ReturnType<typeof memoryStore>;
  const createSession = mock(async () => ({
    getTokens: async () => ({ refreshToken: "fresh-refresh", accessToken: "fresh-access" }),
  }));
  const getUserById = mock(async (userId: string) => (userId === "u1" ? { createSession } : null));

  beforeEach(() => {
    store = memoryStore();
    createSession.mockClear();
    getUserById.mockClear();
  });

  function handler() {
    return makeNativeTokenHandler({ store, getUserById });
  }

  function redeemRequest(body: unknown, headers: Record<string, string> = {}, origin = "https://cmux.test"): NextRequest {
    return new NextRequest(`${origin}/api/native/token`, {
      method: "POST",
      headers: { "content-type": "application/json", ...headers },
      body: typeof body === "string" ? body : JSON.stringify(body),
    });
  }

  async function issued(scheme = "cmux", userId = "u1") {
    return issueNativeSignInCode(store, { userId, codeChallenge: RFC_CHALLENGE, scheme });
  }

  test("mints the session at redemption and returns tokens only in the body", async () => {
    const code = await issued();

    const response = await handler()(redeemRequest({ code, code_verifier: VERIFIER, scheme: "cmux" }));

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("location")).toBeNull();
    expect(await response.json()).toEqual({ refresh_token: "fresh-refresh", access_token: "fresh-access" });
    expect(getUserById).toHaveBeenCalledWith("u1");
    expect(createSession).toHaveBeenCalledWith({ expiresInMillis: 30 * 24 * 60 * 60 * 1000 });
    expect(store.rows.size).toBe(0);
  });

  test("a second redemption of the same code is refused", async () => {
    const code = await issued();
    const body = { code, code_verifier: VERIFIER, scheme: "cmux" };
    expect((await handler()(redeemRequest(body))).status).toBe(200);

    const replay = await handler()(redeemRequest(body));

    expect(replay.status).toBe(400);
    expect(await replay.json()).toEqual({ error: "invalid_grant" });
    expect(createSession).toHaveBeenCalledTimes(1);
  });

  test("a PKCE mismatch is refused with the generic error and mints nothing", async () => {
    const code = await issued();

    const response = await handler()(redeemRequest({ code, code_verifier: "x".repeat(43), scheme: "cmux" }));

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_grant" });
    expect(createSession).not.toHaveBeenCalled();
    expect(store.rows.size).toBe(0);
  });

  test("a scheme mismatch is refused and mints nothing", async () => {
    const code = await issued("cmux-next");

    const response = await handler()(redeemRequest({ code, code_verifier: VERIFIER, scheme: "cmux" }));

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_grant" });
    expect(createSession).not.toHaveBeenCalled();
  });

  test("keeps production and staging schemes apart at redemption", async () => {
    const code = await issued("cmux-next-dev");

    const onProduction = await handler()(
      redeemRequest({ code, code_verifier: VERIFIER, scheme: "cmux-next-dev" }, {}, "https://cmux.com"),
    );

    expect(onProduction.status).toBe(400);
    expect(createSession).not.toHaveBeenCalled();
  });

  test("refuses non-JSON and malformed bodies", async () => {
    const code = await issued();
    const form = await handler()(
      redeemRequest(`code=${code}&code_verifier=${VERIFIER}&scheme=cmux`, { "content-type": "application/x-www-form-urlencoded" }),
    );
    expect(form.status).toBe(400);
    expect((await handler()(redeemRequest("not json"))).status).toBe(400);
    expect((await handler()(redeemRequest([code]))).status).toBe(400);
    expect((await handler()(redeemRequest({ code, code_verifier: VERIFIER, scheme: "cmux", pad: "x".repeat(5000) }))).status).toBe(400);
    expect(createSession).not.toHaveBeenCalled();
  });

  test("a code for a user who no longer exists mints nothing", async () => {
    const code = await issued("cmux", "gone");

    const response = await handler()(redeemRequest({ code, code_verifier: VERIFIER, scheme: "cmux" }));

    expect(response.status).toBe(400);
    expect(createSession).not.toHaveBeenCalled();
  });

  test("answers 503 without detail when storage fails", async () => {
    const failing = makeNativeTokenHandler({
      store: { insert: async () => undefined, consume: async () => { throw new Error("db down: secret detail"); } },
      getUserById,
    });

    const response = await failing(redeemRequest({ code: "a".repeat(43), code_verifier: VERIFIER, scheme: "cmux" }));

    expect(response.status).toBe(503);
    expect(await response.text()).not.toContain("secret detail");
  });
});

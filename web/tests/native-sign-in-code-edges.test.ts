import { afterEach, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import { NextRequest } from "next/server";

process.env.SKIP_ENV_VALIDATION = "1";

// Edge cases of the one-time code + PKCE hand-off that native-sign-in-codes.test.ts
// does not reach: verifier boundaries, expiry at the route on an injected clock,
// the put-back after a throttled mint, concurrent redemptions, and that no
// refusal or log line carries a code, verifier or token.

const {
  NATIVE_SIGN_IN_CODE_TTL_MS,
  issueNativeSignInCode,
  restoreNativeSignInCode,
  s256CodeChallenge,
} = await import("../app/lib/native-sign-in-codes");
const { makeNativeTokenHandler } = await import("../app/api/native/token/handler");
type NativeSignInCodeRecord = import("../app/lib/native-sign-in-codes").NativeSignInCodeRecord;

const ISSUER = "project-production";
const VERIFIER = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
const CHALLENGE = s256CodeChallenge(VERIFIER);
const REFRESH = "sentinel-refresh-token";
const ACCESS = "sentinel-access-token";
const T0 = Date.UTC(2026, 10, 22, 0, 0, 0);

/** The Postgres store's contract: consume is one atomic delete that honours expiry. */
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

function redeemRequest(body: unknown, headers: Record<string, string> = {}): NextRequest {
  return new NextRequest("https://cmux.test/api/native/token", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

describe("POST /api/native/token edges", () => {
  let store: ReturnType<typeof memoryStore>;
  let clock: number;
  const now = () => clock;
  const createSession = mock(async () => ({
    getTokens: async () => ({ refreshToken: REFRESH, accessToken: ACCESS }),
  }));
  const getUserById = mock(async (userId: string) => (userId === "u1" ? { createSession } : null));

  beforeEach(() => {
    store = memoryStore();
    clock = T0;
    createSession.mockClear();
    getUserById.mockClear();
  });

  function handler(overrides: Partial<Parameters<typeof makeNativeTokenHandler>[0]> = {}) {
    return makeNativeTokenHandler({ store, getUserById, issuer: ISSUER, now, ...overrides });
  }

  async function issued(codeChallenge = CHALLENGE) {
    return issueNativeSignInCode(store, { userId: "u1", codeChallenge, scheme: "cmux", issuer: ISSUER }, now);
  }

  async function expectRefused(response: Response) {
    expect(response.status).toBe(400);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("location")).toBeNull();
    // Every refusal is the same body, so a caller learns nothing about why.
    expect(await response.text()).toBe(JSON.stringify({ error: "invalid_grant" }));
  }

  describe("verifier shape", () => {
    test("accepts RFC 7636's shortest and longest verifiers", async () => {
      for (const verifier of ["a".repeat(43), "Az09-._~".repeat(16)]) {
        expect(verifier.length === 43 || verifier.length === 128).toBe(true);
        const code = await issued(s256CodeChallenge(verifier));
        const response = await handler()(redeemRequest({ code, code_verifier: verifier, scheme: "cmux" }));
        expect(response.status).toBe(200);
      }
      expect(createSession).toHaveBeenCalledTimes(2);
    });

    const badVerifiers: Array<[string, unknown]> = [
      ["missing", undefined],
      ["null", null],
      ["a number", 12345],
      ["42 characters", "a".repeat(42)],
      ["129 characters", "a".repeat(129)],
      ["a '+'", "a".repeat(42) + "+"],
      ["a '/'", "a".repeat(42) + "/"],
      ["a '='", "a".repeat(42) + "="],
      ["a space", "a".repeat(42) + " "],
      ["non-ASCII", "a".repeat(42) + "é"],
    ];
    for (const [name, verifier] of badVerifiers) {
      test(`a verifier that is ${name} is refused and burns the code`, async () => {
        // The challenge matches the verifier where one can be computed, so only its shape is wrong.
        const challenge = typeof verifier === "string" ? s256CodeChallenge(verifier) : CHALLENGE;
        const code = await issued(challenge);
        const body: Record<string, unknown> = { code, scheme: "cmux" };
        if (verifier !== undefined) body.code_verifier = verifier;

        await expectRefused(await handler()(redeemRequest(body)));

        expect(store.rows.size).toBe(0);
        expect(createSession).not.toHaveBeenCalled();
        // The right verifier afterwards cannot bring the code back.
        await expectRefused(await handler()(redeemRequest({ code, code_verifier: VERIFIER, scheme: "cmux" })));
      });
    }

    test("the challenge's own value sent as the verifier is refused", async () => {
      const code = await issued();
      await expectRefused(await handler()(redeemRequest({ code, code_verifier: CHALLENGE, scheme: "cmux" })));
      expect(createSession).not.toHaveBeenCalled();
    });
  });

  describe("expiry on the route's clock", () => {
    test("redeems one millisecond before the code's 60 seconds are up", async () => {
      const code = await issued();
      clock = T0 + NATIVE_SIGN_IN_CODE_TTL_MS - 1;
      const response = await handler()(redeemRequest({ code, code_verifier: VERIFIER, scheme: "cmux" }));
      expect(response.status).toBe(200);
    });

    test("refuses at exactly 60 seconds and mints nothing", async () => {
      const code = await issued();
      clock = T0 + NATIVE_SIGN_IN_CODE_TTL_MS;
      await expectRefused(await handler()(redeemRequest({ code, code_verifier: VERIFIER, scheme: "cmux" })));
      expect(createSession).not.toHaveBeenCalled();
    });

    test("a store that returns an expired row is still refused by the route", async () => {
      // Defence in depth: the store's own expiry filter is not the only check.
      const code = await issued();
      const leaky = {
        insert: store.insert,
        consume: async (codeHash: string) => {
          const record = store.rows.get(codeHash) ?? null;
          store.rows.delete(codeHash);
          return record;
        },
      };
      clock = T0 + NATIVE_SIGN_IN_CODE_TTL_MS + 1;
      await expectRefused(await handler({ store: leaky })(redeemRequest({ code, code_verifier: VERIFIER, scheme: "cmux" })));
      expect(createSession).not.toHaveBeenCalled();
    });
  });

  describe("the put-back after a throttled mint", () => {
    const throttled = () => Object.assign(new Error("Stack Auth rate limited"), { status: 429 });

    function flakyHandler(failures: number) {
      let left = failures;
      return handler({
        getUserById: async () => ({
          createSession: async () => {
            if (left > 0) {
              left -= 1;
              throw throttled();
            }
            return createSession();
          },
        }),
      });
    }

    test("keeps the code's original expiry, so a retry after it is refused", async () => {
      const code = await issued();
      const flaky = flakyHandler(1);
      const body = { code, code_verifier: VERIFIER, scheme: "cmux" };

      clock = T0 + 30_000;
      expect((await flaky(redeemRequest(body))).status).toBe(429);
      expect([...store.rows.values()][0]?.expiresAt.getTime()).toBe(T0 + NATIVE_SIGN_IN_CODE_TTL_MS);

      clock = T0 + NATIVE_SIGN_IN_CODE_TTL_MS;
      await expectRefused(await flaky(redeemRequest(body)));
      expect(createSession).not.toHaveBeenCalled();
    });

    test("a code put back and then redeemed cannot be redeemed a third time", async () => {
      const code = await issued();
      const flaky = flakyHandler(1);
      const body = { code, code_verifier: VERIFIER, scheme: "cmux" };

      expect((await flaky(redeemRequest(body))).status).toBe(429);
      expect((await flaky(redeemRequest(body))).status).toBe(200);
      await expectRefused(await flaky(redeemRequest(body)));
      expect(createSession).toHaveBeenCalledTimes(1);
    });

    test("a put-back code still refuses a wrong verifier, and that burns it", async () => {
      const code = await issued();
      const flaky = flakyHandler(1);

      expect((await flaky(redeemRequest({ code, code_verifier: VERIFIER, scheme: "cmux" }))).status).toBe(429);
      await expectRefused(await flaky(redeemRequest({ code, code_verifier: "b".repeat(43), scheme: "cmux" })));
      await expectRefused(await flaky(redeemRequest({ code, code_verifier: VERIFIER, scheme: "cmux" })));
      expect(createSession).not.toHaveBeenCalled();
    });

    test("restoring an already expired record stores nothing", async () => {
      await restoreNativeSignInCode(
        store,
        { codeHash: "h", codeChallenge: CHALLENGE, scheme: "cmux", userId: "u1", issuer: ISSUER, expiresAt: new Date(T0) },
        now,
      );
      expect(store.rows.size).toBe(0);
    });

    test("a session with no access token answers the generic refusal and puts nothing back", async () => {
      const code = await issued();
      const partial = handler({
        getUserById: async () => ({
          createSession: async () => ({ getTokens: async () => ({ refreshToken: REFRESH, accessToken: null }) }),
        }),
      });
      const response = await partial(redeemRequest({ code, code_verifier: VERIFIER, scheme: "cmux" }));
      await expectRefused(response);
      expect(store.rows.size).toBe(0);
    });
  });

  describe("concurrency", () => {
    test("two redemptions of one code racing each other mint one session", async () => {
      const code = await issued();
      const body = { code, code_verifier: VERIFIER, scheme: "cmux" };

      const responses = await Promise.all([handler()(redeemRequest(body)), handler()(redeemRequest(body))]);

      expect(responses.map((response) => response.status).sort()).toEqual([200, 400]);
      expect(createSession).toHaveBeenCalledTimes(1);
    });

    test("an attacker's wrong-verifier attempt burns the code for the app too", async () => {
      // Single use wins over availability: an intercepted code is worthless without the verifier,
      // and a guess costs the app this attempt, never the account.
      const code = await issued();
      await expectRefused(await handler()(redeemRequest({ code, code_verifier: "c".repeat(43), scheme: "cmux" })));
      await expectRefused(await handler()(redeemRequest({ code, code_verifier: VERIFIER, scheme: "cmux" })));
      expect(createSession).not.toHaveBeenCalled();
    });
  });

  describe("request shape", () => {
    test("a declared body over 4 KiB is refused before the code is touched", async () => {
      const code = await issued();
      const response = await handler()(
        redeemRequest({ code, code_verifier: VERIFIER, scheme: "cmux" }, { "content-length": String(4 * 1024 + 1) }),
      );
      await expectRefused(response);
      // The code was never consumed: the app's real request can still redeem it.
      expect(store.rows.size).toBe(1);
    });

    test("a scheme the deployment does not allow is refused before the code is touched", async () => {
      const code = await issued();
      await expectRefused(await handler()(redeemRequest({ code, code_verifier: VERIFIER, scheme: "https" })));
      await expectRefused(await handler()(redeemRequest({ code, code_verifier: VERIFIER, scheme: "cmux-next-dev" })));
      expect(store.rows.size).toBe(1);
    });

    test("a code sent as another JSON type, or with padding, never matches", async () => {
      const code = await issued();
      for (const sent of [[code], { code }, ` ${code}`, `${code}=`, code.toUpperCase()]) {
        await expectRefused(await handler()(redeemRequest({ code: sent, code_verifier: VERIFIER, scheme: "cmux" })));
      }
      // None of those reached the stored row.
      expect((await handler()(redeemRequest({ code, code_verifier: VERIFIER, scheme: "cmux" }))).status).toBe(200);
    });

    test("tokens travel only in the body: no cookie, no redirect", async () => {
      const code = await issued();
      const response = await handler()(redeemRequest({ code, code_verifier: VERIFIER, scheme: "cmux" }));
      expect(response.status).toBe(200);
      expect(response.headers.get("set-cookie")).toBeNull();
      expect(response.headers.get("location")).toBeNull();
      expect(response.headers.get("pragma")).toBe("no-cache");
      for (const [, value] of response.headers) {
        expect(value).not.toContain(REFRESH);
        expect(value).not.toContain(ACCESS);
      }
    });
  });

  describe("nothing secret in logs", () => {
    let errors: ReturnType<typeof spyOn>;
    let warns: ReturnType<typeof spyOn>;
    let logs: ReturnType<typeof spyOn>;

    beforeEach(() => {
      errors = spyOn(console, "error").mockImplementation(() => undefined);
      warns = spyOn(console, "warn").mockImplementation(() => undefined);
      logs = spyOn(console, "log").mockImplementation(() => undefined);
    });

    afterEach(() => {
      errors.mockRestore();
      warns.mockRestore();
      logs.mockRestore();
    });

    function logged(): string {
      return [errors, warns, logs]
        .flatMap((spy) => spy.mock.calls)
        .map((call) => call.map((part: unknown) => (part instanceof Error ? `${part.message} ${part.stack}` : JSON.stringify(part))).join(" "))
        .join("\n");
    }

    test("no failure path logs the code, the verifier or a token", async () => {
      const failures = [
        handler({ store: { insert: store.insert, consume: async () => { throw new Error("db down"); } } }),
        handler({
          getUserById: async () => ({
            createSession: async () => {
              throw Object.assign(new Error("rate limited"), { status: 429 });
            },
          }),
        }),
        handler({
          getUserById: async () => {
            throw new Error("lookup failed");
          },
        }),
        handler(),
      ];
      const codes: string[] = [];
      for (const failing of failures) {
        const code = await issued();
        codes.push(code);
        await failing(redeemRequest({ code, code_verifier: VERIFIER, scheme: "cmux" }));
        await handler()(redeemRequest({ code, code_verifier: "d".repeat(43), scheme: "cmux" }));
      }

      const text = logged();
      expect(errors).toHaveBeenCalled();
      for (const code of codes) expect(text).not.toContain(code);
      expect(text).not.toContain(VERIFIER);
      expect(text).not.toContain(REFRESH);
      expect(text).not.toContain(ACCESS);
    });
  });
});

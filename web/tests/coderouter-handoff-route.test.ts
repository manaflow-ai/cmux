import { describe, expect, mock, test } from "bun:test";

process.env.SKIP_ENV_VALIDATION = "1";
process.env.SUBROUTER_ALLOWED_TEAM_IDS = "*";
process.env.SUBROUTER_ENFORCE_STACK_PERMISSIONS = "1";

const { makeCoderouterHandoffPostHandler } = await import(
  "../app/api/coderouter/handoff/route"
);
const { makeCoderouterHandoffExchangePostHandler } = await import(
  "../app/api/coderouter/handoff/exchange/route"
);
const {
  coderouterOpenaiBaseUrl,
  makeCoderouterHandoffRateLimiter,
  validTeamSelectorHeaders,
} = await import("../app/api/coderouter/handoff/_shared");
const {
  CodeRouterHandoffEntitlementDenied,
  handoffLeaseHash,
  isValidCoderouterHandoffLease,
} = await import("../services/coderouter/repository");
const { AccountDeletionMutationBlockedError } = await import(
  "../services/account/deletionLock"
);

const LEASE = "crh_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ";
const EXPIRES_AT = new Date("2026-08-13T12:02:00.000Z");
const context = {
  ok: true as const,
  value: {
    user: { id: "user_1" },
    team: {
      teamId: "team_1",
      teamName: "Team",
      use: true,
      manageAccounts: false,
    },
  },
};

function nativeHeaders(extra: Record<string, string> = {}): Record<string, string> {
  return {
    authorization: "Bearer stack-access",
    "x-stack-refresh-token": "stack-refresh",
    "x-cmux-team-id": "team_1",
    ...extra,
  };
}

function mintRequest(
  init: RequestInit = {},
): Request {
  const headers = new Headers(nativeHeaders({
    "content-type": "application/json",
  }));
  new Headers(init.headers).forEach((value, name) => {
    headers.set(name, value);
  });
  return new Request("https://cmux.test/api/coderouter/handoff", {
    ...init,
    method: init.method ?? "POST",
    headers,
  });
}

function exchangeRequest(
  lease = LEASE,
  headers: Record<string, string> = {},
): Request {
  return new Request("https://cmux.test/api/coderouter/handoff/exchange", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...headers,
    },
    body: JSON.stringify({ lease }),
  });
}

function allowedRateLimit() {
  return async () => "allowed" as const;
}

describe("CodeRouter native handoff mint", () => {
  test("rejects cookie-only callers before resolving a browser session", async () => {
    const resolveContext = mock(async () => context);
    const POST = makeCoderouterHandoffPostHandler({
      resolveContext: resolveContext as never,
      hasActiveEntitlement: mock(async () => true),
      issueLease: mock(async () => ({ lease: LEASE, expiresAt: EXPIRES_AT })),
      hostedProRequired: () => false,
      rateLimit: allowedRateLimit(),
    });

    const response = await POST(new Request(
      "https://cmux.test/api/coderouter/handoff",
      {
        method: "POST",
        headers: { cookie: "hexclave-access=browser-session" },
      },
    ));

    expect(response.status).toBe(401);
    expect(resolveContext).not.toHaveBeenCalled();
  });

  test("rejects an incomplete or oversized native token pair", async () => {
    const resolveContext = mock(async () => context);
    const POST = makeCoderouterHandoffPostHandler({
      resolveContext: resolveContext as never,
      hasActiveEntitlement: mock(async () => true),
      issueLease: mock(async () => ({ lease: LEASE, expiresAt: EXPIRES_AT })),
      hostedProRequired: () => false,
      rateLimit: allowedRateLimit(),
    });

    const incomplete = await POST(mintRequest({
      headers: { "x-stack-refresh-token": "" },
    }));
    const oversized = await POST(mintRequest({
      headers: {
        "x-stack-refresh-token": "x".repeat(16 * 1024 + 1),
      },
    }));

    expect(incomplete.status).toBe(401);
    expect(oversized.status).toBe(401);
    expect(resolveContext).not.toHaveBeenCalled();
  });

  test("enforces the existing use and hosted entitlement gates", async () => {
    const issueLease = mock(async () => ({
      lease: LEASE,
      expiresAt: EXPIRES_AT,
    }));
    const forbidden = makeCoderouterHandoffPostHandler({
      resolveContext: mock(async () => ({
        ok: true as const,
        value: {
          ...context.value,
          team: { ...context.value.team, use: false },
        },
      })) as never,
      hasActiveEntitlement: mock(async () => true),
      issueLease,
      hostedProRequired: () => true,
      rateLimit: allowedRateLimit(),
    });
    const noEntitlement = makeCoderouterHandoffPostHandler({
      resolveContext: mock(async () => context) as never,
      hasActiveEntitlement: mock(async () => false),
      issueLease,
      hostedProRequired: () => true,
      rateLimit: allowedRateLimit(),
    });

    expect((await forbidden(mintRequest())).status).toBe(403);
    expect((await noEntitlement(mintRequest())).status).toBe(402);
    expect(issueLease).not.toHaveBeenCalled();
  });

  test("passes a transaction-bound entitlement recheck to lease issuance", async () => {
    const entitlementDb = {};
    const hasActiveEntitlement = mock(async () => true);
    const issueLease = mock(async () => {
      return { lease: LEASE, expiresAt: EXPIRES_AT };
    });
    const POST = makeCoderouterHandoffPostHandler({
      resolveContext: mock(async () => context) as never,
      hasActiveEntitlement,
      issueLease: issueLease as never,
      hostedProRequired: () => true,
      rateLimit: allowedRateLimit(),
    });

    const response = await POST(mintRequest());

    expect(response.status).toBe(200);
    const issueCalls = (issueLease as unknown as {
      mock: { calls: unknown[][] };
    }).mock.calls;
    const authorizeCallback = issueCalls[0]?.[3] as
      | ((
        identity: { teamId: string; stackUserId: string },
        db: unknown,
      ) => Promise<boolean>)
      | undefined;
    expect(authorizeCallback).toBeDefined();
    expect(
      await authorizeCallback!(
        { teamId: "team_1", stackUserId: "user_1" },
        entitlementDb,
      ),
    ).toBe(true);
    expect(hasActiveEntitlement).toHaveBeenLastCalledWith(
      "user_1",
      "team_1",
      entitlementDb,
    );
  });

  test("returns account_deletion_in_progress when mint loses the deletion lock", async () => {
    const issueLease = mock(async () => {
      throw new AccountDeletionMutationBlockedError("user_1");
    });
    const POST = makeCoderouterHandoffPostHandler({
      resolveContext: mock(async () => context) as never,
      hasActiveEntitlement: mock(async () => true),
      issueLease: issueLease as never,
      hostedProRequired: () => false,
      rateLimit: allowedRateLimit(),
    });

    const response = await POST(mintRequest());

    expect(response.status).toBe(409);
    await expect(response.json()).resolves.toEqual({
      error: "account_deletion_in_progress",
      retryable: false,
    });
  });

  test("returns pro_required when the serialized entitlement recheck lapses", async () => {
    const issueLease = mock(async () => {
      throw new CodeRouterHandoffEntitlementDenied("lapsed");
    });
    const POST = makeCoderouterHandoffPostHandler({
      resolveContext: mock(async () => context) as never,
      hasActiveEntitlement: mock(async () => true),
      issueLease: issueLease as never,
      hostedProRequired: () => true,
      rateLimit: allowedRateLimit(),
    });

    const response = await POST(mintRequest());

    expect(response.status).toBe(402);
    await expect(response.json()).resolves.toEqual({
      error: "pro_required",
      retryable: false,
    });
  });

  test("returns the opaque lease with no-store and never changes the request body contract", async () => {
    const issueLease = mock(async () => {
      return { lease: LEASE, expiresAt: EXPIRES_AT };
    });
    const POST = makeCoderouterHandoffPostHandler({
      resolveContext: mock(async () => context) as never,
      hasActiveEntitlement: mock(async () => true),
      issueLease: issueLease as never,
      hostedProRequired: () => false,
      rateLimit: allowedRateLimit(),
      now: () => new Date("2026-08-13T12:00:00.000Z"),
    });

    const response = await POST(mintRequest({ body: "{}" }));

    expect(response.status).toBe(200);
    const issueCalls = (issueLease as unknown as {
      mock: { calls: unknown[][] };
    }).mock.calls;
    expect(issueCalls[0]).toEqual([
      "team_1",
      "user_1",
      new Date("2026-08-13T12:00:00.000Z"),
    ]);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("referrer-policy")).toBe("no-referrer");
    await expect(response.json()).resolves.toEqual({
      teamId: "team_1",
      lease: LEASE,
      expiresAt: EXPIRES_AT.toISOString(),
    });
  });
});

describe("CodeRouter native handoff exchange", () => {
  test("exchanges a lease without requiring Stack credentials", async () => {
    const exchangeLease = mock(async () => {
      return {
        teamId: "team_1",
        stackUserId: "user_1",
        token: "crt_route_token_value",
        expiresAt: new Date("2026-09-12T12:00:00.000Z"),
      };
    });
    const hasActiveEntitlement = mock(async () => true);
    const POST = makeCoderouterHandoffExchangePostHandler({
      exchangeLease: exchangeLease as never,
      resolveContext: mock(async () => context) as never,
      hasActiveEntitlement,
      hostedProRequired: () => true,
      rateLimit: allowedRateLimit(),
      publicOrigin: () => "https://coderouter.dev",
    });

    const response = await POST(exchangeRequest());

    expect(response.status).toBe(200);
    // Possession-only exchange must not perform the native entitlement gate;
    // the callback is only supplied for the repository's stored-principal
    // recheck immediately before the atomic claim.
    expect(hasActiveEntitlement).not.toHaveBeenCalled();
    const exchangeCalls = (exchangeLease as unknown as {
      mock: { calls: unknown[][] };
    }).mock.calls;
    expect(exchangeCalls[0]?.[0]).toBe(LEASE);
    expect(exchangeCalls[0]?.[2]).toEqual({});
    expect(typeof exchangeCalls[0]?.[3]).toBe("function");
    const authorizeCallback = exchangeCalls[0]?.[3] as
      | ((
        identity: { teamId: string; stackUserId: string },
        db: unknown,
      ) => Promise<boolean>)
      | undefined;
    expect(authorizeCallback).toBeDefined();
    expect(
      await authorizeCallback!(
        { teamId: "team_1", stackUserId: "user_1" },
        {},
      ),
    ).toBe(true);
    expect(hasActiveEntitlement).toHaveBeenCalledWith("user_1", "team_1", {});
    await expect(response.json()).resolves.toMatchObject({
      teamId: "team_1",
      token: "crt_route_token_value",
      openaiBaseUrl: "https://coderouter.dev/v1",
    });
  });

  test("fails closed before consuming a lease when deployed origin is missing", async () => {
    const exchangeLease = mock(async () => {
      throw new Error("repository must not be reached");
    });
    const previousVercel = process.env.VERCEL;
    process.env.VERCEL = "1";
    try {
      const POST = makeCoderouterHandoffExchangePostHandler({
        exchangeLease,
        resolveContext: mock(async () => context) as never,
        hasActiveEntitlement: mock(async () => true),
        hostedProRequired: () => false,
        rateLimit: allowedRateLimit(),
        publicOrigin: () => undefined,
      });

      const response = await POST(exchangeRequest());

      expect(response.status).toBe(503);
      expect(exchangeLease).not.toHaveBeenCalled();
    } finally {
      if (previousVercel === undefined) {
        delete process.env.VERCEL;
      } else {
        process.env.VERCEL = previousVercel;
      }
    }
  });

  test("does not treat a browser cookie as native exchange authorization", async () => {
    const exchangeLease = mock(async () => {
      throw new Error("repository must not be reached");
    });
    const POST = makeCoderouterHandoffExchangePostHandler({
      exchangeLease,
      resolveContext: mock(async () => context) as never,
      hasActiveEntitlement: mock(async () => true),
      hostedProRequired: () => false,
      rateLimit: allowedRateLimit(),
    });

    const response = await POST(exchangeRequest(
      LEASE,
      { cookie: "hexclave-access=browser-session" },
    ));

    expect(response.status).toBe(401);
    expect(exchangeLease).not.toHaveBeenCalled();
  });

  test("optionally binds a native-confirmed exchange to the same principal", async () => {
    const exchangeLease = mock(async () => null);
    const POST = makeCoderouterHandoffExchangePostHandler({
      exchangeLease: exchangeLease as never,
      resolveContext: mock(async () => context) as never,
      hasActiveEntitlement: mock(async () => true),
      hostedProRequired: () => false,
      rateLimit: allowedRateLimit(),
    });

    const response = await POST(exchangeRequest(LEASE, nativeHeaders()));

    expect(response.status).toBe(401);
    const exchangeCalls = (exchangeLease as unknown as {
      mock: { calls: unknown[][] };
    }).mock.calls;
    expect(exchangeCalls[0]?.[2]).toEqual({
      teamId: "team_1",
      stackUserId: "user_1",
    });
    expect((await response.json()).error).toBe("invalid_handoff_lease");
  });

  test("treats replay, expiry, and identity mismatch as one generic failure", async () => {
    let consumed = false;
    const exchangeLease = mock(async () => {
      if (consumed) return null;
      consumed = true;
      return {
        teamId: "team_1",
        stackUserId: "user_1",
        token: "crt_once",
        expiresAt: EXPIRES_AT,
      };
    });
    const POST = makeCoderouterHandoffExchangePostHandler({
      exchangeLease,
      resolveContext: mock(async () => context) as never,
      hasActiveEntitlement: mock(async () => true),
      hostedProRequired: () => false,
      rateLimit: allowedRateLimit(),
    });

    const [first, replay] = await Promise.all([
      POST(exchangeRequest()),
      POST(exchangeRequest()),
    ]);
    expect([first.status, replay.status].sort()).toEqual([200, 401]);

    const expired = makeCoderouterHandoffExchangePostHandler({
      exchangeLease: mock(async () => null),
      resolveContext: mock(async () => context) as never,
      hasActiveEntitlement: mock(async () => true),
      hostedProRequired: () => false,
      rateLimit: allowedRateLimit(),
    });
    expect((await expired(exchangeRequest())).status).toBe(401);
  });

  test("bounds and validates the lease body before touching the repository", async () => {
    const exchangeLease = mock(async () => null);
    const POST = makeCoderouterHandoffExchangePostHandler({
      exchangeLease,
      resolveContext: mock(async () => context) as never,
      hasActiveEntitlement: mock(async () => true),
      hostedProRequired: () => false,
      rateLimit: allowedRateLimit(),
    });

    const malformed = await POST(exchangeRequest("crh_bad"));
    const wrongContentType = await POST(new Request(
      "https://cmux.test/api/coderouter/handoff/exchange",
      {
        method: "POST",
        headers: { "content-type": "application/jsonp" },
        body: JSON.stringify({ lease: LEASE }),
      },
    ));
    const oversized = await POST(new Request(
      "https://cmux.test/api/coderouter/handoff/exchange",
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "content-length": String(2 * 1024 + 1),
        },
        body: JSON.stringify({ lease: LEASE }),
      },
    ));

    expect(malformed.status).toBe(400);
    expect(wrongContentType.status).toBe(400);
    expect(oversized.status).toBe(413);
    expect(exchangeLease).not.toHaveBeenCalled();
  });
});

describe("CodeRouter handoff secret representation", () => {
  test("uses exact opaque syntax and a fixed-length digest", () => {
    expect(isValidCoderouterHandoffLease(LEASE)).toBe(true);
    expect(isValidCoderouterHandoffLease(`${LEASE} `)).toBe(false);
    expect(isValidCoderouterHandoffLease("crh_short")).toBe(false);
    expect(handoffLeaseHash(LEASE)).toMatch(/^[0-9a-f]{64}$/);
    expect(handoffLeaseHash(LEASE)).not.toContain(LEASE);
  });

  test("uses a trusted configured data-plane origin instead of the request host", () => {
    const request = new Request(
      "https://attacker.example/api/coderouter/handoff/exchange",
    );
    expect(coderouterOpenaiBaseUrl(request, "https://coderouter.dev"))
      .toBe("https://coderouter.dev/v1");

    const previousVercel = process.env.VERCEL;
    process.env.VERCEL = "1";
    try {
      expect(coderouterOpenaiBaseUrl(request, "https://coderouter.dev/path"))
        .toBeNull();
      expect(coderouterOpenaiBaseUrl(request)).toBeNull();
    } finally {
      if (previousVercel === undefined) {
        delete process.env.VERCEL;
      } else {
        process.env.VERCEL = previousVercel;
      }
    }
  });

  test("rejects ambiguous team selectors before Stack resolves a team", () => {
    expect(validTeamSelectorHeaders(new Request(
      "https://cmux.test/api/coderouter/handoff?teamId=team_1&team_id=team_2",
    ))).toBe(false);
    expect(validTeamSelectorHeaders(new Request(
      "https://cmux.test/api/coderouter/handoff?teamId=team_1&teamId=team_1",
    ))).toBe(true);
    expect(validTeamSelectorHeaders(new Request(
      "https://cmux.test/api/coderouter/handoff?teamId=team_1&teamId=team_2",
    ))).toBe(false);
    expect(validTeamSelectorHeaders(new Request(
      "https://cmux.test/api/coderouter/handoff?teamId=team_1",
      { headers: { "x-cmux-team-id": "team_2" } },
    ))).toBe(false);
    expect(validTeamSelectorHeaders(new Request(
      "https://cmux.test/api/coderouter/handoff?teamId=team_1",
      { headers: { "x-cmux-team-id": "team_1" } },
    ))).toBe(true);
    expect(validTeamSelectorHeaders(new Request(
      "https://cmux.test/api/coderouter/handoff",
      {
        headers: [
          ["x-cmux-team-id", "team_1"],
          ["x-cmux-team-id", "team_1"],
        ],
      },
    ))).toBe(true);
    expect(validTeamSelectorHeaders(new Request(
      "https://cmux.test/api/coderouter/handoff",
      {
        headers: [
          ["x-cmux-team-id", "team_1"],
          ["x-cmux-team-id", "team_2"],
        ],
      },
    ))).toBe(false);
  });
});

describe("CodeRouter handoff rate limiting", () => {
  test("fails closed when durable production limiting is absent or unavailable", async () => {
    const checkRateLimit = mock(async () => ({
      rateLimited: false,
      error: "firewall-unavailable",
    }));
    const request = exchangeRequest();
    const unavailable = makeCoderouterHandoffRateLimiter({
      isVercel: () => true,
      rateLimitId: () => "coderouter-handoff",
      checkRateLimit: checkRateLimit as never,
    });
    const missing = makeCoderouterHandoffRateLimiter({
      isVercel: () => true,
      checkRateLimit: checkRateLimit as never,
    });

    expect(await unavailable(request)).toBe("unavailable");
    expect(await missing(request)).toBe("unavailable");
  });

  test("does not pass token-derived keys to the durable limiter", async () => {
    const checkRateLimit = mock(async () => ({
      rateLimited: false,
      error: null,
    }));
    const limiter = makeCoderouterHandoffRateLimiter({
      isVercel: () => true,
      rateLimitId: () => "coderouter-handoff",
      checkRateLimit: checkRateLimit as never,
    });

    expect(await limiter(exchangeRequest())).toBe("allowed");
    expect(checkRateLimit).toHaveBeenCalledTimes(1);
    const options = (checkRateLimit as unknown as {
      mock: { calls: unknown[][] };
    }).mock.calls[0]?.[1] as { request?: unknown };
    expect(Object.keys(options)).toEqual(["request"]);
    expect(options.request).toBeInstanceOf(Request);
  });

  test("keeps a bounded local development backstop", async () => {
    let now = 1_000;
    const limiter = makeCoderouterHandoffRateLimiter({
      isVercel: () => false,
      now: () => now,
    });
    for (let index = 0; index < 60; index += 1) {
      expect(await limiter(exchangeRequest())).toBe("allowed");
    }
    expect(await limiter(exchangeRequest())).toBe("limited");
    now += 60_001;
    expect(await limiter(exchangeRequest())).toBe("allowed");
  });
});

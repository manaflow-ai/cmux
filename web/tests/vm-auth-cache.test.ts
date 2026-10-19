import {
  afterEach,
  beforeEach,
  describe,
  expect,
  mock,
  setSystemTime,
  test,
} from "bun:test";

const getUser = mock(async (): Promise<unknown> => null);

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

const {
  verifyRequest,
  clearNativeAuthCacheForTests,
  clearStackThrottleCircuitForTests,
  invalidateNativeAuthCacheForTokens,
} = await import("../services/vms/auth");

const fakeStackUser = {
  id: "user-1",
  displayName: "Test User",
  primaryEmail: "test@example.com",
  selectedTeam: null,
  clientReadOnlyMetadata: {},
  listTeams: async () => [],
};

function nativeRequest(access: string, refresh = "refresh-1"): Request {
  return new Request("https://cmux.test/api/vm", {
    headers: {
      authorization: `Bearer ${access}`,
      "x-stack-refresh-token": refresh,
    },
  });
}

const originalTtl = process.env.CMUX_VM_AUTH_CACHE_TTL_MS;

beforeEach(() => {
  clearNativeAuthCacheForTests();
  clearStackThrottleCircuitForTests();
  getUser.mockClear();
  getUser.mockResolvedValue(fakeStackUser);
  delete process.env.CMUX_VM_AUTH_CACHE_TTL_MS;
});

afterEach(() => {
  setSystemTime();
  if (originalTtl === undefined) delete process.env.CMUX_VM_AUTH_CACHE_TTL_MS;
  else process.env.CMUX_VM_AUTH_CACHE_TTL_MS = originalTtl;
});

describe("native auth verification cache", () => {
  test("a burst of identical native requests verifies with Stack once", async () => {
    const first = await verifyRequest(nativeRequest("access-1"));
    const second = await verifyRequest(nativeRequest("access-1"));
    const third = await verifyRequest(nativeRequest("access-1"));

    expect(first?.id).toBe("user-1");
    expect(second?.id).toBe("user-1");
    expect(third?.id).toBe("user-1");
    expect(getUser).toHaveBeenCalledTimes(1);
  });

  test("different tokens never share a cache entry", async () => {
    await verifyRequest(nativeRequest("access-1"));
    await verifyRequest(nativeRequest("access-2"));

    expect(getUser).toHaveBeenCalledTimes(2);
  });

  test("requested team id is part of the cache identity", async () => {
    await verifyRequest(nativeRequest("access-1"), { requestedTeamId: "team-a" });
    await verifyRequest(nativeRequest("access-1"), { requestedTeamId: "team-b" });

    expect(getUser).toHaveBeenCalledTimes(2);
  });

  test("failed verification is not cached", async () => {
    getUser.mockResolvedValue(null);

    expect(await verifyRequest(nativeRequest("access-1"))).toBeNull();
    expect(await verifyRequest(nativeRequest("access-1"))).toBeNull();
    expect(getUser).toHaveBeenCalledTimes(2);

    // The user signs in successfully right after: the earlier failure must not mask it.
    getUser.mockResolvedValue(fakeStackUser);
    const authed = await verifyRequest(nativeRequest("access-1"));
    expect(authed?.id).toBe("user-1");
  });

  test("CMUX_VM_AUTH_CACHE_TTL_MS=0 disables caching", async () => {
    process.env.CMUX_VM_AUTH_CACHE_TTL_MS = "0";

    await verifyRequest(nativeRequest("access-1"));
    await verifyRequest(nativeRequest("access-1"));

    expect(getUser).toHaveBeenCalledTimes(2);
  });

  test("entries expire after the TTL", async () => {
    process.env.CMUX_VM_AUTH_CACHE_TTL_MS = "20";
    setSystemTime(0);
    await verifyRequest(nativeRequest("access-1"));
    setSystemTime(21);
    await verifyRequest(nativeRequest("access-1"));

    expect(getUser).toHaveBeenCalledTimes(2);
  });

  test("explicit sign-out revocation invalidates cached native credentials", async () => {
    await verifyRequest(nativeRequest("access-1", "refresh-1"));
    invalidateNativeAuthCacheForTokens({ accessToken: "access-1", refreshToken: "refresh-1" });
    await verifyRequest(nativeRequest("access-1", "refresh-1"));

    expect(getUser).toHaveBeenCalledTimes(2);
  });

  test("cookie-only requests bypass the cache entirely", async () => {
    const cookieRequest = new Request("https://cmux.test/api/vm", {
      headers: { cookie: "stack-session=abc" },
    });
    await verifyRequest(cookieRequest);
    await verifyRequest(cookieRequest);

    expect(getUser).toHaveBeenCalledTimes(2);
  });
});


// bun's MockFunction typing in this tree lacks the *Once variants; the
// devices-route test uses the same cast.
function failStackOnce(error: unknown): void {
  (getUser as unknown as {
    mockImplementationOnce(implementation: () => Promise<never>): void;
  }).mockImplementationOnce(async () => {
    throw error;
  });
}

describe("Stack Auth throttle circuit", () => {
  // Fake clocks far in the future so an opened circuit can never leak into
  // the cache tests above, which run at epoch 0.
  const BASE = 4_000_000_000_000;

  test("a Stack throttle opens a short circuit so native retries stop hitting Stack", async () => {
    setSystemTime(BASE);
    failStackOnce(new AggregateError([
        new Error("Rate limited, no retry-after header received"),
      ]));

    await expect(verifyRequest(nativeRequest("throttled-1"))).rejects.toThrow(/rate limited/i);
    await expect(verifyRequest(nativeRequest("throttled-2"))).rejects.toThrow(/rate limited/i);
    expect(getUser).toHaveBeenCalledTimes(1);

    setSystemTime(BASE + 10_001);
    const user = await verifyRequest(nativeRequest("throttled-2"));
    expect(user?.id).toBe("user-1");
    expect(getUser).toHaveBeenCalledTimes(2);
  });

  test("requests rejected by the open circuit do not extend it", async () => {
    setSystemTime(BASE + 30_000);
    failStackOnce(new AggregateError([
      new Error("Rate limited, no retry-after header received"),
    ]));
    await expect(verifyRequest(nativeRequest("extend-1"))).rejects.toThrow(/rate limited/i);

    setSystemTime(BASE + 30_000 + 9_000);
    await expect(verifyRequest(nativeRequest("extend-2"))).rejects.toThrow(/rate limited/i);

    setSystemTime(BASE + 30_000 + 10_001);
    const user = await verifyRequest(nativeRequest("extend-3"));
    expect(user?.id).toBe("user-1");
    expect(getUser).toHaveBeenCalledTimes(2);
  });

  test("a non-throttle Stack failure does not open the circuit", async () => {
    setSystemTime(BASE + 60_000);
    failStackOnce(new Error("Stack Auth unreachable"));

    await expect(verifyRequest(nativeRequest("plain-1"))).rejects.toThrow("Stack Auth unreachable");
    const user = await verifyRequest(nativeRequest("plain-2"));
    expect(user?.id).toBe("user-1");
    expect(getUser).toHaveBeenCalledTimes(2);
  });

  test("a subrouter-path throttle does not open the native circuit", async () => {
    setSystemTime(BASE + 180_000);
    failStackOnce(new Error("Rate limited, no retry-after header received"));

    await expect(verifyRequest(nativeRequest("subrouter-1"), {
      subrouterAuthorizationSignal: new AbortController().signal,
    })).rejects.toThrow(/rate limited/i);
    const user = await verifyRequest(nativeRequest("native-after-subrouter"));
    expect(user?.id).toBe("user-1");
    expect(getUser).toHaveBeenCalledTimes(2);
  });

  test("cookie verification is never short-circuited by a native throttle", async () => {
    setSystemTime(BASE + 120_000);
    failStackOnce(new AggregateError([
        new Error("Rate limited, no retry-after header received"),
      ]));
    await expect(verifyRequest(nativeRequest("throttled-3"))).rejects.toThrow(/rate limited/i);

    const cookieRequest = new Request("https://cmux.test/api/vm", {
      headers: { cookie: "stack-session=abc" },
    });
    const user = await verifyRequest(cookieRequest);
    expect(user?.id).toBe("user-1");
    expect(getUser).toHaveBeenCalledTimes(2);
  });
});

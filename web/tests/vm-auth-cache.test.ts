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

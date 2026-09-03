import { beforeEach, describe, expect, mock, test } from "bun:test";

const getUser = mock(async (): Promise<unknown> => null);

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

const {
  verifyRequestIdentity,
  clearNativeAuthCacheForTests,
  clearStackThrottleCircuitForTests,
} = await import("../services/vms/auth");

const fakeStackUser = {
  id: "stack-user-1",
  displayName: "Test User",
  primaryEmail: "test@example.com",
  selectedTeam: null,
  clientReadOnlyMetadata: {},
  listTeams: async () => [],
};

function nativeRequest(access: string, refresh = "refresh-1"): Request {
  return new Request("https://cmux.test/api/devices/iroh/register", {
    method: "POST",
    headers: {
      authorization: `Bearer ${access}`,
      "x-stack-refresh-token": refresh,
    },
  });
}

const localIdentity = async (token: string) => token === "good-token"
  ? {
    userId: "jwt-user-1",
    projectId: "454ecd03-1db2-4050-845e-4ce5b0cd9895",
    refreshTokenId: "rt-1",
    isAnonymous: false,
    expiresAt: new Date(Date.now() + 60_000),
  }
  : null;

// bun's MockFunction typing in this tree lacks mockImplementation; the
// devices-route test uses the same cast.
function stackThrottles(): void {
  (getUser as unknown as {
    mockImplementation(implementation: () => Promise<never>): void;
  }).mockImplementation(async () => {
    throw new AggregateError([new Error("Rate limited, no retry-after header received")]);
  });
}

beforeEach(() => {
  clearNativeAuthCacheForTests();
  clearStackThrottleCircuitForTests();
  getUser.mockClear();
  getUser.mockResolvedValue(fakeStackUser);
});

describe("verifyRequestIdentity", () => {
  test("a locally verified access token never calls Stack", async () => {
    const identity = await verifyRequestIdentity(nativeRequest("good-token"), {
      allowCookie: false,
      verifyAccessToken: localIdentity,
    });
    expect(identity).toEqual({ id: "jwt-user-1", source: "access_token" });
    expect(getUser).toHaveBeenCalledTimes(0);
  });

  test("a token the local check cannot accept falls back to Stack", async () => {
    const identity = await verifyRequestIdentity(nativeRequest("stale-token"), {
      allowCookie: false,
      verifyAccessToken: localIdentity,
    });
    expect(identity).toEqual({ id: "stack-user-1", source: "stack" });
    expect(getUser).toHaveBeenCalledTimes(1);
  });

  test("a Stack failure on the fallback propagates so routes can map it", async () => {
    stackThrottles();
    await expect(verifyRequestIdentity(nativeRequest("stale-token"), {
      allowCookie: false,
      verifyAccessToken: localIdentity,
    })).rejects.toThrow(/rate limited/i);
  });

  test("a locally verified token bypasses an open Stack throttle circuit", async () => {
    stackThrottles();
    await expect(verifyRequestIdentity(nativeRequest("stale-token"), {
      allowCookie: false,
      verifyAccessToken: localIdentity,
    })).rejects.toThrow(/rate limited/i);

    const identity = await verifyRequestIdentity(nativeRequest("good-token"), {
      allowCookie: false,
      verifyAccessToken: localIdentity,
    });
    expect(identity?.source).toBe("access_token");
  });

  test("requireStackSession skips the local check and asks Stack", async () => {
    const identity = await verifyRequestIdentity(nativeRequest("good-token"), {
      allowCookie: false,
      requireStackSession: true,
      verifyAccessToken: localIdentity,
    });
    expect(identity).toEqual({ id: "stack-user-1", source: "stack" });
    expect(getUser).toHaveBeenCalledTimes(1);
  });

  test("without native credentials and with cookies disallowed there is no identity", async () => {
    const identity = await verifyRequestIdentity(
      new Request("https://cmux.test/api/devices/iroh/register", {
        method: "POST",
        headers: { cookie: "stack-session=abc" },
      }),
      { allowCookie: false, verifyAccessToken: localIdentity },
    );
    expect(identity).toBeNull();
    expect(getUser).toHaveBeenCalledTimes(0);
  });
});

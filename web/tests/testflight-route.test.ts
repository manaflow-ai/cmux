import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

const dbClientModule = await import("../db/client");
const realCloudDb = dbClientModule.cloudDb;
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

let stackConfigured = true;
let ascConfigured = true;
let currentUser = testflightUser();
let user: typeof currentUser | null = currentUser;
let useStubDb = false;

const getUser = mock(async () => user);
const ascFetch = mock(async (path: unknown) => {
  if (String(path).startsWith("/v1/betaTesters?")) {
    return {
      data: [
        {
          type: "betaTesters",
          id: "tester_123",
          attributes: {},
        },
      ],
    };
  }
  return {};
});
const captureAscError = mock(() => undefined);

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => stackConfigured,
  stackServerApp: stackConfigured ? { getUser } : null,
}));

mock.module("../services/asc/client", () => ({
  AscApiError: class AscApiError extends Error {},
  AscConfigurationError: class AscConfigurationError extends Error {},
  AscNetworkError: class AscNetworkError extends Error {},
  ascFetch,
  isAscConfigured: () => ascConfigured,
}));

mock.module("../services/errors", () => ({
  captureAscError,
  captureBillingError: mock(() => undefined),
}));

mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: (() =>
    useStubDb
      ? ({
          select: () => ({
            from: () => ({
              where: () => ({
                limit: async () => [],
              }),
            }),
          }),
        } as unknown as ReturnType<typeof realCloudDb>)
      : realCloudDb()) as typeof realCloudDb,
}));

const { POST } = await import("../app/api/testflight/route");

beforeAll(() => {
  useStubDb = true;
});

afterAll(() => {
  useStubDb = false;
});

describe("TestFlight route", () => {
  beforeEach(() => {
    stackConfigured = true;
    ascConfigured = true;
    currentUser = testflightUser();
    user = currentUser;
    getUser.mockClear();
    ascFetch.mockClear();
    captureAscError.mockClear();
    mockImplementation(ascFetch, async (path: unknown) => {
      if (String(path).startsWith("/v1/betaTesters?")) {
        return {
          data: [
            {
              type: "betaTesters",
              id: "tester_123",
              attributes: {},
            },
          ],
        };
      }
      return {};
    });
  });

  test("joins an eligible user and redirects with joined", async () => {
    const response = await postAction("join");

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/testflight?testflight=joined",
    );
    expect(ascFetch).toHaveBeenCalledWith(
      "/v1/betaTesters",
      expect.objectContaining({ method: "POST" }),
    );
    const body = JSON.parse(String(callInit(0).body));
    expect(body.data.attributes).toMatchObject({
      email: "pro@example.com",
      firstName: "Pro",
      lastName: "User",
    });
  });

  test("does not enroll ineligible users", async () => {
    currentUser = testflightUser({ eligible: false });
    user = currentUser;

    const response = await postAction("join");

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/testflight?testflight=ineligible",
    );
    expect(ascFetch).not.toHaveBeenCalled();
  });

  test("leaves by removing the current user's email", async () => {
    const response = await postAction("leave");

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/testflight?testflight=left",
    );
    expect(ascFetch).toHaveBeenCalledWith(
      "/v1/betaGroups/3ee84bfa-10ad-4f23-a45c-f9a3b037373e/relationships/betaTesters",
      expect.objectContaining({ method: "DELETE" }),
    );
  });

  test("redirects anonymous users to sign in", async () => {
    user = null;

    const response = await postAction("join", {
      referer: "https://cmux.test/ja/dashboard/testflight",
    });
    const location = new URL(response.headers.get("location")!);
    const afterSignIn = new URL(
      location.searchParams.get("after_auth_return_to")!,
      "https://cmux.test",
    );

    expect(response.status).toBe(303);
    expect(location.pathname).toBe("/handler/sign-in");
    expect(afterSignIn.searchParams.get("after_auth_return_to")).toBe(
      "/ja/dashboard/testflight",
    );
    expect(ascFetch).not.toHaveBeenCalled();
  });

  test("rejects cross-site posts before auth or ASC writes", async () => {
    const response = await postAction("join", {
      origin: "https://evil.example",
      secFetchSite: "cross-site",
    });

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/testflight?testflight=error",
    );
    expect(getUser).not.toHaveBeenCalled();
    expect(ascFetch).not.toHaveBeenCalled();
  });

  test("redirects unavailable when ASC is not configured", async () => {
    ascConfigured = false;

    const response = await postAction("join");

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/testflight?testflight=unavailable",
    );
    expect(ascFetch).not.toHaveBeenCalled();
  });
});

function postAction(
  action: string,
  options: {
    referer?: string;
    origin?: string;
    secFetchSite?: string;
  } = {},
) {
  const headers = new Headers({
    "content-type": "application/x-www-form-urlencoded",
    origin: options.origin ?? "https://cmux.test",
    referer: options.referer ?? "https://cmux.test/dashboard/testflight",
  });
  if (options.secFetchSite) {
    headers.set("sec-fetch-site", options.secFetchSite);
  }

  return POST(
    new NextRequest("https://cmux.test/api/testflight", {
      method: "POST",
      headers,
      body: new URLSearchParams({ action }),
    }),
  );
}

function testflightUser({ eligible = true }: { eligible?: boolean } = {}) {
  return {
    id: "user-pro",
    isAnonymous: false,
    primaryEmail: "Pro@Example.com",
    displayName: "Pro User",
    clientReadOnlyMetadata: {},
    listProducts: mock(async () =>
      Object.assign(
        eligible
          ? [
              {
                id: "pro",
                quantity: 1,
                subscription: {
                  cancelAtPeriodEnd: false,
                  currentPeriodEnd: new Date("2026-12-01T00:00:00Z"),
                },
              },
            ]
          : [],
        { nextCursor: null },
      ),
    ),
    update: mock(async () => undefined),
  };
}

function callInit(index: number): RequestInit {
  return (ascFetch as unknown as { mock: { calls: unknown[][] } }).mock.calls[index][1] as RequestInit;
}

function mockImplementation(
  fn: unknown,
  implementation: (...args: unknown[]) => unknown,
) {
  (fn as { mockImplementation(next: typeof implementation): void }).mockImplementation(
    implementation,
  );
}

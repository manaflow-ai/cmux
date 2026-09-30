import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import { accountMutationLeases } from "../db/schema";
import {
  createTestflightUser,
  testflightUserEligibility,
} from "./helpers/testflight-user";

const dbClientModule = await import("../db/client");
const realCloudDb = dbClientModule.cloudDb;
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;
const billingProModule = await import("../services/billing/pro");

let stackConfigured = true;
let ascConfigured = true;
let currentUser = createTestflightUser();
let user: typeof currentUser | null = currentUser;
let useStubDb = false;
let accountMutationLockActive = false;
let accountMutationTransactionCount = 0;
let accountMutationOperationId: string | null = null;
let ascMutationLockStates: boolean[] = [];
let eligibilityMutationLockStates: boolean[] = [];

function stubSelect() {
  return {
    from: (table: unknown) => ({
      where: () => ({
        limit: async () =>
          table === accountMutationLeases && accountMutationOperationId
            ? [{ operationId: accountMutationOperationId }]
            : [],
      }),
    }),
  };
}

function stubDelete(table: unknown) {
  return {
    where: async () => {
      if (table === accountMutationLeases) accountMutationOperationId = null;
    },
  };
}

function stubInsert(table: unknown) {
  return {
    values: async (values: unknown) => {
      if (table === accountMutationLeases) {
        accountMutationOperationId = (values as { operationId: string })
          .operationId;
      }
    },
  };
}

function stubUpdate() {
  return {
    set: () => ({ where: async () => undefined }),
  };
}

const getUser = mock(async () => user);
const ascFetch = mock(async (path: unknown, init?: unknown) => {
  ascMutationLockStates.push(accountMutationLockActive);
  if (path === "/v1/betaTesters" && (init as { method?: string })?.method === "POST") {
    return {
      data: { type: "betaTesters", id: "tester_new" },
    };
  }
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
const isTestflightEligible = mock(async (candidate: unknown) => {
  eligibilityMutationLockStates.push(accountMutationLockActive);
  return testflightUserEligibility(candidate) ?? false;
});

mock.module("../services/billing/pro", () => ({
  ...billingProModule,
  isTestflightEligible,
}));

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
          select: stubSelect,
          delete: stubDelete,
          insert: stubInsert,
          update: stubUpdate,
          transaction: async (run: (tx: unknown) => Promise<unknown>) => {
            accountMutationTransactionCount += 1;
            const tx = {
              select: stubSelect,
              delete: stubDelete,
              insert: stubInsert,
              update: stubUpdate,
              execute: async () => {
                accountMutationLockActive = true;
              },
            };
            try {
              return await run(tx);
            } finally {
              accountMutationLockActive = false;
            }
          },
        } as unknown as ReturnType<typeof realCloudDb>)
      : realCloudDb()) as typeof realCloudDb,
}));

const { PRO_TESTFLIGHT_GROUP_ID } = await import("../services/asc/testflight");
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
    currentUser = createTestflightUser();
    user = currentUser;
    getUser.mockClear();
    mockImplementation(getUser, async () => user);
    isTestflightEligible.mockClear();
    mockImplementation(isTestflightEligible, async (candidate: unknown) => {
      eligibilityMutationLockStates.push(accountMutationLockActive);
      return testflightUserEligibility(candidate) ?? false;
    });
    ascFetch.mockClear();
    accountMutationLockActive = false;
    accountMutationTransactionCount = 0;
    accountMutationOperationId = null;
    ascMutationLockStates = [];
    eligibilityMutationLockStates = [];
    captureAscError.mockClear();
    mockImplementation(ascFetch, async (path: unknown, init?: unknown) => {
      ascMutationLockStates.push(accountMutationLockActive);
      if (path === "/v1/betaTesters" && (init as { method?: string })?.method === "POST") {
        return {
          data: { type: "betaTesters", id: "tester_new" },
        };
      }
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
    const update = mock(async () => undefined);
    currentUser.update = update;
    user = currentUser;

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
    expect(update).toHaveBeenCalledWith({
      clientReadOnlyMetadata: {
        cmuxProTestflightEnrollmentEmails: ["pro@example.com"],
        cmuxProTestflightGrants: [
          { email: "pro@example.com", source: "user" },
        ],
      },
    });
    expect(
      (ascFetch as unknown as { mock: { calls: unknown[][] } }).mock.calls.some(
        ([path]) => path === "/v1/betaTesterInvitations",
      ),
    ).toBe(false);
  });

  test("re-fetches reconciled Stack metadata before recording enrollment ownership", async () => {
    const staleUpdates: unknown[] = [];
    const freshUpdates: unknown[] = [];
    const staleUser = createTestflightUser();
    staleUser.update = mock(async (options: unknown) => {
      staleUpdates.push(options);
    });
    const freshUser = createTestflightUser();
    freshUser.clientReadOnlyMetadata = {
      cmuxPlan: "pro",
      retained: true,
    };
    freshUser.update = mock(async (options: unknown) => {
      freshUpdates.push(options);
    });
    let reads = 0;
    mockImplementation(getUser, async () => {
      reads += 1;
      return reads === 1 ? staleUser : freshUser;
    });
    mockImplementation(isTestflightEligible, async (candidate: unknown) => {
      if (candidate === staleUser) {
        await staleUser.update({
          clientReadOnlyMetadata: { cmuxPlan: "pro" },
        });
      }
      return true;
    });

    const response = await postAction("join");

    expect(response.status).toBe(303);
    expect(getUser).toHaveBeenCalledTimes(2);
    expect(staleUpdates).toEqual([
      { clientReadOnlyMetadata: { cmuxPlan: "pro" } },
    ]);
    expect(freshUpdates).toEqual([
      {
        clientReadOnlyMetadata: {
          cmuxPlan: "pro",
          retained: true,
          cmuxProTestflightEnrollmentEmails: ["pro@example.com"],
          cmuxProTestflightGrants: [
            { email: "pro@example.com", source: "user" },
          ],
        },
      },
    ]);
  });

  test("does not enroll ineligible users", async () => {
    currentUser = createTestflightUser({ eligible: false });
    user = currentUser;

    const response = await postAction("join");

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/testflight?testflight=ineligible",
    );
    expect(ascFetch).not.toHaveBeenCalled();
  });

  test("releases the database transaction before eligibility and ASC enrollment", async () => {
    const response = await postAction("join");

    expect(response.status).toBe(303);
    expect(accountMutationTransactionCount).toBeGreaterThan(1);
    expect(eligibilityMutationLockStates.length).toBeGreaterThan(0);
    expect(eligibilityMutationLockStates.every((active) => !active)).toBe(true);
    expect(ascMutationLockStates.length).toBeGreaterThan(0);
    expect(ascMutationLockStates.every((active) => !active)).toBe(true);
  });

  test("compensates when Pro eligibility lapses before enrollment completes", async () => {
    let eligibilityChecks = 0;
    mockImplementation(isTestflightEligible, async () => {
      eligibilityChecks += 1;
      return eligibilityChecks === 1;
    });

    const response = await postAction("join");

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/testflight?testflight=ineligible",
    );
    expect(isTestflightEligible).toHaveBeenCalledTimes(2);
    expect(ascFetch).toHaveBeenCalledWith(
      "/v1/betaTesters",
      expect.objectContaining({ method: "POST" }),
    );
    expect(ascFetch).toHaveBeenCalledWith(
      `/v1/betaGroups/${PRO_TESTFLIGHT_GROUP_ID}/relationships/betaTesters`,
      expect.objectContaining({ method: "DELETE" }),
    );
  });

  test("leaves by removing the current user's email", async () => {
    const response = await postAction("leave");

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/testflight?testflight=left",
    );
    expect(ascFetch).toHaveBeenCalledWith(
      `/v1/betaGroups/${PRO_TESTFLIGHT_GROUP_ID}/relationships/betaTesters`,
      expect.objectContaining({ method: "DELETE" }),
    );
  });

  test("removes recorded TestFlight access when the current email is missing", async () => {
    currentUser = {
      ...createTestflightUser(),
      primaryEmail: null,
      clientReadOnlyMetadata: {
        cmuxProTestflightEnrollmentEmails: ["historical@example.com"],
      },
    } as never;
    user = currentUser;

    const response = await postAction("leave");

    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/testflight?testflight=left",
    );
    expect(ascFetch).toHaveBeenCalledWith(
      `/v1/betaTesters?filter[email]=${encodeURIComponent("historical@example.com")}&limit=1`,
    );
    expect(ascFetch).toHaveBeenCalledWith(
      `/v1/betaGroups/${PRO_TESTFLIGHT_GROUP_ID}/relationships/betaTesters`,
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

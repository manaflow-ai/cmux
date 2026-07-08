import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

// Capture real implementations BY VALUE: bun's mock.module can mutate an
// already-loaded namespace in place, so calling through a captured namespace
// object at delegation time can recurse into the mock itself.
const dbClientModule = await import("../db/client");
const realCloudDb = dbClientModule.cloudDb;
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;

const originalSetTimeout = globalThis.setTimeout;
const originalConsoleError = console.error;

const updates: unknown[] = [];
let stripeRows: unknown[] = [];
let useStubDb = false;
const getUser = mock(async () => confirmUser());
const appListProducts = mock(async () => emptyProductsPage());
const userListProducts = mock(async () => emptyProductsPage());
const stripeLimit = mock(async () => stripeRows);

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser, listProducts: appListProducts }),
  isStackConfigured: () => true,
  stackServerApp: { getUser, listProducts: appListProducts },
}));

// bun's mock.module replaces the module for the whole test process, so keep
// every real export other tests import (vm-workflows, vm-db-read-model call
// closeCloudDbForTests during teardown).
mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: () =>
    useStubDb
      ? ({
          select: () => ({
            from: () => ({
              where: () => ({
                limit: stripeLimit,
              }),
            }),
          }),
        } as unknown as ReturnType<typeof realCloudDb>)
      : realCloudDb(),
}));

beforeAll(() => {
  useStubDb = true;
});

afterAll(() => {
  useStubDb = false;
});

const { GET } = await import("../app/api/billing/confirm/route");

describe("billing confirm route", () => {
  beforeEach(() => {
    updates.length = 0;
    stripeRows = [];
    getUser.mockClear();
    getUser.mockResolvedValue(confirmUser());
    appListProducts.mockClear();
    appListProducts.mockResolvedValue(emptyProductsPage());
    userListProducts.mockClear();
    userListProducts.mockResolvedValue(emptyProductsPage());
    stripeLimit.mockClear();
    console.error = mock(() => {}) as unknown as typeof console.error;
    globalThis.setTimeout = ((handler: TimerHandler) => {
      queueMicrotask(() => {
        if (typeof handler === "function") handler();
      });
      return 0 as unknown as ReturnType<typeof setTimeout>;
    }) as unknown as typeof setTimeout;
  });

  afterEach(() => {
    globalThis.setTimeout = originalSetTimeout;
    console.error = originalConsoleError;
  });

  test("keeps Stripe-backed Pro metadata when the Stack poll sees no Pro product", async () => {
    stripeRows = [{ id: "sub_1" }];
    getUser.mockResolvedValue(confirmUser({ cmuxPlan: "pro", theme: "dark" }));

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/confirm"),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?welcome=success",
    );
    expect(appListProducts).toHaveBeenCalledTimes(4);
    expect(userListProducts).toHaveBeenCalledTimes(1);
    expect(stripeLimit).toHaveBeenCalledTimes(1);
    expect(updates).toEqual([]);
  });

  test("clears stale Pro metadata for a genuinely lapsed user", async () => {
    getUser.mockResolvedValue(confirmUser({ cmuxPlan: "pro", theme: "dark" }));

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/confirm"),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?welcome=pending",
    );
    expect(appListProducts).toHaveBeenCalledTimes(4);
    expect(userListProducts).toHaveBeenCalledTimes(1);
    expect(stripeLimit).toHaveBeenCalledTimes(1);
    expect(updates).toEqual([{ theme: "dark" }]);
  });
});

function confirmUser(metadata: unknown = {}) {
  return {
    id: "user-confirm",
    clientReadOnlyMetadata: metadata,
    listProducts: userListProducts,
    update: async (options: { clientReadOnlyMetadata: unknown }) => {
      updates.push(options.clientReadOnlyMetadata);
    },
  };
}

function emptyProductsPage() {
  return Object.assign([], { nextCursor: null });
}

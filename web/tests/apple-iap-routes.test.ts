import { beforeEach, describe, expect, mock, test } from "bun:test";

import { AppleVerificationError } from "../services/billing/apple/verifier";
import * as accountTokenModule from "../services/billing/apple/accountToken";

type TestUser = { id: string; isAnonymous: boolean };

let currentUser: TestUser | null = null;
let stackThrows = false;
const getUserCalls: unknown[] = [];

mock.module("../app/lib/stack", () => ({
  isStackConfigured: () => true,
  getStackServerApp: () => ({
    getUser: async (options: unknown) => {
      getUserCalls.push(options);
      if (stackThrows) throw new Error("Stack unavailable");
      return currentUser;
    },
  }),
}));

let transactionImpl: (input: { userId: string; signedTransactionInfo: unknown }) => Promise<unknown>;
let notificationImpl: (payload: unknown) => Promise<string>;
let accountTokenImpl: (user: TestUser, app: unknown) => Promise<unknown>;

class RejectedError extends Error {
  constructor(readonly reason: string) {
    super(reason);
  }
}

mock.module("../services/billing/apple/service", () => ({
  AppleTransactionRejectedError: RejectedError,
  recordClientAppleTransaction: (input: { userId: string; signedTransactionInfo: unknown }) => transactionImpl(input),
  receiveAppleNotification: (payload: unknown) => notificationImpl(payload),
}));

const realAccountToken = { ...accountTokenModule };
mock.module("../services/billing/apple/accountToken", () => ({
  ...realAccountToken,
  appleAccountTokenResponse: (user: TestUser, app: unknown) => accountTokenImpl(user, app),
}));

const accountTokenRoute = await import("../app/api/billing/apple/account-token/route");
const transactionsRoute = await import("../app/api/billing/apple/transactions/route");
const notificationsRoute = await import("../app/api/billing/apple/notifications/route");

function post(path: string, body: unknown, headers: Record<string, string> = {}) {
  return new Request(`https://cmux.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

beforeEach(() => {
  currentUser = { id: "user-a", isAnonymous: false };
  stackThrows = false;
  getUserCalls.length = 0;
  transactionImpl = async () => ({ planId: "pro", status: "active", expiresAt: null });
  notificationImpl = async () => "processed";
  accountTokenImpl = async (user, app) => ({ appAccountToken: `token-${user.id}`, app });
});

describe("Apple billing route auth", () => {
  test("signed-out and anonymous callers get 401 on both authenticated routes", async () => {
    for (const user of [null, { id: "anon", isAnonymous: true }]) {
      currentUser = user;
      expect((await accountTokenRoute.POST(post("/api/billing/apple/account-token", {}))).status).toBe(401);
      expect((await transactionsRoute.POST(post("/api/billing/apple/transactions", { signedTransactionInfo: "x" }))).status).toBe(401);
    }
  });

  test("the native bearer and refresh token headers authenticate the iOS app", async () => {
    const response = await accountTokenRoute.POST(post("/api/billing/apple/account-token", {}, {
      authorization: "Bearer access-token",
      "x-stack-refresh-token": "refresh-token",
      "x-cmux-bundle-id": "dev.cmux.app.beta",
      "x-cmux-storekit-environment": "Sandbox",
    }));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      appAccountToken: "token-user-a",
      app: { bundleId: "dev.cmux.app.beta", storeKitEnvironment: "Sandbox" },
    });
    expect(getUserCalls[0]).toMatchObject({ tokenStore: { accessToken: "access-token" } });
  });

  test("a Stack outage is a 503, not a sign-out", async () => {
    stackThrows = true;
    expect((await accountTokenRoute.POST(post("/api/billing/apple/account-token", {}))).status).toBe(503);
  });
});

describe("POST /api/billing/apple/transactions", () => {
  test("passes the signed transaction for the authenticated user", async () => {
    let seen: unknown;
    transactionImpl = async (input) => {
      seen = input;
      return { planId: "max", status: "active", expiresAt: "2026-11-01T00:00:00.000Z" };
    };
    const response = await transactionsRoute.POST(post("/api/billing/apple/transactions", { signedTransactionInfo: "jws" }));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ planId: "max", status: "active", expiresAt: "2026-11-01T00:00:00.000Z" });
    expect(seen).toEqual({ userId: "user-a", signedTransactionInfo: "jws" });
  });

  test("maps rejections to stable 4xx codes", async () => {
    transactionImpl = async () => { throw new RejectedError("account_mismatch"); };
    const mismatch = await transactionsRoute.POST(post("/api/billing/apple/transactions", { signedTransactionInfo: "jws" }));
    expect(mismatch.status).toBe(403);
    expect(await mismatch.json()).toEqual({ error: "account_mismatch" });

    transactionImpl = async () => { throw new AppleVerificationError("invalid_signature"); };
    expect((await transactionsRoute.POST(post("/api/billing/apple/transactions", { signedTransactionInfo: "jws" }))).status).toBe(400);

    transactionImpl = async () => { throw new AppleVerificationError("retryable"); };
    expect((await transactionsRoute.POST(post("/api/billing/apple/transactions", { signedTransactionInfo: "jws" }))).status).toBe(503);

    expect((await transactionsRoute.POST(post("/api/billing/apple/transactions", "{not json"))).status).toBe(400);
  });
});

describe("POST /api/billing/apple/notifications", () => {
  test("is public and returns 200 with the outcome once the ledger is durable", async () => {
    currentUser = null;
    notificationImpl = async () => "failed";
    const response = await notificationsRoute.POST(post("/api/billing/apple/notifications", { signedPayload: "jws" }));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, outcome: "failed" });
    expect(getUserCalls).toEqual([]);
  });

  test("returns 400 only for payloads that fail verification", async () => {
    notificationImpl = async () => { throw new AppleVerificationError("invalid_signature"); };
    expect((await notificationsRoute.POST(post("/api/billing/apple/notifications", { signedPayload: "jws" }))).status).toBe(400);
    notificationImpl = async () => { throw new Error("ledger write failed"); };
    expect((await notificationsRoute.POST(post("/api/billing/apple/notifications", { signedPayload: "jws" }))).status).toBe(503);
  });
});

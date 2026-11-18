// Shared fixture for the Apple IAP cron tests: a test signing chain, signed
// transactions, renewal info and notifications, the in-memory store, and a
// dependency set whose clock, entitlement re-derives and Server API calls
// the test controls.

import type { ServerEventInput } from "../../services/analytics/serverEvents";
import type { AppleServerApi, AppleSubscriptionStatusSnapshot } from "../../services/billing/apple/serverApi";
import type { AppleIapDependencies } from "../../services/billing/apple/service";
import type { AppleSubscriptionRow } from "../../services/billing/apple/store";
import { createAppleSignedDataVerifier } from "../../services/billing/apple/verifier";
import { memoryAppleStore, type MemoryAppleStore } from "./apple-memory-store";
import { createAppleTestSigner } from "./apple-signing";

export const BUNDLE = "com.cmux.app";
export const ORIGINAL = "2000000000000100";
export const MINUTE = 60 * 1000;
export const HOUR = 60 * MINUTE;
export const DAY = 24 * HOUR;
export const NOW = new Date(Date.UTC(2026, 9, 15));
export const env = { APPLE_IAP_BUNDLE_IDS: `${BUNDLE},dev.cmux.app.beta`, APPLE_IAP_APP_APPLE_ID: "6783338052" };
export const signer = createAppleTestSigner();
export const forger = createAppleTestSigner("Forger");
export const verifier = createAppleSignedDataVerifier({ rootCertificates: [signer.rootCertificate], onlineChecks: false, env });

export type Fixture = {
  store: MemoryAppleStore;
  clock: Date;
  applied: string[];
  events: ServerEventInput[];
  applyFailures: number;
  serverApi: AppleServerApi | null;
  statusCalls: string[];
  token: string;
  tokenB: string;
  deps(overrides?: Partial<AppleIapDependencies>): AppleIapDependencies;
  subscription(id?: string): AppleSubscriptionRow;
  /** Server API that answers status lookups with `answer` and has no history. */
  statusApi(answer: (originalTransactionId: string) => Promise<AppleSubscriptionStatusSnapshot | null>): AppleServerApi;
};

export async function createFixture(): Promise<Fixture> {
  const store = memoryAppleStore();
  const fixture: Fixture = {
    store,
    clock: NOW,
    applied: [],
    events: [],
    applyFailures: 0,
    serverApi: null,
    statusCalls: [],
    token: await store.accountTokenForUser("user-a"),
    tokenB: await store.accountTokenForUser("user-b"),
    deps(overrides = {}) {
      return {
        store: fixture.store,
        verifier,
        serverApi: fixture.serverApi,
        applyEntitlement: async (userId) => {
          if (fixture.applyFailures > 0) {
            fixture.applyFailures -= 1;
            throw new Error("Stack unavailable");
          }
          fixture.applied.push(userId);
        },
        captureEvent: async (input) => {
          fixture.events.push(input);
        },
        now: () => fixture.clock,
        env,
        ...overrides,
      };
    },
    subscription(id = ORIGINAL) {
      return fixture.store.subscriptions.get(id)!;
    },
    statusApi(answer) {
      return {
        subscriptionStatus: async ({ originalTransactionId }) => {
          fixture.statusCalls.push(originalTransactionId);
          return await answer(originalTransactionId);
        },
        notificationHistory: async () => ({ signedPayloads: [], hasMore: false, paginationToken: null }),
      };
    },
  };
  return fixture;
}

let transactionCounter = 0;
export function transaction(overrides: Record<string, unknown> = {}, token: string | undefined = undefined) {
  transactionCounter += 1;
  return {
    transactionId: `30000000000${String(transactionCounter).padStart(5, "0")}`,
    originalTransactionId: ORIGINAL,
    bundleId: BUNDLE,
    productId: `${BUNDLE}.pro.monthly`,
    type: "Auto-Renewable Subscription",
    environment: "Production",
    appAccountToken: token,
    purchaseDate: NOW.getTime() - 30 * DAY,
    originalPurchaseDate: NOW.getTime() - 30 * DAY,
    expiresDate: NOW.getTime() + 2 * HOUR,
    transactionReason: "PURCHASE",
    storefront: "USA",
    currency: "USD",
    price: 74990,
    signedDate: NOW.getTime() - 30 * DAY,
    ...overrides,
  };
}

export function renewal(overrides: Record<string, unknown> = {}) {
  return {
    originalTransactionId: ORIGINAL,
    productId: `${BUNDLE}.pro.monthly`,
    autoRenewProductId: `${BUNDLE}.pro.monthly`,
    autoRenewStatus: 1,
    environment: "Production",
    signedDate: NOW.getTime() - 30 * DAY,
    ...overrides,
  };
}

let notificationCounter = 0;
export function notification(input: {
  readonly type: string;
  readonly subtype?: string;
  readonly status?: number;
  readonly signedDate: number;
  readonly tx: Record<string, unknown>;
  readonly renewalInfo?: Record<string, unknown>;
  readonly uuid?: string;
  readonly environment?: string;
  readonly signWith?: typeof signer;
}): string {
  notificationCounter += 1;
  const sign = input.signWith ?? signer;
  const environment = input.environment ?? "Production";
  return sign.sign({
    notificationType: input.type,
    ...(input.subtype ? { subtype: input.subtype } : {}),
    notificationUUID: input.uuid ?? `00000000-0000-4000-9000-${String(notificationCounter).padStart(12, "0")}`,
    version: "2.0",
    signedDate: input.signedDate,
    data: {
      bundleId: BUNDLE,
      environment,
      appAppleId: 6783338052,
      ...(input.status ? { status: input.status } : {}),
      signedTransactionInfo: sign.sign({ ...input.tx, environment, signedDate: input.signedDate }),
      signedRenewalInfo: sign.sign(renewal({ environment, signedDate: input.signedDate, ...input.renewalInfo })),
    },
  });
}

/** A subscription bought 30 days ago by user-a whose access ends at `expiresAt`. */
export async function seedSubscription(
  fixture: Fixture,
  overrides: Partial<AppleSubscriptionRow> = {},
): Promise<AppleSubscriptionRow> {
  const row: AppleSubscriptionRow = {
    originalTransactionId: ORIGINAL,
    userId: "user-a",
    appAccountToken: fixture.token,
    bundleId: BUNDLE,
    environment: "Production",
    productId: `${BUNDLE}.pro.monthly`,
    planId: "pro",
    status: "active",
    autoRenewEnabled: true,
    autoRenewProductId: `${BUNDLE}.pro.monthly`,
    purchaseDate: new Date(NOW.getTime() - 30 * DAY),
    originalPurchaseDate: new Date(NOW.getTime() - 30 * DAY),
    expiresAt: new Date(NOW.getTime() + 2 * HOUR),
    gracePeriodExpiresAt: null,
    storefront: "USA",
    currency: "USD",
    priceMilliunits: 74990,
    lastTransactionId: "period-1",
    revokedAt: null,
    revocationReason: null,
    stateSignedAt: new Date(NOW.getTime() - 30 * DAY),
    appleCheckedAt: null,
    createdAt: new Date(NOW.getTime() - 30 * DAY),
    updatedAt: new Date(NOW.getTime() - 30 * DAY),
    ...overrides,
  };
  fixture.store.subscriptions.set(row.originalTransactionId, row);
  return row;
}

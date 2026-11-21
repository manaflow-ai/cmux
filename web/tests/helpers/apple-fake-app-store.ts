// A local App Store for end-to-end billing scenarios. It keeps one source
// of truth per subscription (its transactions, renewal preference and
// Apple status) and serves it three ways, all signed by a test chain the
// verifier trusts: the StoreKit JWS the app posts, App Store Server
// Notifications V2 (kept in a history whether or not they were delivered),
// and the App Store Server API (getAllSubscriptionStatuses and
// getNotificationHistory). Apple's clock is the process clock, which the
// scenarios set with bun's setSystemTime. Never talks to Apple.

import { VerificationException, VerificationStatus } from "@apple/app-store-server-library";

import type { AppleServerApi, AppleSubscriptionStatusSnapshot } from "../../services/billing/apple/serverApi";
import {
  AppleVerificationError,
  createAppleSignedDataVerifier,
  type AppleSignedDataVerifier,
} from "../../services/billing/apple/verifier";
import { createAppleTestSigner } from "./apple-signing";

export const FAKE_BUNDLE_ID = "com.cmux.app";
export const FAKE_APP_APPLE_ID = 6783338052;
const DAY = 24 * 60 * 60 * 1000;
export const SUBSCRIPTION_PERIOD_MS = 30 * DAY;
const HISTORY_PAGE_SIZE = 20;

/** Apple `status`: 1 active, 2 expired, 3 billing retry, 4 grace period, 5 revoked. */
export type AppleStatusCode = 1 | 2 | 3 | 4 | 5;
export type FakePlan = "go" | "pro" | "max";

type FakeTransaction = {
  transactionId: string;
  originalTransactionId: string;
  webOrderLineItemId: string;
  bundleId: string;
  productId: string;
  subscriptionGroupIdentifier: string;
  purchaseDate: number;
  originalPurchaseDate: number;
  expiresDate: number;
  quantity: number;
  type: "Auto-Renewable Subscription";
  appAccountToken?: string;
  inAppOwnershipType: "PURCHASED" | "FAMILY_SHARED";
  transactionReason: "PURCHASE" | "RENEWAL";
  environment: "Production";
  storefront: string;
  storefrontId: string;
  price: number;
  currency: string;
  isUpgraded?: boolean;
  revocationDate?: number;
  revocationReason?: number;
};

type FakeSubscription = {
  readonly originalTransactionId: string;
  transactions: FakeTransaction[];
  current: FakeTransaction;
  status: AppleStatusCode;
  autoRenewStatus: 0 | 1;
  autoRenewProductId: string;
  isInBillingRetryPeriod: boolean;
  gracePeriodExpiresDate: number | null;
  /** The token a plan change made from another cmux account puts on the next renewal. */
  nextRenewalToken?: string;
};

/** One App Store Server Notification. Apple keeps it in history whether or not it reached the server. */
export type FakeNotification = {
  readonly uuid: string;
  readonly type: string;
  readonly subtype: string | null;
  readonly signedDate: number;
  readonly signedPayload: string;
  readonly bundleId: string;
  readonly environment: string;
};

export type FakePurchase = {
  readonly originalTransactionId: string;
  readonly transactionId: string;
  /** What StoreKit hands the app (`jwsRepresentation`), signed now. */
  readonly jws: string;
  readonly notification: FakeNotification;
};

const PRICES: Readonly<Record<FakePlan, number>> = { go: 14990, pro: 74990, max: 299990 };

export function fakeProductId(plan: FakePlan): string {
  return `${FAKE_BUNDLE_ID}.${plan}.monthly`;
}

function planOfProduct(productId: string): FakePlan {
  const plan = productId.split(".").at(-2);
  if (plan !== "go" && plan !== "pro" && plan !== "max") throw new Error(`unknown fake product ${productId}`);
  return plan;
}

export class FakeAppStore {
  readonly signer = createAppleTestSigner("Fake App Store");
  /** Every notification Apple sent, delivered or not, oldest first. */
  readonly history: FakeNotification[] = [];
  /** Original transaction ids the Server API was asked about, in order. */
  readonly statusCalls: string[] = [];
  /** Apple's certificate revocation (OCSP) check is unreachable: verification fails as retryable. */
  verificationOutage = false;
  /** The App Store Server API answers with errors (status lookups and history). */
  serverApiOutage = false;
  /** Notifications Get Notification History leaves out (see omitFromHistory). */
  private readonly omitted = new Set<string>();
  readonly verifier: AppleSignedDataVerifier;
  readonly serverApi: AppleServerApi;
  private readonly subscriptions = new Map<string, FakeSubscription>();
  private nextId = 1;

  constructor() {
    const real = createAppleSignedDataVerifier({
      rootCertificates: [this.signer.rootCertificate],
      onlineChecks: false,
    });
    const online = <T>(verify: () => Promise<T>): Promise<T> => {
      if (this.verificationOutage) {
        // What the library raises when OCSP is unreachable, as the verifier maps it.
        return Promise.reject(new AppleVerificationError(
          "retryable",
          new VerificationException(VerificationStatus.RETRYABLE_VERIFICATION_FAILURE),
        ));
      }
      return verify();
    };
    this.verifier = {
      verifyTransaction: (jws) => online(() => real.verifyTransaction(jws)),
      verifyRenewalInfo: (jws, scope) => online(() => real.verifyRenewalInfo(jws, scope)),
      verifyNotification: (payload) => online(() => real.verifyNotification(payload)),
    };
    this.serverApi = {
      subscriptionStatus: async (input) => {
        if (this.serverApiOutage) throw new Error("App Store Server API unavailable (fake outage)");
        return this.subscriptionStatus(input);
      },
      notificationHistory: async (input) => {
        if (this.serverApiOutage) throw new Error("App Store Server API unavailable (fake outage)");
        return this.notificationHistory(input);
      },
    };
  }

  // MARK: - What happens in the App Store

  /** A new subscription bought in the app with the account's `appAccountToken`. */
  purchase(input: { readonly token?: string; readonly plan: FakePlan; readonly familyShared?: boolean }): FakePurchase {
    const now = Date.now();
    const originalTransactionId = this.id("2000000");
    const tx = this.transaction({
      originalTransactionId,
      productId: fakeProductId(input.plan),
      purchaseDate: now,
      originalPurchaseDate: now,
      expiresDate: now + SUBSCRIPTION_PERIOD_MS,
      appAccountToken: input.token,
      inAppOwnershipType: input.familyShared ? "FAMILY_SHARED" : "PURCHASED",
      transactionReason: "PURCHASE",
    });
    const sub: FakeSubscription = {
      originalTransactionId,
      transactions: [tx],
      current: tx,
      status: 1,
      autoRenewStatus: 1,
      autoRenewProductId: tx.productId,
      isInBillingRetryPeriod: false,
      gracePeriodExpiresDate: null,
    };
    this.subscriptions.set(originalTransactionId, sub);
    const notification = this.notify(sub, "SUBSCRIBED", "INITIAL_BUY");
    return { originalTransactionId, transactionId: tx.transactionId, jws: this.sign(tx), notification };
  }

  /**
   * The family member's copy of a purchase when Family Sharing is on: its own
   * transaction, owned FAMILY_SHARED, with no account token.
   */
  familyCopy(purchaserOriginalTransactionId: string): FakePurchase {
    const purchaser = this.subscription(purchaserOriginalTransactionId);
    const now = Date.now();
    const originalTransactionId = this.id("2000000");
    const tx = this.transaction({
      originalTransactionId,
      productId: purchaser.current.productId,
      purchaseDate: now,
      originalPurchaseDate: now,
      expiresDate: purchaser.current.expiresDate,
      inAppOwnershipType: "FAMILY_SHARED",
      transactionReason: "PURCHASE",
    });
    const sub: FakeSubscription = {
      originalTransactionId,
      transactions: [tx],
      current: tx,
      status: 1,
      autoRenewStatus: 1,
      autoRenewProductId: tx.productId,
      isInBillingRetryPeriod: false,
      gracePeriodExpiresDate: null,
    };
    this.subscriptions.set(originalTransactionId, sub);
    const notification = this.notify(sub, "SUBSCRIBED", "INITIAL_BUY");
    return { originalTransactionId, transactionId: tx.transactionId, jws: this.sign(tx), notification };
  }

  /**
   * Apple charges the renewal (up to a day before the period ends). As in
   * Apple's data, the renewal transaction's `purchaseDate` is the start of
   * the new period (the old `expiresDate`), not the time of the charge, and
   * it runs one period in the product the subscriber chose to renew into.
   */
  renew(originalTransactionId: string): { readonly transactionId: string; readonly notification: FakeNotification } {
    const sub = this.subscription(originalTransactionId);
    const previous = sub.current;
    const tx = this.transaction({
      originalTransactionId,
      productId: sub.autoRenewProductId,
      purchaseDate: previous.expiresDate,
      originalPurchaseDate: previous.originalPurchaseDate,
      expiresDate: previous.expiresDate + SUBSCRIPTION_PERIOD_MS,
      appAccountToken: sub.nextRenewalToken ?? previous.appAccountToken,
      inAppOwnershipType: previous.inAppOwnershipType,
      transactionReason: "RENEWAL",
    });
    delete sub.nextRenewalToken;
    this.advance(sub, tx, 1);
    return { transactionId: tx.transactionId, notification: this.notify(sub, "DID_RENEW") };
  }

  /**
   * An upgrade takes effect at once: a new transaction for the higher plan
   * from now, carrying the token of the cmux account that bought it.
   */
  upgrade(
    originalTransactionId: string,
    plan: FakePlan,
    options: { readonly token?: string } = {},
  ): FakePurchase {
    const sub = this.subscription(originalTransactionId);
    const previous = sub.current;
    previous.isUpgraded = true;
    const now = Date.now();
    const tx = this.transaction({
      originalTransactionId,
      productId: fakeProductId(plan),
      purchaseDate: now,
      originalPurchaseDate: previous.originalPurchaseDate,
      expiresDate: now + SUBSCRIPTION_PERIOD_MS,
      appAccountToken: options.token ?? previous.appAccountToken,
      inAppOwnershipType: previous.inAppOwnershipType,
      transactionReason: "PURCHASE",
    });
    sub.autoRenewProductId = tx.productId;
    this.advance(sub, tx, 1);
    const notification = this.notify(sub, "DID_CHANGE_RENEWAL_PREF", "UPGRADE");
    return { originalTransactionId, transactionId: tx.transactionId, jws: this.sign(tx), notification };
  }

  /**
   * A downgrade only changes what the next renewal buys. Made from another
   * cmux account (`token`), the next renewal carries that account's token.
   */
  downgrade(originalTransactionId: string, plan: FakePlan, options: { readonly token?: string } = {}): FakeNotification {
    const sub = this.subscription(originalTransactionId);
    sub.autoRenewProductId = fakeProductId(plan);
    if (options.token) sub.nextRenewalToken = options.token;
    return this.notify(sub, "DID_CHANGE_RENEWAL_PREF", "DOWNGRADE");
  }

  setAutoRenew(originalTransactionId: string, enabled: boolean): FakeNotification {
    const sub = this.subscription(originalTransactionId);
    sub.autoRenewStatus = enabled ? 1 : 0;
    return this.notify(sub, "DID_CHANGE_RENEWAL_STATUS", enabled ? "AUTO_RENEW_ENABLED" : "AUTO_RENEW_DISABLED");
  }

  /** The period ended with auto-renew off. */
  expire(originalTransactionId: string): FakeNotification {
    const sub = this.subscription(originalTransactionId);
    if (Date.now() < sub.current.expiresDate) throw new Error("the fake App Store expires a subscription only after its period ends");
    sub.status = 2;
    return this.notify(sub, "EXPIRED", "VOLUNTARY");
  }

  /**
   * The renewal charge failed at expiry. With a grace period the subscriber
   * keeps access through it (status 4); without one (`graceDays: 0`) access
   * ends now and Apple keeps retrying (status 3).
   */
  failRenewal(originalTransactionId: string, options: { readonly graceDays: number }): FakeNotification {
    const sub = this.subscription(originalTransactionId);
    sub.isInBillingRetryPeriod = true;
    if (options.graceDays === 0) {
      sub.status = 3;
      sub.gracePeriodExpiresDate = null;
      return this.notify(sub, "DID_FAIL_TO_RENEW");
    }
    sub.status = 4;
    sub.gracePeriodExpiresDate = sub.current.expiresDate + options.graceDays * DAY;
    return this.notify(sub, "DID_FAIL_TO_RENEW", "GRACE_PERIOD");
  }

  /** Grace ran out while Apple keeps retrying the charge. */
  graceExpired(originalTransactionId: string): FakeNotification {
    const sub = this.subscription(originalTransactionId);
    if (sub.gracePeriodExpiresDate === null || Date.now() < sub.gracePeriodExpiresDate) {
      throw new Error("the fake App Store ends grace only after the grace period");
    }
    sub.status = 3;
    return this.notify(sub, "GRACE_PERIOD_EXPIRED");
  }

  /** A billing retry finally charged: a new period starts now. */
  recoverBilling(originalTransactionId: string): { readonly transactionId: string; readonly notification: FakeNotification } {
    const sub = this.subscription(originalTransactionId);
    const previous = sub.current;
    const now = Date.now();
    const tx = this.transaction({
      originalTransactionId,
      productId: sub.autoRenewProductId,
      purchaseDate: now,
      originalPurchaseDate: previous.originalPurchaseDate,
      expiresDate: now + SUBSCRIPTION_PERIOD_MS,
      appAccountToken: previous.appAccountToken,
      inAppOwnershipType: previous.inAppOwnershipType,
      transactionReason: "RENEWAL",
    });
    sub.isInBillingRetryPeriod = false;
    sub.gracePeriodExpiresDate = null;
    this.advance(sub, tx, 1);
    return { transactionId: tx.transactionId, notification: this.notify(sub, "DID_RENEW", "BILLING_RECOVERY") };
  }

  /** Apple refunds one transaction (the current period unless named). */
  refund(originalTransactionId: string, transactionId?: string): FakeNotification {
    const sub = this.subscription(originalTransactionId);
    const tx = this.transactionOf(sub, transactionId);
    tx.revocationDate = Date.now();
    tx.revocationReason = 0;
    if (tx === sub.current) sub.status = 5;
    return this.notify(sub, "REFUND", null, tx);
  }

  /** Apple reverses a refund it granted. */
  reverseRefund(originalTransactionId: string, transactionId: string): FakeNotification {
    const sub = this.subscription(originalTransactionId);
    const tx = this.transactionOf(sub, transactionId);
    delete tx.revocationDate;
    delete tx.revocationReason;
    if (tx === sub.current) sub.status = Date.now() < tx.expiresDate ? 1 : 2;
    return this.notify(sub, "REFUND_REVERSED", null, tx);
  }

  /** Family Sharing access to a copy was revoked (the purchaser left the family or turned sharing off). */
  revokeFamilyAccess(originalTransactionId: string, transactionId?: string): FakeNotification {
    const sub = this.subscription(originalTransactionId);
    const tx = this.transactionOf(sub, transactionId);
    if (tx.inAppOwnershipType !== "FAMILY_SHARED") throw new Error("REVOKE is about a family member's copy");
    tx.revocationDate = Date.now();
    sub.status = 5;
    return this.notify(sub, "REVOKE", null, tx);
  }

  /**
   * A REVOKE for a family member's copy as Apple would sign it if the copy
   * shared the purchaser's original transaction id: the hardest case for
   * the server, which must still leave the purchaser alone.
   */
  familyRevokeNamingPurchaser(purchaserOriginalTransactionId: string): FakeNotification {
    const purchaser = this.subscription(purchaserOriginalTransactionId);
    const copy: FakeTransaction = {
      ...purchaser.current,
      transactionId: this.id("3000000"),
      appAccountToken: undefined,
      inAppOwnershipType: "FAMILY_SHARED",
      revocationDate: Date.now(),
    };
    return this.notify({ ...purchaser, status: 5 }, "REVOKE", null, copy);
  }

  /** A transaction exactly as StoreKit would hand it to the app right now. */
  appTransaction(originalTransactionId: string, transactionId?: string): string {
    const sub = this.subscription(originalTransactionId);
    return this.sign(this.transactionOf(sub, transactionId));
  }

  /**
   * Leaves a notification out of Get Notification History as well as
   * undelivered, so a story can exercise the paths that must not depend on
   * the backfill (the renewal re-check and the lapse sweep). Apple's real
   * history normally has every notification it sent.
   */
  omitFromHistory(notification: FakeNotification): void {
    this.omitted.add(notification.uuid);
  }

  /** Whether Get Notification History returns this notification. */
  isInHistory(notification: FakeNotification): boolean {
    return !this.omitted.has(notification.uuid);
  }

  status(originalTransactionId: string): AppleStatusCode {
    return this.subscription(originalTransactionId).status;
  }

  // MARK: - App Store Server API

  private subscriptionStatus(input: {
    readonly originalTransactionId: string;
    readonly bundleId: string;
    readonly environment: string;
  }): AppleSubscriptionStatusSnapshot | null {
    this.statusCalls.push(input.originalTransactionId);
    const sub = this.subscriptions.get(input.originalTransactionId);
    // Apple answers an unknown transaction with 404 TransactionIdNotFound.
    if (!sub || input.bundleId !== FAKE_BUNDLE_ID || input.environment !== "Production") {
      throw new Error("App Store Server API 404: TransactionIdNotFound (fake)");
    }
    return {
      status: sub.status,
      signedTransactionInfo: this.sign(sub.current),
      signedRenewalInfo: this.signer.sign(this.renewalInfo(sub)),
    };
  }

  private notificationHistory(input: {
    readonly bundleId: string;
    readonly environment: string;
    readonly startDate: Date;
    readonly endDate: Date;
    readonly paginationToken: string | null;
  }) {
    const matching = this.history.filter((item) =>
      !this.omitted.has(item.uuid) &&
      item.bundleId === input.bundleId &&
      item.environment === input.environment &&
      item.signedDate >= input.startDate.getTime() &&
      item.signedDate <= input.endDate.getTime()
    );
    const offset = input.paginationToken ? Number(input.paginationToken) : 0;
    const page = matching.slice(offset, offset + HISTORY_PAGE_SIZE);
    const hasMore = offset + HISTORY_PAGE_SIZE < matching.length;
    return {
      signedPayloads: page.map((item) => item.signedPayload),
      hasMore,
      paginationToken: hasMore ? String(offset + HISTORY_PAGE_SIZE) : null,
    };
  }

  // MARK: - Internals

  private id(prefix: string): string {
    const value = `${prefix}${String(this.nextId).padStart(9, "0")}`;
    this.nextId += 1;
    return value;
  }

  private subscription(originalTransactionId: string): FakeSubscription {
    const sub = this.subscriptions.get(originalTransactionId);
    if (!sub) throw new Error(`the fake App Store has no subscription ${originalTransactionId}`);
    return sub;
  }

  private transactionOf(sub: FakeSubscription, transactionId: string | undefined): FakeTransaction {
    if (!transactionId) return sub.current;
    const tx = sub.transactions.find((item) => item.transactionId === transactionId);
    if (!tx) throw new Error(`the fake App Store has no transaction ${transactionId}`);
    return tx;
  }

  private transaction(input: Pick<
    FakeTransaction,
    | "originalTransactionId"
    | "productId"
    | "purchaseDate"
    | "originalPurchaseDate"
    | "expiresDate"
    | "appAccountToken"
    | "inAppOwnershipType"
    | "transactionReason"
  >): FakeTransaction {
    const tx: FakeTransaction = {
      transactionId: this.id("3000000"),
      webOrderLineItemId: this.id("4000000"),
      bundleId: FAKE_BUNDLE_ID,
      subscriptionGroupIdentifier: "21000001",
      quantity: 1,
      type: "Auto-Renewable Subscription",
      environment: "Production",
      storefront: "USA",
      storefrontId: "143441",
      price: PRICES[planOfProduct(input.productId)],
      currency: "USD",
      ...input,
    };
    if (!tx.appAccountToken) delete tx.appAccountToken;
    return tx;
  }

  private advance(sub: FakeSubscription, tx: FakeTransaction, status: AppleStatusCode): void {
    sub.transactions.push(tx);
    sub.current = tx;
    sub.status = status;
  }

  /** Signed at Apple's current time, as every Apple response is. */
  private sign(tx: FakeTransaction): string {
    return this.signer.sign({ ...tx, signedDate: Date.now() });
  }

  private renewalInfo(sub: FakeSubscription): Record<string, unknown> {
    return {
      originalTransactionId: sub.originalTransactionId,
      productId: sub.current.productId,
      autoRenewProductId: sub.autoRenewProductId,
      autoRenewStatus: sub.autoRenewStatus,
      isInBillingRetryPeriod: sub.isInBillingRetryPeriod,
      ...(sub.gracePeriodExpiresDate === null ? {} : { gracePeriodExpiresDate: sub.gracePeriodExpiresDate }),
      ...(sub.status === 2 ? { expirationIntent: 1 } : {}),
      recentSubscriptionStartDate: sub.current.originalPurchaseDate,
      renewalDate: sub.current.expiresDate,
      environment: "Production",
      signedDate: Date.now(),
    };
  }

  private notify(
    sub: FakeSubscription,
    type: string,
    subtype: string | null = null,
    tx: FakeTransaction = sub.current,
  ): FakeNotification {
    const signedDate = Date.now();
    const uuid = `00000000-0000-4000-a000-${String(this.nextId).padStart(12, "0")}`;
    this.nextId += 1;
    const signedPayload = this.signer.sign({
      notificationType: type,
      ...(subtype ? { subtype } : {}),
      notificationUUID: uuid,
      version: "2.0",
      signedDate,
      data: {
        appAppleId: FAKE_APP_APPLE_ID,
        bundleId: FAKE_BUNDLE_ID,
        bundleVersion: "1",
        environment: "Production",
        status: sub.status,
        signedTransactionInfo: this.signer.sign({ ...tx, signedDate }),
        signedRenewalInfo: this.signer.sign(this.renewalInfo(sub)),
      },
    });
    const notification: FakeNotification = {
      uuid, type, subtype, signedDate, signedPayload, bundleId: FAKE_BUNDLE_ID, environment: "Production",
    };
    this.history.push(notification);
    return notification;
  }
}

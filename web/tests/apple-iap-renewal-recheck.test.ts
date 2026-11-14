// A renewal whose DID_RENEW notification never arrived must not cut a paying
// user off: the cron asks the App Store Server API before access ends and
// before the lapse sweep expires a row, and expires only when Apple agrees
// (or the API is not configured). Apple's answer is verified like every other
// signed payload and goes through the same forward-only state write.

import { beforeEach, describe, expect, test } from "bun:test";

import { appleSubscriptionGrantsAccess } from "../services/billing/apple/entitlement";
import { retryAppleNotifications } from "../services/billing/apple/service";
import {
  DAY,
  HOUR,
  MINUTE,
  NOW,
  ORIGINAL,
  createFixture,
  forger,
  renewal,
  seedSubscription,
  signer,
  transaction,
  type Fixture,
} from "./helpers/apple-iap-fixture";

let f: Fixture;

beforeEach(async () => {
  f = await createFixture();
});

const oldExpiry = NOW.getTime() + 2 * HOUR;
const renewedExpiry = oldExpiry + 30 * DAY;

/** Apple's signed state after the renewal it charged at `oldExpiry`. */
function renewedSnapshot(signedDate = NOW.getTime()) {
  return {
    status: 1,
    signedTransactionInfo: signer.sign(transaction({
      transactionId: "period-2",
      purchaseDate: oldExpiry,
      expiresDate: renewedExpiry,
      transactionReason: "RENEWAL",
      signedDate,
    }, f.token)),
    signedRenewalInfo: signer.sign(renewal({ signedDate })),
  };
}

function grantsAt(at: number): boolean {
  return appleSubscriptionGrantsAccess(f.subscription(), new Date(at), {});
}

describe("renewal re-check before access ends", () => {
  test("a renewal Apple charged but never notified keeps the user's access past the old expiry", async () => {
    await seedSubscription(f, { expiresAt: new Date(oldExpiry) });
    f.serverApi = f.statusApi(async () => renewedSnapshot());

    const result = await retryAppleNotifications({}, f.deps());

    expect(f.statusCalls).toEqual([ORIGINAL]);
    expect(result).toMatchObject({ renewalsChecked: 1, renewalsExtended: 1 });
    expect(f.subscription()).toMatchObject({ status: "active", lastTransactionId: "period-2" });
    expect(f.subscription().expiresAt?.getTime()).toBe(renewedExpiry);
    expect(grantsAt(oldExpiry + MINUTE)).toBe(true);
    expect(f.applied).toEqual(["user-a"]);
    expect(f.store.transactions.get("period-2")?.userId).toBe("user-a");
  });

  test("asks Apple at most once per re-check interval while the renewal has not happened yet", async () => {
    await seedSubscription(f, { expiresAt: new Date(oldExpiry) });
    f.serverApi = f.statusApi(async () => ({
      status: 1,
      signedTransactionInfo: signer.sign(transaction({ transactionId: "period-1", signedDate: NOW.getTime() }, f.token)),
      signedRenewalInfo: signer.sign(renewal({ signedDate: NOW.getTime() })),
    }));
    expect(await retryAppleNotifications({}, f.deps())).toMatchObject({ renewalsChecked: 1, renewalsExtended: 0 });
    expect(f.subscription().appleCheckedAt?.getTime()).toBe(NOW.getTime());
    expect(f.subscription().expiresAt?.getTime()).toBe(oldExpiry);

    f.clock = new Date(NOW.getTime() + 20 * MINUTE);
    await retryAppleNotifications({}, f.deps());
    expect(f.statusCalls).toHaveLength(1);

    f.clock = new Date(NOW.getTime() + 30 * MINUTE);
    await retryAppleNotifications({}, f.deps());
    expect(f.statusCalls).toHaveLength(2);
  });

  test("does not ask about subscriptions far from their end, with auto-renew off, or already expired", async () => {
    await seedSubscription(f, { originalTransactionId: "far", expiresAt: new Date(NOW.getTime() + 20 * DAY) });
    await seedSubscription(f, { originalTransactionId: "off", autoRenewEnabled: false });
    await seedSubscription(f, { originalTransactionId: "gone", status: "expired" });
    f.serverApi = f.statusApi(async () => renewedSnapshot());
    expect(await retryAppleNotifications({}, f.deps())).toMatchObject({ renewalsChecked: 0 });
    expect(f.statusCalls).toEqual([]);
  });

  test("never writes Apple state that removes access: revocation stays with notifications and the sweep", async () => {
    await seedSubscription(f, { expiresAt: new Date(oldExpiry) });
    f.serverApi = f.statusApi(async () => ({
      status: 5,
      signedTransactionInfo: signer.sign(transaction({
        transactionId: "period-1", revocationDate: NOW.getTime(), revocationReason: 0, signedDate: NOW.getTime(),
      }, f.token)),
      signedRenewalInfo: null,
    }));
    await retryAppleNotifications({}, f.deps());
    expect(f.subscription()).toMatchObject({ status: "active", lastTransactionId: "period-1" });
    expect(f.applied).toEqual([]);
  });

  test("an answer that is not signed by Apple is ignored", async () => {
    await seedSubscription(f, { expiresAt: new Date(oldExpiry) });
    f.serverApi = f.statusApi(async () => ({
      status: 1,
      signedTransactionInfo: forger.sign(transaction({
        transactionId: "forged", purchaseDate: oldExpiry, expiresDate: renewedExpiry, signedDate: NOW.getTime(),
      }, f.token)),
      signedRenewalInfo: null,
    }));
    expect(await retryAppleNotifications({}, f.deps())).toMatchObject({ renewalCheckFailures: 1 });
    expect(f.subscription()).toMatchObject({ lastTransactionId: "period-1", appleCheckedAt: null });
    expect(f.subscription().expiresAt?.getTime()).toBe(oldExpiry);
    expect(f.applied).toEqual([]);
  });

  test("an answer older than the stored state never overwrites it", async () => {
    await seedSubscription(f, { expiresAt: new Date(oldExpiry), stateSignedAt: new Date(NOW.getTime() - HOUR) });
    f.serverApi = f.statusApi(async () => renewedSnapshot(NOW.getTime() - 2 * HOUR));
    await retryAppleNotifications({}, f.deps());
    expect(f.subscription().lastTransactionId).toBe("period-1");
    expect(f.applied).toEqual([]);
  });

  test("spends at most 60 status lookups per run", async () => {
    for (let index = 0; index < 70; index += 1) {
      await seedSubscription(f, {
        originalTransactionId: `otx-${index}`, expiresAt: new Date(oldExpiry + index * MINUTE),
      });
    }
    f.serverApi = f.statusApi(async () => null);
    await retryAppleNotifications({}, f.deps());
    expect(f.statusCalls.length).toBeLessThanOrEqual(60);
    expect(f.statusCalls.length).toBeGreaterThan(0);
  });
});

describe("lapse sweep", () => {
  const longAgo = new Date(NOW.getTime() - 60 * DAY);

  test("waits an hour past the access end before acting", async () => {
    await seedSubscription(f, { expiresAt: new Date(NOW.getTime() - 30 * MINUTE), updatedAt: longAgo });
    expect(await retryAppleNotifications({}, f.deps())).toMatchObject({ lapsedUsers: 0 });
    expect(f.subscription().status).toBe("active");

    f.clock = new Date(NOW.getTime() + 31 * MINUTE);
    expect(await retryAppleNotifications({}, f.deps())).toMatchObject({ lapsedUsers: 1 });
    expect(f.subscription().status).toBe("expired");
    expect(f.applied).toEqual(["user-a"]);
  });

  test("a lapsed row Apple shows as renewed is written and kept, not expired", async () => {
    const expired = NOW.getTime() - 2 * HOUR;
    await seedSubscription(f, { expiresAt: new Date(expired), updatedAt: longAgo });
    f.serverApi = f.statusApi(async () => ({
      status: 1,
      signedTransactionInfo: signer.sign(transaction({
        transactionId: "period-2", purchaseDate: expired, expiresDate: expired + 30 * DAY,
        transactionReason: "RENEWAL", signedDate: NOW.getTime(),
      }, f.token)),
      signedRenewalInfo: signer.sign(renewal({ signedDate: NOW.getTime() })),
    }));
    const result = await retryAppleNotifications({}, f.deps());
    expect(result).toMatchObject({ lapsedUsers: 0, lapsesRecovered: 1 });
    expect(f.subscription()).toMatchObject({ status: "active", lastTransactionId: "period-2" });
    expect(grantsAt(NOW.getTime())).toBe(true);
    expect(f.applied).toEqual(["user-a"]);
  });

  test("a lapsed row in its grace period per Apple keeps access", async () => {
    const expired = NOW.getTime() - 2 * HOUR;
    await seedSubscription(f, { expiresAt: new Date(expired), updatedAt: longAgo });
    f.serverApi = f.statusApi(async () => ({
      status: 4,
      signedTransactionInfo: signer.sign(transaction({ transactionId: "period-1", expiresDate: expired, signedDate: NOW.getTime() }, f.token)),
      signedRenewalInfo: signer.sign(renewal({
        signedDate: NOW.getTime(), isInBillingRetryPeriod: true, gracePeriodExpiresDate: NOW.getTime() + 5 * DAY,
      })),
    }));
    expect(await retryAppleNotifications({}, f.deps())).toMatchObject({ lapsedUsers: 0, lapsesRecovered: 1 });
    expect(f.subscription().status).toBe("grace_period");
    expect(grantsAt(NOW.getTime())).toBe(true);
  });

  test("expires when Apple agrees the subscription expired", async () => {
    const expired = NOW.getTime() - 2 * HOUR;
    await seedSubscription(f, { expiresAt: new Date(expired), updatedAt: longAgo });
    f.serverApi = f.statusApi(async () => ({
      status: 2,
      signedTransactionInfo: signer.sign(transaction({ transactionId: "period-1", expiresDate: expired, signedDate: NOW.getTime() }, f.token)),
      signedRenewalInfo: signer.sign(renewal({ signedDate: NOW.getTime(), autoRenewStatus: 0 })),
    }));
    expect(await retryAppleNotifications({}, f.deps())).toMatchObject({ lapsedUsers: 1, lapsesRecovered: 0 });
    expect(f.subscription().status).toBe("expired");
    expect(f.applied).toEqual(["user-a"]);
  });

  test("expires when Apple has no status for the transaction", async () => {
    await seedSubscription(f, { expiresAt: new Date(NOW.getTime() - 2 * HOUR), updatedAt: longAgo });
    f.serverApi = f.statusApi(async () => null);
    expect(await retryAppleNotifications({}, f.deps())).toMatchObject({ lapsedUsers: 1 });
    expect(f.subscription().status).toBe("expired");
  });

  test("defers while Apple cannot be asked, then expires a day after the lapse", async () => {
    await seedSubscription(f, { expiresAt: new Date(NOW.getTime() - 2 * HOUR), updatedAt: longAgo });
    f.serverApi = f.statusApi(async () => {
      throw new Error("503 from Apple");
    });
    expect(await retryAppleNotifications({}, f.deps())).toMatchObject({ lapsedUsers: 0, lapsedDeferred: 1 });
    expect(f.subscription().status).toBe("active");
    expect(f.applied).toEqual([]);

    f.clock = new Date(NOW.getTime() + 23 * HOUR);
    expect(await retryAppleNotifications({}, f.deps())).toMatchObject({ lapsedUsers: 1, lapsedDeferred: 0 });
    expect(f.subscription().status).toBe("expired");
    expect(f.applied).toEqual(["user-a"]);
  });

  test("expires on Apple's last signed state when the Server API is not configured", async () => {
    await seedSubscription(f, { expiresAt: new Date(NOW.getTime() - 2 * HOUR), updatedAt: longAgo });
    expect(await retryAppleNotifications({}, f.deps())).toMatchObject({ lapsedUsers: 1 });
    expect(f.subscription().status).toBe("expired");
  });
});

// The notification retry job backs off a row that keeps failing and
// dead-letters it after the last attempt, so one poisoned row (or a hundred)
// can never starve newer notifications.

import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";

import { retryAppleNotifications } from "../services/billing/apple/service";
// A namespace import, so the behavioral tests below still load (and fail on
// their assertions) against a store without the backoff exports.
import * as appleStore from "../services/billing/apple/store";
import { MEMORY_MAX_ATTEMPTS, memoryRetryDelayMs } from "./helpers/apple-memory-store";
import { DAY, HOUR, MINUTE, NOW, createFixture, notification, transaction, type Fixture } from "./helpers/apple-iap-fixture";

const APPLE_NOTIFICATION_MAX_ATTEMPTS = 12;

let f: Fixture;
let errors: unknown[][];
let errorSpy: ReturnType<typeof spyOn>;

beforeEach(async () => {
  f = await createFixture();
  errors = [];
  errorSpy = spyOn(console, "error").mockImplementation((...args: unknown[]) => {
    errors.push(args);
  });
});

afterEach(() => {
  errorSpy.mockRestore();
});

/** Ledger rows for user-a's subscription, inserted (not yet applied) in order. */
async function ledger(count: number, start = 0): Promise<string[]> {
  const uuids: string[] = [];
  for (let index = start; index < start + count; index += 1) {
    const uuid = `00000000-0000-4000-b000-${String(index).padStart(12, "0")}`;
    const signedDate = NOW.getTime() - DAY + index * 1000;
    const signed = notification({
      type: "SUBSCRIBED", subtype: "INITIAL_BUY", status: 1, uuid, signedDate,
      tx: transaction({ transactionId: `tx-${index}`, expiresDate: NOW.getTime() + 29 * DAY }, f.token),
    });
    const payload = await f.deps().verifier.verifyNotification(signed);
    const data = payload.data!;
    await f.store.insertNotification({
      notificationUuid: uuid,
      notificationType: "SUBSCRIBED",
      subtype: "INITIAL_BUY",
      environment: "Production",
      originalTransactionId: null,
      signedDate: new Date(signedDate),
      payload: {
        notificationType: "SUBSCRIBED",
        subtype: "INITIAL_BUY",
        data: { status: 1, transactionInfo: await f.deps().verifier.verifyTransaction(data.signedTransactionInfo!) },
      },
    });
    uuids.push(uuid);
  }
  return uuids;
}

describe("retry backoff", () => {
  test("the memory store double uses the store's backoff schedule", () => {
    expect(appleStore.APPLE_NOTIFICATION_MAX_ATTEMPTS).toBe(APPLE_NOTIFICATION_MAX_ATTEMPTS);
    expect(MEMORY_MAX_ATTEMPTS).toBe(APPLE_NOTIFICATION_MAX_ATTEMPTS);
    for (let attempt = 1; attempt <= 15; attempt += 1) {
      expect(memoryRetryDelayMs(attempt)).toBe(appleStore.appleNotificationRetryDelayMs(attempt));
    }
    expect([1, 2, 3, 9, 10].map((attempt) => appleStore.appleNotificationRetryDelayMs(attempt))).toEqual([
      5 * MINUTE, 10 * MINUTE, 20 * MINUTE, 12 * HOUR, 12 * HOUR,
    ]);
  });

  test("a failed row waits out its backoff, then is retried", async () => {
    const [uuid] = await ledger(1);
    f.applyFailures = 1;
    expect(await retryAppleNotifications({}, f.deps())).toMatchObject({ notifications: { failed: 1 } });
    expect(f.store.notifications.get(uuid!)).toMatchObject({ attemptCount: 1, processedAt: null });
    expect(f.store.notifications.get(uuid!)?.nextAttemptAt?.getTime()).toBe(NOW.getTime() + 5 * MINUTE);

    f.clock = new Date(NOW.getTime() + 4 * MINUTE);
    expect(await retryAppleNotifications({}, f.deps())).toMatchObject({ notifications: { processed: 0, failed: 0 } });

    f.clock = new Date(NOW.getTime() + 5 * MINUTE);
    expect(await retryAppleNotifications({}, f.deps())).toMatchObject({ notifications: { processed: 1 } });
    expect(f.store.notifications.get(uuid!)?.processedAt).not.toBeNull();
  });

  test("failing rows at the head of the queue do not starve newer ones", async () => {
    const poisoned = await ledger(3);
    const [fresh] = await ledger(1, 3);
    f.applyFailures = 3;
    // A batch of three: the three oldest rows fail.
    expect(await retryAppleNotifications({ limit: 3 }, f.deps())).toMatchObject({ notifications: { failed: 3 } });
    // The next run, a minute later, reaches the newer row instead of the same three.
    f.clock = new Date(NOW.getTime() + MINUTE);
    expect(await retryAppleNotifications({ limit: 3 }, f.deps())).toMatchObject({ notifications: { processed: 1 } });
    expect(f.store.notifications.get(fresh!)?.processedAt).not.toBeNull();
    for (const uuid of poisoned) expect(f.store.notifications.get(uuid)?.processedAt).toBeNull();
  });

  test("dead-letters a row after the last attempt and stops retrying it", async () => {
    const [uuid] = await ledger(1);
    let deadLettered = 0;
    for (let attempt = 1; attempt <= APPLE_NOTIFICATION_MAX_ATTEMPTS; attempt += 1) {
      f.applyFailures = 1;
      const result = await retryAppleNotifications({}, f.deps());
      expect(result.notifications.failed).toBe(1);
      deadLettered += result.deadLettered;
      f.clock = f.store.notifications.get(uuid!)!.nextAttemptAt!;
    }
    expect(deadLettered).toBe(1);
    expect(f.store.notifications.get(uuid!)).toMatchObject({ attemptCount: APPLE_NOTIFICATION_MAX_ATTEMPTS, processedAt: null });
    expect(f.store.notifications.get(uuid!)?.deadLetteredAt).not.toBeNull();
    expect(errors.some(([message]) => message === "apple_iap.notification_dead_lettered")).toBe(true);

    f.clock = new Date(f.clock.getTime() + 30 * DAY);
    expect(await retryAppleNotifications({}, f.deps())).toMatchObject({ notifications: { processed: 0, failed: 0 } });
  });
});

// Until an app has its first App Store release, the App Store Server API's
// Production host answers a bodyless 401 for a key the Sandbox accepts
// (productionAccess.ts). That is a quiet, known state: the cron stays ok, the
// backfill skips Production history and keeps its cursor, the renewal
// re-check skips, and the lapse sweep falls back to its no-API behavior.
// When the Sandbox refuses the key too, it stays a loud credential error.

import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";

import { runAppleIapCron } from "../services/billing/apple/cron";
import { backfillAppleNotifications } from "../services/billing/apple/history";
import { AppleServerApiUnauthorizedError, type AppleServerApi } from "../services/billing/apple/serverApi";
import { recordClientAppleTransaction, retryAppleNotifications } from "../services/billing/apple/service";
import {
  BUNDLE,
  DAY,
  HOUR,
  NOW,
  createFixture,
  seedSubscription,
  signer,
  transaction,
  type Fixture,
} from "./helpers/apple-iap-fixture";

type Call = { readonly method: "status" | "history"; readonly bundleId: string; readonly environment: string };

let f: Fixture;
let calls: Call[];
let errors: unknown[][];
let warnings: unknown[][];
let spies: { mockRestore(): void }[];

beforeEach(async () => {
  f = await createFixture();
  calls = [];
  errors = [];
  warnings = [];
  spies = [
    spyOn(console, "error").mockImplementation((...args: unknown[]) => void errors.push(args)),
    spyOn(console, "warn").mockImplementation((...args: unknown[]) => void warnings.push(args)),
    spyOn(console, "info").mockImplementation(() => undefined),
  ];
});

afterEach(() => {
  for (const spy of spies) spy.mockRestore();
});

/**
 * Production answers 401 for every call; the Sandbox answers (empty) unless
 * `sandboxUnauthorized`, when it answers 401 too.
 */
function lockedApi(options: { readonly sandboxUnauthorized?: boolean } = {}): AppleServerApi {
  const refuse = (environment: "Production" | "Sandbox", bundleId: string) =>
    environment === "Production" || options.sandboxUnauthorized === true
      ? new AppleServerApiUnauthorizedError(environment, bundleId)
      : null;
  return {
    subscriptionStatus: async ({ bundleId, environment }) => {
      calls.push({ method: "status", bundleId, environment });
      const error = refuse(environment, bundleId);
      if (error) throw error;
      return null;
    },
    notificationHistory: async ({ bundleId, environment }) => {
      calls.push({ method: "history", bundleId, environment });
      const error = refuse(environment, bundleId);
      if (error) throw error;
      return { signedPayloads: [], hasMore: false, paginationToken: null };
    },
  };
}

function productionCalls(): Call[] {
  return calls.filter((call) => call.environment === "Production");
}

function logged(list: unknown[][], name: string): boolean {
  return list.some(([message]) => message === name);
}

describe("history backfill while Production is locked until release", () => {
  test("skips Production histories without a failure and keeps their cursors", async () => {
    f.serverApi = lockedApi();
    const result = await backfillAppleNotifications(f.deps());

    expect(result.failures).toBe(0);
    const production = result.sources.filter((source) => source.environment === "Production");
    expect(production.length).toBeGreaterThan(0);
    for (const source of production) {
      expect(source).toMatchObject({ error: null, complete: false, locked: true, pages: 0 });
      expect(await f.store.notificationHistoryCursor(source.bundleId, "Production")).toBeNull();
    }
    // The Sandbox history is still read and its cursor moves.
    const sandbox = result.sources.find((source) => source.bundleId === BUNDLE && source.environment === "Sandbox");
    expect(sandbox).toMatchObject({ error: null, complete: true, locked: false });
    expect(await f.store.notificationHistoryCursor(BUNDLE, "Sandbox")).not.toBeNull();
    expect(logged(errors, "apple_iap.history_backfill_failed")).toBe(false);
  });

  test("a later run asks Production again and moves on once it answers", async () => {
    f.serverApi = lockedApi();
    await backfillAppleNotifications(f.deps());
    f.serverApi = f.statusApi(async () => null);
    const result = await backfillAppleNotifications(f.deps());
    expect(result.sources.every((source) => source.complete && !source.locked)).toBe(true);
    expect(await f.store.notificationHistoryCursor(BUNDLE, "Production")).not.toBeNull();
  });

  test("a key the Sandbox refuses too is a loud failure", async () => {
    f.serverApi = lockedApi({ sandboxUnauthorized: true });
    const result = await backfillAppleNotifications(f.deps());
    expect(result.failures).toBe(result.sources.length);
    expect(result.sources.every((source) => source.error !== null && !source.locked)).toBe(true);
    expect(logged(errors, "apple_iap.server_api_unauthorized")).toBe(true);
  });
});

describe("cron while Production is locked until release", () => {
  test("stays ok and reports the state per bundle, without error logs", async () => {
    f.serverApi = lockedApi();
    const result = await runAppleIapCron(f.deps({ env: { ...f.deps().env, VERCEL_ENV: "production" } }));
    expect(result.ok).toBe(true);
    expect(result.productionApi).toEqual({
      [BUNDLE]: "locked_until_release",
      "dev.cmux.app.beta": "locked_until_release",
    });
    expect(errors).toEqual([]);
    // One Production call per bundle per run, not one per history page or row.
    expect(productionCalls()).toHaveLength(2);
  });

  test("a key the Sandbox refuses too fails the cron", async () => {
    f.serverApi = lockedApi({ sandboxUnauthorized: true });
    const result = await runAppleIapCron(f.deps());
    expect(result.ok).toBe(false);
    expect(result.productionApi[BUNDLE]).toBe("unauthorized");
  });

  test("a Production answer is reported ok", async () => {
    f.serverApi = f.statusApi(async () => null);
    const result = await runAppleIapCron(f.deps());
    expect(result.ok).toBe(true);
    expect(result.productionApi[BUNDLE]).toBe("ok");
  });
});

describe("renewal re-check and lapse sweep while Production is locked", () => {
  const longAgo = new Date(NOW.getTime() - 60 * DAY);

  test("the renewal re-check skips the row: no failure, no write", async () => {
    await seedSubscription(f, { expiresAt: new Date(NOW.getTime() + 2 * HOUR) });
    f.serverApi = lockedApi();
    const result = await retryAppleNotifications({}, f.deps());
    expect(result).toMatchObject({ renewalsChecked: 0, renewalCheckFailures: 0, renewalsExtended: 0 });
    expect(f.subscription()).toMatchObject({ status: "active", lastTransactionId: "period-1", appleCheckedAt: null });
    expect(logged(warnings, "apple_iap.status_lookup_failed")).toBe(false);
  });

  test("the sweep expires on Apple's last signed state, as without the Server API, not after a day's deferral", async () => {
    await seedSubscription(f, { expiresAt: new Date(NOW.getTime() - 2 * HOUR), updatedAt: longAgo });
    f.serverApi = lockedApi();
    const result = await retryAppleNotifications({}, f.deps());
    expect(result).toMatchObject({ lapsedUsers: 1, lapsedDeferred: 0, lapsesRecovered: 0 });
    expect(f.subscription().status).toBe("expired");
    expect(f.applied).toEqual(["user-a"]);
  });

  test("a key the Sandbox refuses too keeps the outage behavior: the lapse is deferred", async () => {
    await seedSubscription(f, { expiresAt: new Date(NOW.getTime() - 2 * HOUR), updatedAt: longAgo });
    f.serverApi = lockedApi({ sandboxUnauthorized: true });
    expect(await retryAppleNotifications({}, f.deps())).toMatchObject({ lapsedUsers: 0, lapsedDeferred: 1 });
    expect(f.subscription().status).toBe("active");
  });
});

describe("client transactions while Production is locked", () => {
  test("fall back to the client's own verified transaction under a distinct reason", async () => {
    f.serverApi = lockedApi();
    const result = await recordClientAppleTransaction(
      { userId: "user-a", signedTransactionInfo: signer.sign(transaction({}, f.token)) },
      f.deps(),
    );
    expect(result.planId).toBe("pro");
    const fallback = warnings.find(([message]) => message === "apple_iap.client_transaction_fallback");
    expect(fallback?.[1]).toMatchObject({ reason: "production_api_locked_until_release" });
  });
});

describe("billingHealth probe", () => {
  test("tells ok, locked until release, unauthorized, not configured and unknown apart", async () => {
    const { probeAppleProductionApi } = await import("../services/billing/apple/productionAccess");
    const now = () => NOW;
    expect(await probeAppleProductionApi(null, now)).toBe("not_configured");
    expect(await probeAppleProductionApi(f.statusApi(async () => null), now)).toBe("ok");
    expect(await probeAppleProductionApi(lockedApi(), now)).toBe("locked_until_release");
    expect(await probeAppleProductionApi(lockedApi({ sandboxUnauthorized: true }), now)).toBe("unauthorized");
    const down: AppleServerApi = {
      subscriptionStatus: async () => null,
      notificationHistory: async () => {
        throw new Error("503 from Apple");
      },
    };
    expect(await probeAppleProductionApi(down, now)).toBe("unknown");
  });
});

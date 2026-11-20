// Until an app has its first App Store release, the App Store Server API's
// Production host answers a bodyless 401 for a key the Sandbox accepts
// (productionAccess.ts). That is a quiet, known state: the cron stays ok, the
// backfill skips Production history and keeps its cursor, the renewal
// re-check and the lapse sweep, whose Production rows can only exist after a
// release, treat it as an outage, never as a reason to expire or grant.
// When the Sandbox refuses the key too, it stays a loud credential error.

import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";

import { runAppleIapCron } from "../services/billing/apple/cron";
import { backfillAppleNotifications } from "../services/billing/apple/history";
import { APIException } from "@apple/app-store-server-library";

import * as serverApiModule from "../services/billing/apple/serverApi";
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
    expect(sandbox).toMatchObject({ error: null, locked: false });
    expect(sandbox!.pages).toBeGreaterThan(0);
    expect(await f.store.notificationHistoryCursor(BUNDLE, "Sandbox")).not.toBeNull();
    expect(logged(errors, "apple_iap.history_backfill_failed")).toBe(false);
  });

  test("a later run asks Production again and moves on once it answers", async () => {
    f.serverApi = lockedApi();
    await backfillAppleNotifications(f.deps());
    f.serverApi = f.statusApi(async () => null);
    const result = await backfillAppleNotifications(f.deps());
    expect(result.failures).toBe(0);
    expect(result.sources.every((source) => !source.locked && source.pages > 0)).toBe(true);
    // The first Production window starts at Apple's retention limit, as it would have without the lock.
    expect((await f.store.notificationHistoryCursor(BUNDLE, "Production"))?.nextStartAt.getTime())
      .toBeGreaterThan(NOW.getTime() - 179 * DAY);
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

describe("renewal re-check and lapse sweep: a Production row means the app is released", () => {
  const longAgo = new Date(NOW.getTime() - 60 * DAY);

  test("the renewal re-check counts a locked-looking Production as a failure, writes nothing, and fails the cron", async () => {
    await seedSubscription(f, { expiresAt: new Date(NOW.getTime() + 2 * HOUR) });
    f.serverApi = lockedApi();
    const result = await runAppleIapCron(f.deps());
    expect(result).toMatchObject({ renewalsChecked: 1, renewalCheckFailures: 1, renewalsExtended: 0, ok: false });
    expect(result.productionApi[BUNDLE]).toBe("unauthorized");
    expect(f.subscription()).toMatchObject({ status: "active", lastTransactionId: "period-1", appleCheckedAt: null });
    expect(logged(errors, "apple_iap.production_api_locked_with_subscription")).toBe(true);
    // The backfill that runs after it is loud too, not skipped as locked.
    const production = result.history.sources.find((source) => source.bundleId === BUNDLE && source.environment === "Production");
    expect(production).toMatchObject({ locked: false });
    expect(production?.error).not.toBeNull();
  });

  test("the sweep defers it like an outage instead of expiring a possibly paying user at once", async () => {
    await seedSubscription(f, { expiresAt: new Date(NOW.getTime() - 2 * HOUR), updatedAt: longAgo });
    f.serverApi = lockedApi();
    expect(await retryAppleNotifications({}, f.deps())).toMatchObject({ lapsedUsers: 0, lapsedDeferred: 1 });
    expect(f.subscription().status).toBe("active");
    expect(f.applied).toEqual([]);
    // Still capped: a day after the lapse it expires on Apple's last signed state.
    f.clock = new Date(NOW.getTime() + 23 * HOUR);
    expect(await retryAppleNotifications({}, f.deps())).toMatchObject({ lapsedUsers: 1, lapsedDeferred: 0 });
    expect(f.subscription().status).toBe("expired");
  });

  test("a key the Sandbox refuses too keeps the outage behavior: the lapse is deferred", async () => {
    await seedSubscription(f, { expiresAt: new Date(NOW.getTime() - 2 * HOUR), updatedAt: longAgo });
    f.serverApi = lockedApi({ sandboxUnauthorized: true });
    expect(await retryAppleNotifications({}, f.deps())).toMatchObject({ lapsedUsers: 0, lapsedDeferred: 1 });
    expect(f.subscription().status).toBe("active");
  });
});

describe("what is not the lock", () => {
  test("a Production error other than 401 is an ordinary failure", async () => {
    f.serverApi = {
      subscriptionStatus: async () => null,
      notificationHistory: async ({ environment }) => {
        if (environment === "Production") throw new Error("App Store Server API HTTP 500");
        return { signedPayloads: [], hasMore: false, paginationToken: null };
      },
    };
    const result = await backfillAppleNotifications(f.deps());
    const production = result.sources.filter((source) => source.environment === "Production");
    expect(production.every((source) => source.error !== null && !source.locked)).toBe(true);
    expect(result.failures).toBe(production.length);
  });

  test("a Sandbox probe that fails (an outage) leaves the 401 loud and is not retried for every call", async () => {
    let sandboxCalls = 0;
    f.serverApi = {
      subscriptionStatus: async ({ bundleId }) => {
        throw new AppleServerApiUnauthorizedError("Production", bundleId);
      },
      notificationHistory: async ({ bundleId, environment }) => {
        if (environment === "Production") throw new AppleServerApiUnauthorizedError("Production", bundleId);
        sandboxCalls += 1;
        throw new Error("App Store Server API HTTP 503");
      },
    };
    const { createAppleProductionAccessTracker } = await import("../services/billing/apple/productionAccess");
    const tracker = createAppleProductionAccessTracker(f.serverApi, () => NOW);
    const refused = new AppleServerApiUnauthorizedError("Production", BUNDLE);
    expect(await tracker.classify(refused, BUNDLE)).toBeNull();
    expect(await tracker.classify(refused, BUNDLE)).toBeNull();
    expect(sandboxCalls).toBe(1);
    expect(logged(warnings, "apple_iap.production_api_probe_failed")).toBe(true);
  });

  test("a 401 after Production already answered this run is a real failure, not the lock", async () => {
    let sandboxCalls = 0;
    const api: AppleServerApi = {
      subscriptionStatus: async () => null,
      notificationHistory: async () => {
        sandboxCalls += 1;
        return { signedPayloads: [], hasMore: false, paginationToken: null };
      },
    };
    const { createAppleProductionAccessTracker } = await import("../services/billing/apple/productionAccess");
    const tracker = createAppleProductionAccessTracker(api, () => NOW);
    tracker.markOk(BUNDLE);
    expect(await tracker.classify(new AppleServerApiUnauthorizedError("Production", BUNDLE), BUNDLE)).toBeNull();
    expect(sandboxCalls).toBe(0);
    expect(tracker.snapshot()).toEqual({ [BUNDLE]: "ok" });
  });

  test("the client maps only Apple's HTTP 401 to the unauthorized error", () => {
    const map = (serverApiModule as unknown as {
      unauthorizedOr?: (error: unknown, environment: "Production" | "Sandbox", bundleId: string) => unknown;
    }).unauthorizedOr!;
    const mapped = map(new APIException(401, null, null), "Production", BUNDLE);
    expect(mapped).toBeInstanceOf(AppleServerApiUnauthorizedError);
    expect(mapped).toMatchObject({ environment: "Production", bundleId: BUNDLE });
    const other = new APIException(500, null, null);
    expect(map(other, "Production", BUNDLE)).toBe(other);
    const plain = new Error("socket hang up");
    expect(map(plain, "Sandbox", BUNDLE)).toBe(plain);
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

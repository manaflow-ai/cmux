// The App Store Server API's Production host answers a bodyless HTTP 401 for
// every call until the app has its first App Store release, even with a key
// that works in the Sandbox (Apple, developer forums 742923, 807236, 796073:
// "If your app does not have a production release, you will receive 401 from
// production endpoints"). That is a known, quiet state, not a key problem:
//
// - locked_until_release: Production answered 401 and the Sandbox accepted
//   the same key for the same bundle. Callers fall back to the behavior they
//   have without the Server API (never a grant): the backfill skips that
//   Production history and keeps its cursor, and client transactions use
//   their own verified payload.
// - unauthorized: the Sandbox refused the key too. A credential error, loud.
// - ok: Production answered.
//
// A tracker lives for one cron run, or for one request on the client and
// notification paths (so before the release each such Production call costs
// one extra Sandbox call). Each run asks again, so the state clears by itself
// after the first release.
//
// A Production subscription row can only exist once the app is released, so
// the renewal re-check and the lapse sweep never take the locked fallback for
// one: there a locked answer is logged as an error and treated as an outage
// (recheck.ts).

import { APP_STORE_BUNDLE_ID } from "./config";
import { errorText } from "./effects";
import { appleServerApi, isAppleServerApiUnauthorized, type AppleServerApi } from "./serverApi";
import type { AppleIapDependencies } from "./service";

export type AppleProductionApiAccess = "ok" | "locked_until_release" | "unauthorized";

/** What billingHealth reports: the access above, or why it could not be told. */
export type AppleProductionApiHealth = AppleProductionApiAccess | "not_configured" | "unknown";

/** The Sandbox probe reads this much of the notification history (an empty answer is fine). */
const PROBE_WINDOW_MS = 60 * 60 * 1000;

export type AppleProductionAccessTracker = {
  /** Production is known locked for this bundle in this run: do not ask it again. */
  isLocked(bundleId: string): boolean;
  /** Production answered for this bundle. */
  markOk(bundleId: string): void;
  /**
   * A Production subscription of this bundle exists, so the app is released
   * and its Production 401 is a real credential failure, not the lock.
   */
  markReleasedButRefused(bundleId: string): void;
  /**
   * Explains an error from a Production call for `bundleId`: a 401 is
   * classified once per bundle (one Sandbox probe); null for any other error,
   * or when the Sandbox probe itself failed for another reason (an outage).
   */
  classify(error: unknown, bundleId: string): Promise<"locked_until_release" | "unauthorized" | null>;
  /** Every bundle this run learned about. */
  snapshot(): Readonly<Record<string, AppleProductionApiAccess>>;
};

/**
 * Asks the Sandbox whether the key authenticates for `bundleId`: true when
 * it answered, false on its own 401. Throws on any other failure.
 */
async function sandboxAccepts(serverApi: AppleServerApi, bundleId: string, now: Date): Promise<boolean> {
  try {
    await serverApi.notificationHistory({
      bundleId,
      environment: "Sandbox",
      startDate: new Date(now.getTime() - PROBE_WINDOW_MS),
      endDate: now,
      paginationToken: null,
    });
    return true;
  } catch (error) {
    if (isAppleServerApiUnauthorized(error)) return false;
    throw error;
  }
}

export function createAppleProductionAccessTracker(
  serverApi: AppleServerApi,
  now: () => Date,
): AppleProductionAccessTracker {
  const known = new Map<string, AppleProductionApiAccess>();
  // Bundles whose Sandbox probe failed this run: not probed again (an outage
  // would otherwise cost one extra call per row), the error stays loud.
  const probeFailed = new Set<string>();
  return {
    isLocked: (bundleId) => known.get(bundleId) === "locked_until_release",
    markOk(bundleId) {
      known.set(bundleId, "ok");
    },
    markReleasedButRefused(bundleId) {
      known.set(bundleId, "unauthorized");
    },
    async classify(error, bundleId) {
      if (!isAppleServerApiUnauthorized(error)) return null;
      const cached = known.get(bundleId);
      if (cached === "locked_until_release" || cached === "unauthorized") return cached;
      // Production already answered this run, so it is not waiting for a
      // first release: this 401 is a real failure.
      if (cached === "ok" || probeFailed.has(bundleId)) return null;
      let accepted: boolean;
      try {
        accepted = await sandboxAccepts(serverApi, bundleId, now());
      } catch (probeError) {
        probeFailed.add(bundleId);
        console.warn("apple_iap.production_api_probe_failed", {
          metric: "apple_iap.production_api_probe_failed",
          bundleId,
          error: errorText(probeError),
        });
        return null;
      }
      const access = accepted ? "locked_until_release" : "unauthorized";
      known.set(bundleId, access);
      if (access === "locked_until_release") {
        // Expected until the first App Store release; info, not an alert.
        console.info("apple_iap.production_api_locked_until_release", {
          metric: "apple_iap.production_api_locked_until_release",
          bundleId,
        });
      } else {
        console.error("apple_iap.server_api_unauthorized", {
          metric: "apple_iap.server_api_unauthorized",
          bundleId,
          environments: ["Production", "Sandbox"],
        });
      }
      return access;
    },
    snapshot: () => Object.fromEntries(known),
  };
}

/**
 * The run's tracker (the cron passes one shared by every step), or a fresh
 * one for a single request; null without the Server API.
 */
export function productionAccessOf(deps: AppleIapDependencies): AppleProductionAccessTracker | null {
  if (!deps.serverApi) return null;
  return deps.productionAccess ?? createAppleProductionAccessTracker(deps.serverApi, deps.now);
}

/** `deps` with one tracker for every step of a run (kept when it already has one). */
export function withProductionAccess(deps: AppleIapDependencies): AppleIapDependencies {
  if (!deps.serverApi || deps.productionAccess) return deps;
  return { ...deps, productionAccess: createAppleProductionAccessTracker(deps.serverApi, deps.now) };
}

/** A Production call for `bundleId` was refused because the app has no App Store release yet. */
export async function isProductionLocked(
  tracker: AppleProductionAccessTracker | null,
  error: unknown,
  bundleId: string,
): Promise<boolean> {
  return tracker !== null && (await tracker.classify(error, bundleId)) === "locked_until_release";
}

/**
 * The live Production access of the App Store app for billingHealth: one
 * Production read and, on its 401, one Sandbox read. Never throws.
 */
export async function probeAppleProductionApi(
  serverApi: AppleServerApi | null = appleServerApi(),
  now: () => Date = () => new Date(),
  bundleId: string = APP_STORE_BUNDLE_ID,
): Promise<AppleProductionApiHealth> {
  if (!serverApi) return "not_configured";
  const at = now();
  try {
    await serverApi.notificationHistory({
      bundleId,
      environment: "Production",
      startDate: new Date(at.getTime() - PROBE_WINDOW_MS),
      endDate: at,
      paginationToken: null,
    });
    return "ok";
  } catch (error) {
    const tracker = createAppleProductionAccessTracker(serverApi, now);
    return (await tracker.classify(error, bundleId)) ?? "unknown";
  }
}

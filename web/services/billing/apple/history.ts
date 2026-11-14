// Backfill of App Store Server Notifications through the App Store Server
// API's Get Notification History. Apple retries a failed delivery for a few
// days only; anything it gave up on (or that never reached us) is fetched
// here and fed through the same verify, ledger and apply path as the
// webhook (receiveAppleNotification), so it is idempotent on
// `notificationUUID`. Apple keeps 180 days of history.

import { appleNotificationHistorySources, type AppleNotificationHistorySource } from "./config";
import { errorText } from "./effects";
import { AppleHistoryPaginationError } from "./serverApi";
import { receiveAppleNotification, type AppleIapDependencies, type AppleNotificationOutcome } from "./service";
import type { AppleNotificationHistoryCursor } from "./store";
import { AppleVerificationError } from "./verifier";

const HOUR = 60 * 60 * 1000;
/** Each window starts this much before the previous one ended. */
export const APPLE_HISTORY_OVERLAP_MS = HOUR;
/** Apple keeps 180 days; a day of margin keeps the start date valid. */
export const APPLE_HISTORY_RETENTION_MS = 179 * 24 * HOUR;
/** Pages (up to 20 notifications each) one cron run reads per history. */
const PAGES_PER_SOURCE = 5;

export type AppleHistoryCounts = Record<AppleNotificationOutcome | "rejected", number>;

export type AppleHistorySourceResult = AppleNotificationHistorySource & {
  readonly pages: number;
  readonly notifications: AppleHistoryCounts;
  /** The window was read to its end and the cursor moved past it. */
  readonly complete: boolean;
  readonly error: string | null;
};

export type AppleHistoryResult = {
  /** False when this deployment has no App Store Server API key. */
  readonly configured: boolean;
  readonly sources: readonly AppleHistorySourceResult[];
  /** Histories whose read failed this run; their cursor did not move. */
  readonly failures: number;
};

type HistoryWindow = {
  readonly startDate: Date;
  readonly endDate: Date;
  readonly paginationToken: string | null;
};

function later(a: Date, b: Date): Date {
  return a.getTime() >= b.getTime() ? a : b;
}

/**
 * The window to read: a partly read window continues with its saved token;
 * otherwise a new one runs from the cursor (or, the first time, the newest
 * notification already in the ledger) minus the overlap, to now.
 */
async function historyWindow(
  source: AppleNotificationHistorySource,
  cursor: AppleNotificationHistoryCursor | null,
  deps: AppleIapDependencies,
  now: Date,
): Promise<HistoryWindow> {
  const oldest = new Date(now.getTime() - APPLE_HISTORY_RETENTION_MS);
  if (cursor?.paginationToken && cursor.windowStartAt && cursor.windowEndAt && cursor.windowStartAt > oldest) {
    return { startDate: cursor.windowStartAt, endDate: cursor.windowEndAt, paginationToken: cursor.paginationToken };
  }
  const base = cursor?.nextStartAt ?? await deps.store.latestNotificationSignedDate(source.environment) ?? oldest;
  return {
    startDate: later(new Date(base.getTime() - APPLE_HISTORY_OVERLAP_MS), oldest),
    endDate: now,
    paginationToken: null,
  };
}

function emptyCounts(): AppleHistoryCounts {
  return { processed: 0, duplicate: 0, skipped: 0, failed: 0, rejected: 0 };
}

/** Feeds one page through the webhook path. A verification failure is counted, not fatal. */
async function ingestPage(
  signedPayloads: readonly string[],
  source: AppleNotificationHistorySource,
  counts: AppleHistoryCounts,
  deps: AppleIapDependencies,
): Promise<void> {
  for (const signedPayload of signedPayloads) {
    try {
      counts[await receiveAppleNotification(signedPayload, deps)] += 1;
    } catch (error) {
      if (!(error instanceof AppleVerificationError)) throw error;
      counts.rejected += 1;
      console.warn("apple_iap.history_notification_rejected", { ...source, reason: error.message.slice(0, 200) });
    }
  }
}

async function backfillSource(
  source: AppleNotificationHistorySource,
  deps: AppleIapDependencies,
  pagesPerSource: number,
): Promise<AppleHistorySourceResult> {
  const serverApi = deps.serverApi!;
  const now = deps.now();
  const counts = emptyCounts();
  let pages = 0;
  const result = (complete: boolean, error: string | null): AppleHistorySourceResult =>
    ({ ...source, pages, notifications: counts, complete, error });
  const cursor = await deps.store.notificationHistoryCursor(source.bundleId, source.environment);
  const window = await historyWindow(source, cursor, deps, now);
  let paginationToken = window.paginationToken;
  const save = (fields: Omit<AppleNotificationHistoryCursor, "bundleId" | "environment">) =>
    deps.store.saveNotificationHistoryCursor({ ...source, ...fields });
  try {
    while (pages < pagesPerSource) {
      const page = await serverApi.notificationHistory({ ...source, ...window, paginationToken });
      pages += 1;
      await ingestPage(page.signedPayloads, source, counts, deps);
      if (!page.hasMore) {
        await save({ nextStartAt: window.endDate, windowStartAt: null, windowEndAt: null, paginationToken: null });
        return result(true, null);
      }
      if (!page.paginationToken) throw new Error("Apple reported more history without a pagination token");
      paginationToken = page.paginationToken;
      await save({
        nextStartAt: window.startDate,
        windowStartAt: window.startDate,
        windowEndAt: window.endDate,
        paginationToken,
      });
    }
    return result(false, null);
  } catch (error) {
    if (error instanceof AppleHistoryPaginationError) {
      // Re-read the same window from its start on the next run.
      await save({ nextStartAt: window.startDate, windowStartAt: null, windowEndAt: null, paginationToken: null });
      return result(false, null);
    }
    console.error("apple_iap.history_backfill_failed", {
      metric: "apple_iap.history_backfill_failed",
      ...source,
      error: errorText(error),
    });
    return result(false, errorText(error));
  }
}

/**
 * Reads every configured history (appleNotificationHistorySources) from its
 * cursor and applies what it finds. The cursor moves only after a page was
 * fully ingested (ledger rows written), so a failed run re-reads that page.
 */
export async function backfillAppleNotifications(
  deps: AppleIapDependencies,
  options: { readonly pagesPerSource?: number } = {},
): Promise<AppleHistoryResult> {
  if (!deps.serverApi) return { configured: false, sources: [], failures: 0 };
  const sources: AppleHistorySourceResult[] = [];
  for (const source of appleNotificationHistorySources(deps.env ?? process.env)) {
    sources.push(await backfillSource(source, deps, options.pagesPerSource ?? PAGES_PER_SOURCE));
  }
  return { configured: true, sources, failures: sources.filter((source) => source.error !== null).length };
}

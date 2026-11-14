// Backfill of App Store Server Notifications through the App Store Server
// API's Get Notification History. Apple retries a failed delivery for a few
// days only; anything it gave up on (or that never reached us) is fetched
// here and fed through the same verify, ledger and apply path as the
// webhook (receiveAppleNotification), so it is idempotent on
// `notificationUUID`. A notification already in the ledger is left to the
// retry job (and its backoff). Apple keeps 180 days of history.

import { appleNotificationHistorySources, type AppleNotificationHistorySource } from "./config";
import { errorText } from "./effects";
import { AppleHistoryPaginationError } from "./serverApi";
import { receiveAppleNotification, type AppleIapDependencies, type AppleNotificationOutcome } from "./service";
import type { AppleNotificationHistoryCursor } from "./store";
import { AppleVerificationError } from "./verifier";

const HOUR = 60 * 60 * 1000;
/** Each window starts this much before the previous one ended. */
export const APPLE_HISTORY_OVERLAP_MS = HOUR;
/** Apple keeps 180 days; a new window starts at most 179 days back... */
export const APPLE_HISTORY_RETENTION_MS = 179 * 24 * HOUR;
/** ...so a partly read window stays resumable for a day before it falls off Apple's limit. */
const APPLE_HISTORY_LIMIT_MS = 180 * 24 * HOUR;
/** Pages (up to 20 notifications each) one cron run reads per history. */
const PAGES_PER_SOURCE = 5;
/**
 * A window spans at most this much history. The catch-up from Apple's limit
 * then moves in steps that each finish (and move the cursor) long before
 * their start ages out of Apple's 180 days, so progress is never lost.
 */
export const APPLE_HISTORY_WINDOW_MS = 7 * 24 * HOUR;
/**
 * Consecutive runs a history may stop on a retryable verification failure
 * (about a day at two runs an hour) before that page's still-unverifiable
 * payloads are counted as rejected, so one payload cannot stall the history.
 */
export const APPLE_HISTORY_MAX_RETRYABLE_RUNS = 48;

export type AppleHistoryCounts = Record<AppleNotificationOutcome | "rejected", number>;

export type AppleHistoryOptions = {
  readonly pagesPerSource?: number;
  /**
   * Wall-clock time (ms) after which no further page is requested, so the
   * cron's other steps always finish inside the function's time limit.
   */
  readonly deadlineMs?: number;
};

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
 * otherwise a new one runs from the cursor minus the overlap (the first
 * time, from Apple's retention limit, so everything Apple still keeps is
 * covered once) to now.
 */
function historyWindow(cursor: AppleNotificationHistoryCursor | null, now: Date): HistoryWindow {
  const resumable = new Date(now.getTime() - APPLE_HISTORY_LIMIT_MS);
  if (cursor?.paginationToken && cursor.windowStartAt && cursor.windowEndAt && cursor.windowStartAt > resumable) {
    return { startDate: cursor.windowStartAt, endDate: cursor.windowEndAt, paginationToken: cursor.paginationToken };
  }
  return windowFrom(cursor?.nextStartAt ?? null, now);
}

/** A new window from `nextStartAt` minus the overlap, at most APPLE_HISTORY_WINDOW_MS long, ending no later than now. */
function windowFrom(nextStartAt: Date | null, now: Date): HistoryWindow {
  const oldest = new Date(now.getTime() - APPLE_HISTORY_RETENTION_MS);
  const startDate = later(new Date((nextStartAt ?? oldest).getTime() - APPLE_HISTORY_OVERLAP_MS), oldest);
  const endDate = new Date(Math.min(now.getTime(), startDate.getTime() + APPLE_HISTORY_WINDOW_MS));
  return { startDate, endDate, paginationToken: null };
}

function emptyCounts(): AppleHistoryCounts {
  return { processed: 0, duplicate: 0, skipped: 0, failed: 0, rejected: 0 };
}

/**
 * The `notificationUUID` a signed payload claims, read without verifying it.
 * Used only to skip a notification already in the ledger, which does
 * nothing, so a forged value can at most skip a no-op.
 */
function claimedNotificationUuid(signedPayload: string): string | null {
  const body = signedPayload.split(".")[1];
  if (!body) return null;
  try {
    const decoded = JSON.parse(Buffer.from(body, "base64url").toString("utf8")) as { notificationUUID?: unknown };
    return typeof decoded.notificationUUID === "string" ? decoded.notificationUUID : null;
  } catch {
    return null;
  }
}

/**
 * Feeds one page through the webhook path. A payload that fails
 * verification for good is counted and skipped; a retryable verification
 * failure (Apple's certificate check unreachable) throws, so the cursor stays
 * and the page is read again.
 */
async function ingestPage(
  signedPayloads: readonly string[],
  source: AppleNotificationHistorySource,
  counts: AppleHistoryCounts,
  deps: AppleIapDependencies,
  skipRetryable: boolean,
): Promise<void> {
  for (const signedPayload of signedPayloads) {
    const uuid = claimedNotificationUuid(signedPayload);
    if (uuid && await deps.store.notification(uuid)) {
      counts.duplicate += 1;
      continue;
    }
    try {
      counts[await receiveAppleNotification(signedPayload, deps)] += 1;
    } catch (error) {
      if (!(error instanceof AppleVerificationError)) throw error;
      if (error.reason === "retryable" && !skipRetryable) throw error;
      counts.rejected += 1;
      const log = error.reason === "retryable" ? console.error : console.warn;
      log("apple_iap.history_notification_rejected", { ...source, reason: error.reason, notificationUuid: uuid });
    }
  }
}

type CursorFields = Omit<AppleNotificationHistoryCursor, "bundleId" | "environment">;

function isRetryableVerification(error: unknown): boolean {
  return error instanceof AppleVerificationError && error.reason === "retryable";
}

async function backfillSource(
  source: AppleNotificationHistorySource,
  deps: AppleIapDependencies,
  pagesPerSource: number,
  deadlineMs: number,
): Promise<AppleHistorySourceResult> {
  const serverApi = deps.serverApi!;
  const now = deps.now();
  const counts = emptyCounts();
  let pages = 0;
  const result = (complete: boolean, error: string | null): AppleHistorySourceResult =>
    ({ ...source, pages, notifications: counts, complete, error });
  const cursor = await deps.store.notificationHistoryCursor(source.bundleId, source.environment);
  let window = historyWindow(cursor, now);
  // What is persisted; a retryable stop keeps it and only counts the run.
  let saved: CursorFields = cursor ?? {
    nextStartAt: window.startDate, windowStartAt: null, windowEndAt: null, paginationToken: null, retryableRuns: 0,
  };
  const save = async (fields: Omit<CursorFields, "retryableRuns">) => {
    saved = { ...fields, retryableRuns: 0 };
    await deps.store.saveNotificationHistoryCursor({ ...source, ...saved });
  };
  const skipRetryable = saved.retryableRuns >= APPLE_HISTORY_MAX_RETRYABLE_RUNS;
  try {
    while (pages < pagesPerSource && Date.now() < deadlineMs) {
      const page = await serverApi.notificationHistory({ ...source, ...window });
      pages += 1;
      await ingestPage(page.signedPayloads, source, counts, deps, skipRetryable);
      if (page.hasMore) {
        if (!page.paginationToken) throw new Error("Apple reported more history without a pagination token");
        window = { ...window, paginationToken: page.paginationToken };
        await save({ nextStartAt: window.startDate, windowStartAt: window.startDate, windowEndAt: window.endDate, paginationToken: page.paginationToken });
        continue;
      }
      await save({ nextStartAt: window.endDate, windowStartAt: null, windowEndAt: null, paginationToken: null });
      // A catch-up window ended before now: the next one starts in the same run.
      if (window.endDate.getTime() >= now.getTime()) return result(true, null);
      window = windowFrom(window.endDate, now);
    }
    return result(false, null);
  } catch (error) {
    return await backfillFailure(error, source, saved, window, deps, () => result(false, errorText(error)), () => result(false, null));
  }
}

async function backfillFailure(
  error: unknown,
  source: AppleNotificationHistorySource,
  saved: CursorFields,
  window: HistoryWindow,
  deps: AppleIapDependencies,
  failed: () => AppleHistorySourceResult,
  incomplete: () => AppleHistorySourceResult,
): Promise<AppleHistorySourceResult> {
  if (error instanceof AppleHistoryPaginationError) {
    // Re-read the same window from its start on the next run.
    await deps.store.saveNotificationHistoryCursor({
      ...source, nextStartAt: window.startDate, windowStartAt: null, windowEndAt: null, paginationToken: null, retryableRuns: 0,
    });
    return incomplete();
  }
  if (isRetryableVerification(error)) {
    // The page is read again next run; after APPLE_HISTORY_MAX_RETRYABLE_RUNS
    // stopped runs its unverifiable payloads are counted as rejected instead.
    const retryableRuns = saved.retryableRuns + 1;
    await deps.store.saveNotificationHistoryCursor({ ...source, ...saved, retryableRuns });
    console.error("apple_iap.history_backfill_stalled", {
      metric: "apple_iap.history_backfill_stalled", ...source, retryableRuns,
    });
    return failed();
  }
  console.error("apple_iap.history_backfill_failed", {
    metric: "apple_iap.history_backfill_failed",
    ...source,
    error: errorText(error),
  });
  return failed();
}

/**
 * Reads every configured history (appleNotificationHistorySources) from its
 * cursor and applies what it finds. The cursor moves only after a page was
 * fully ingested (ledger rows written), so a failed run re-reads that page.
 */
export async function backfillAppleNotifications(
  deps: AppleIapDependencies,
  options: AppleHistoryOptions = {},
): Promise<AppleHistoryResult> {
  if (!deps.serverApi) return { configured: false, sources: [], failures: 0 };
  const sources: AppleHistorySourceResult[] = [];
  const pagesPerSource = options.pagesPerSource ?? PAGES_PER_SOURCE;
  const deadlineMs = options.deadlineMs ?? Number.POSITIVE_INFINITY;
  for (const source of appleNotificationHistorySources(deps.env ?? process.env)) {
    sources.push(await backfillSource(source, deps, pagesPerSource, deadlineMs));
  }
  return { configured: true, sources, failures: sources.filter((source) => source.error !== null).length };
}

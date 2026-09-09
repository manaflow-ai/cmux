/**
 * Whether a device registration would change anything the registry stores.
 *
 * The Mac re-registers whenever its advertised route set changes, and it
 * compares routes that still carry per-observation timestamps. Those
 * timestamps never reach the database: `sanitizeServerPublishedRoutes` strips
 * every iroh route down to its id, endpoint and priority. So a client can
 * re-POST a "changed" route set many times an hour while the row it would
 * write is byte-identical to the row already there.
 *
 * A client that cannot be updated will keep doing that. This lets the server
 * answer it without taking the per-team advisory lock or writing two rows.
 */

/** How stale a presence timestamp may get before a no-op POST refreshes it. */
const DEFAULT_PRESENCE_TOUCH_INTERVAL_MS = 60_000;

export function presenceTouchIntervalMs(
  raw = process.env.CMUX_DEVICE_PRESENCE_TOUCH_INTERVAL_MS,
): number {
  const trimmed = raw?.trim();
  if (!trimmed) return DEFAULT_PRESENCE_TOUCH_INTERVAL_MS;
  const parsed = Number(trimmed);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    return DEFAULT_PRESENCE_TOUCH_INTERVAL_MS;
  }
  return parsed;
}

export type StoredRegistration = {
  readonly userId: string;
  readonly platform: string;
  readonly displayName: string | null;
  readonly labels: Record<string, unknown>;
  readonly instanceRoutes: readonly unknown[];
  readonly instanceLabels: Record<string, unknown>;
  readonly lastSeenAt: Date;
};

export type IncomingRegistration = {
  readonly userId: string;
  readonly platform: string;
  readonly displayName: string | null;
  readonly labels: Record<string, unknown>;
  readonly instanceRoutes: readonly unknown[];
  readonly instanceLabels: Record<string, unknown>;
};

/**
 * True when writing `incoming` over `stored` would leave every column
 * unchanged except the presence timestamps, and those were refreshed within
 * `touchIntervalMs`.
 *
 * Deliberately strict: any difference at all, including a re-ordered route
 * list, falls through to the normal write path. A false positive would strand
 * a phone on routes the Mac no longer has, which is far worse than an extra
 * transaction.
 */
export function registrationIsUnchanged(input: {
  readonly stored: StoredRegistration | null;
  readonly incoming: IncomingRegistration;
  readonly now: Date;
  readonly touchIntervalMs: number;
}): boolean {
  const { stored, incoming } = input;
  if (!stored) return false;
  if (input.touchIntervalMs <= 0) return false;
  const sinceLastSeenMs = input.now.getTime() - stored.lastSeenAt.getTime();
  // A clock that moved backwards must not make a stale row look fresh.
  if (sinceLastSeenMs < 0 || sinceLastSeenMs >= input.touchIntervalMs) {
    return false;
  }
  return stored.userId === incoming.userId
    && stored.platform === incoming.platform
    && stored.displayName === incoming.displayName
    && jsonEquals(stored.labels, incoming.labels)
    && jsonEquals(stored.instanceRoutes, incoming.instanceRoutes)
    && jsonEquals(stored.instanceLabels, incoming.instanceLabels);
}

/**
 * Structural equality over the JSON shapes the registry stores. Object key
 * order is not significant; array order is.
 */
function jsonEquals(left: unknown, right: unknown): boolean {
  if (left === right) return true;
  if (typeof left !== typeof right) return false;
  if (left === null || right === null) return false;
  if (Array.isArray(left) || Array.isArray(right)) {
    if (!Array.isArray(left) || !Array.isArray(right)) return false;
    if (left.length !== right.length) return false;
    return left.every((value, index) => jsonEquals(value, right[index]));
  }
  if (typeof left !== "object") return false;
  const leftRecord = left as Record<string, unknown>;
  const rightRecord = right as Record<string, unknown>;
  const leftKeys = Object.keys(leftRecord).sort();
  const rightKeys = Object.keys(rightRecord).sort();
  if (leftKeys.length !== rightKeys.length) return false;
  if (leftKeys.some((key, index) => key !== rightKeys[index])) return false;
  return leftKeys.every((key) => jsonEquals(leftRecord[key], rightRecord[key]));
}
